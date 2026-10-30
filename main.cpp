// hyprtagger: companion plugin for hyprtagger.lua
//
// hyprtagger.lua emulates dwl/Mango tags on top of Hyprland workspaces 1..9. When
// several tags are viewed at once, all their windows live on one workspace, so
// Hyprland reports only that one as active and the "borrowed" tags as empty (or
// deletes them). This plugin fixes what ext-workspace-v1 clients (bars) see:
//
//   * viewed tags            -> state ACTIVE
//   * occupied, not viewed   -> state 0 (shown, inactive)
//   * empty, not viewed      -> state HIDDEN
//
// and keeps viewed/occupied tag workspaces alive (persistent) while needed, so
// there is something to report.
//
// hyprtagger.lua feeds it via:  hl.plugin.hyprtagger.set_state({ view = {..}, occupied = {..} })
//
// It also registers a window rule effect `tags`, so users can assign starting
// tags with native rules:
//
//   hl.window_rule({ match = { class = "^discord$" }, tags = "2 5" })
//
// hyprtagger.lua reads it once when a window opens via
// hl.plugin.hyprtagger.rule_tags(address). Unlike Hyprland's `tag` effect this
// leaves no labels on the window. The plugin must be loaded (hl.plugin.load)
// before rules using `tags` are parsed.

#include <bitset>
#include <format>
#include <stdexcept>
#include <string>

#include <lua.hpp>

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/workspace/HLWorkspace.hpp>
#include <hyprland/src/workspace/RegularWorkspace.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>
#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/rule/windowRule/WindowRuleEffectContainer.hpp>
#include <hyprland/src/desktop/rule/windowRule/WindowRuleApplicator.hpp>
#include <hyprland/src/protocols/WaylandProtocol.hpp>
#include <hyprland/protocols/ext-workspace-v1.hpp>

// Needed for the protocol's private members (resource list, handle, manager, sendState)
#define private public
#include <hyprland/src/protocols/ExtWorkspace.hpp>
#undef private

inline HANDLE PHANDLE = nullptr;

namespace {
    constexpr int   NTAGS = 9;

    CFunctionHook*  g_sendStateHook = nullptr;

    constexpr const char*                                 TAGS_EFFECT = "tags";
    Desktop::Rule::CWindowRuleEffectContainer::storageType g_tagsEffect = 0;

    bool            g_haveState = false;
    std::bitset<10> g_view;      // index = tag number
    std::bitset<10> g_occupied;
    std::bitset<10> g_madePersistent; // workspaces we turned persistent (and must undo)

    // Tag number (1..NTAGS) of a workspace, or 0 if it isn't a tag workspace.
    // Since 0.57 workspace IDs are a variant: numbered, or none for named/special.
    int tagOf(const PHLWORKSPACE& ws) {
        if (!ws || ws->type() != Workspace::eWorkspaceType::NORMAL)
            return 0;
        const auto id = ws->numberedID();
        if (!id || *id < 1 || *id > (Workspace::WorkspaceIDContainer)NTAGS)
            return 0;
        return (int)*id;
    }

    PHLWORKSPACE findWorkspace(int tag) {
        for (const auto& ref : State::workspaceState()->workspaces()) {
            auto ws = ref.lock();
            if (ws && tagOf(ws) == tag)
                return ws;
        }
        return nullptr;
    }

    Workspace::CRegularWorkspace* regular(const PHLWORKSPACE& ws) {
        return ws ? dynamic_cast<Workspace::CRegularWorkspace*>(ws.get()) : nullptr;
    }

    // Override the state Hyprland just sent for a tag workspace
    void applyTagState(CExtWorkspaceResource* res) {
        if (!g_haveState || !res || !res->good() || !res->m_resource)
            return;

        auto       ws = res->workspace();
        const auto t  = tagOf(ws);
        if (!t)
            return;

        uint32_t   state = 0;
        if (g_view[t])
            state |= EXT_WORKSPACE_HANDLE_V1_STATE_ACTIVE;
        else if (!g_occupied[t])
            state |= EXT_WORKSPACE_HANDLE_V1_STATE_HIDDEN;
        if (ws->hasUrgentWindow())
            state |= EXT_WORKSPACE_HANDLE_V1_STATE_URGENT;

        res->m_resource->sendState((extWorkspaceHandleV1State)state);

        // m_manager is a weak ref to a unique ptr: check, don't lock()
        if (res->m_manager)
            res->m_manager->scheduleDone();
    }

    // A resource can briefly outlive its workspace (e.g. right after we drop
    // persistence). Hyprland's own sendState() assumes a live workspace.
    bool hasLiveWorkspace(CExtWorkspaceResource* res) {
        if (!res || !res->good())
            return false;
        return !!res->workspace();
    }

    void hkSendState(void* thisptr) {
        auto res = (CExtWorkspaceResource*)thisptr;
        if (!hasLiveWorkspace(res))
            return;
        ((void (*)(void*))g_sendStateHook->m_original)(thisptr);
        applyTagState(res);
    }

    void resendAll() {
        if (!PROTO::extWorkspace)
            return;
        for (const auto& res : PROTO::extWorkspace->m_workspaces) {
            if (hasLiveWorkspace(res.get()))
                res->sendState(); // goes through the hook
        }
    }

    // Keep viewed/occupied tag workspaces alive, let the rest go
    void syncPersistence() {
        PHLMONITOR mon;
        for (int t = 1; t <= NTAGS && !mon; ++t) {
            if (auto ws = findWorkspace(t); ws && ws->m_monitor)
                mon = ws->m_monitor.lock();
        }

        for (int t = 1; t <= NTAGS; ++t) {
            const bool want = g_view[t] || g_occupied[t];
            auto       ws   = findWorkspace(t);

            if (want) {
                if (!ws && mon) {
                    ws = State::workspaceState()->createNumbered(Workspace::SWorkspaceNumberedID((Workspace::WorkspaceIDContainer)t), mon, std::to_string(t));
                    if (ws)
                        ws->ready();
                }
                if (auto r = regular(ws); r && !r->isPersistent()) {
                    r->setPersistent(true);
                    g_madePersistent[t] = true;
                }
            } else if (g_madePersistent[t]) {
                if (auto r = regular(ws))
                    r->setPersistent(false);
                g_madePersistent[t] = false;
            }
        }
    }

    std::bitset<10> readTagList(lua_State* L, int tbl, const char* key) {
        std::bitset<10> out;
        lua_getfield(L, tbl, key);
        if (lua_istable(L, -1)) {
            const auto n = lua_rawlen(L, -1);
            for (lua_Integer i = 1; i <= (lua_Integer)n; ++i) {
                lua_rawgeti(L, -1, i);
                if (lua_isinteger(L, -1)) {
                    const auto t = lua_tointeger(L, -1);
                    if (t >= 1 && t <= NTAGS)
                        out[t] = true;
                }
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 1);
        return out;
    }

    // hl.plugin.hyprtagger.set_state({ view = {1,2}, occupied = {1,2,3} })
    int luaSetState(lua_State* L) {
        if (!lua_istable(L, 1))
            return luaL_error(L, "hyprtagger.set_state: expected a table { view = {...}, occupied = {...} }");

        g_view      = readTagList(L, 1, "view");
        g_occupied  = readTagList(L, 1, "occupied");
        g_haveState = true;

        syncPersistence();
        resendAll();
        return 0;
    }

    // hl.plugin.hyprtagger.has_state() -> bool (hyprtagger.lua uses this to bootstrap after a plugin load)
    int luaHasState(lua_State* L) {
        lua_pushboolean(L, g_haveState);
        return 1;
    }

    // Drop all overrides and hand plain Hyprland state back to clients. With
    // g_haveState cleared, applyTagState() is a no-op, so the resend is safe
    // whether or not the sendState hook is still installed.
    void reset() {
        g_haveState = false;
        g_view.reset();
        g_occupied.reset();
        syncPersistence();
        resendAll();
    }

    // hl.plugin.hyprtagger.clear(): drop overrides, return to plain Hyprland behaviour
    int luaClear(lua_State*) {
        reset();
        return 0;
    }

    // hl.plugin.hyprtagger.rule_tags(address) -> string|nil
    // Raw value of the `tags` rule effect for a window, e.g. "2 5" or "all".
    int luaRuleTags(lua_State* L) {
        const std::string addr = luaL_checkstring(L, 1);
        for (const auto& w : Desktop::windowState()->windows()) {
            if (!w || std::format("0x{:x}", (uintptr_t)w.get()) != addr)
                continue;
            if (!w->m_ruleApplicator)
                break;
            const auto& props = w->m_ruleApplicator->m_otherProps.props;
            if (auto it = props.find(g_tagsEffect); it != props.end() && it->second) {
                lua_pushstring(L, it->second->effect.c_str());
                return 1;
            }
            break;
        }
        lua_pushnil(L);
        return 1;
    }

    void fail(const std::string& msg) {
        HyprlandAPI::addNotification(PHANDLE, "[hyprtagger] " + msg, CHyprColor{1.0, 0.2, 0.2, 1.0}, 8000);
        throw std::runtime_error("[hyprtagger] " + msg);
    }

    void addLuaFn(const char* name, PLUGIN_LUA_FN fn) {
        if (!HyprlandAPI::addLuaFunction(PHANDLE, "hyprtagger", name, fn))
            fail(std::format("could not register hl.plugin.hyprtagger.{}", name));
    }
}

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    const std::string COMPOSITOR_HASH = __hyprland_api_get_hash();
    const std::string CLIENT_HASH     = __hyprland_api_get_client_hash();
    if (COMPOSITOR_HASH != CLIENT_HASH)
        fail("Mismatched headers! Rebuild the plugin for this Hyprland version.");

    const auto matches = HyprlandAPI::findFunctionsByName(PHANDLE, "sendState");
    void*      target  = nullptr;
    for (const auto& m : matches) {
        if (m.demangled.starts_with("CExtWorkspaceResource::sendState(")) {
            target = m.address;
            break;
        }
    }
    if (!target)
        fail("CExtWorkspaceResource::sendState not found");

    g_sendStateHook = HyprlandAPI::createFunctionHook(PHANDLE, target, (void*)&hkSendState);
    if (!g_sendStateHook || !g_sendStateHook->hook())
        fail("failed to hook CExtWorkspaceResource::sendState");

    addLuaFn("set_state", luaSetState);
    addLuaFn("has_state", luaHasState);
    addLuaFn("clear", luaClear);
    addLuaFn("rule_tags", luaRuleTags);

    // Register the effect last: a failed init ejects the plugin without calling
    // PLUGIN_EXIT, so nothing that can throw may follow this.
    g_tagsEffect = Desktop::Rule::windowEffects()->registerEffect(TAGS_EFFECT);
    if (!g_tagsEffect)
        fail("could not register the `tags` window rule effect");

    return {"hyprtagger", "dwl/Mango-style tags for Hyprland: bar reporting and the tags window rule", "prankstr", "0.1"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    if (g_tagsEffect)
        Desktop::Rule::windowEffects()->unregisterEffect(g_tagsEffect);
    // Undo persistence and send plain state, so bars don't keep showing tags
    reset();
}
