-----------------------------------------------------------------------
-- hyprtagger.lua: dwl/Mango-style tags on top of Hyprland workspaces
--
-- Model
--   * Every window carries a set of tags 1..9, stored as Hyprland window
--     tags "t1".."t9" (so they survive config reloads).
--   * The monitor views a *set* of tags. One of them is the "primary" tag,
--     and workspace <primary> is what's actually on screen.
--   * Changing the view gathers every window that matches the view into the
--     primary workspace *before* switching to it (while it's off-screen),
--     and parks every other window on its lowest tag's workspace. Plain
--     single-tag switches therefore use Hyprland's own workspace animation.
--   * The "mtile" layout orders windows by one global stack order (like
--     dwl's client list), so windows keep their position when they leave and
--     come back, instead of being appended at the end.
--
-- Window rules (needs the hyprtagger plugin, loaded with hl.plugin.load
-- *before* any rule that uses it):
--
--     hl.window_rule({ match = { class = "^discord$" }, tags = "2 5" })
--     hl.window_rule({ match = { class = "^pavucontrol$" }, tags = "all" })
--
--   `tags` sets a window's starting tags once, when it opens; keybinds own
--   them afterwards (like Mango). Matching is Hyprland's own, so every match
--   field and regex works. If none of the tags is being viewed, the window
--   opens in the background and the view doesn't change. A plain workspace
--   rule (`workspace = "3 silent"`) still works for a single tag; `tags` wins
--   if both are set. Prefer `silent` workspace rules: a non-silent one
--   switches the view.
--
--   The labels "t1".."t9" belong to hyprtagger.lua; don't set them from rules.
--
-- Single monitor only. Workspaces outside 1..9 and special workspaces
-- (scratchpads) are left alone.
-----------------------------------------------------------------------

local M = {}

local NTAGS = 9
-- One state file per Hyprland instance (next to its sockets)
local STATE_FILE = (os.getenv("XDG_RUNTIME_DIR") or "/tmp")
	.. "/hypr/"
	.. (os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or "default")
	.. "/tags-state.lua"

local cfg = {
	mfact = 0.55, -- master width fraction
	nmaster = 1, -- windows in the master area
	new_is_master = true, -- new windows become master (dwl/Mango default)
	follow_tag = true, -- SUPER+SHIFT+N also switches to tag N (Mango default)
	layouts = { "tile", "center_tile" }, -- cycled with M.cycle_layout
}

-- Runtime state (Lua state is wiped on reload; see save()/load())
local S = {
	order = {}, -- window addresses, index 1 = top of stack
	view = { tags = { [1] = true }, primary = 1 },
	prev = nil, -- previous view, for view_prev
	pertag = {}, -- [workspace id] = { mfact, nmaster, layout }
}

local busy = 0 -- >0 while we're the ones moving windows / switching

-----------------------------------------------------------------------
-- Small helpers
-----------------------------------------------------------------------

local function notify_err(err)
	pcall(hl.notification.create, { text = "hyprtagger.lua: " .. tostring(err), timeout = 8000, icon = "error" })
end

-- Run fn with the re-entrancy guard held; report errors instead of throwing
local function guarded(fn, ...)
	busy = busy + 1
	local ok, err = pcall(fn, ...)
	busy = busy - 1
	if not ok then
		notify_err(err)
	end
	return ok
end

local function sel(w)
	return "address:" .. w.address
end

local function copy(set)
	local t = {}
	for k in pairs(set) do
		t[k] = true
	end
	return t
end

local function minkey(set)
	local m
	for k in pairs(set) do
		if not m or k < m then
			m = k
		end
	end
	return m
end

local function same(a, b)
	for k in pairs(a) do
		if not b[k] then
			return false
		end
	end
	for k in pairs(b) do
		if not a[k] then
			return false
		end
	end
	return true
end

local function is_tag_ws(ws)
	-- Since Hyprland 0.57, named workspaces have no numeric id (ws.id == nil)
	local id = ws and ws.id
	return type(id) == "number" and not ws.special and id >= 1 and id <= NTAGS
end

local function managed(w)
	return w ~= nil and w.mapped ~= false and is_tag_ws(w.workspace)
end

-- Tags of a window as a set; second return value is false if it has none
local function wtags(w)
	local set, any = {}, false
	for _, t in ipairs(w.tags or {}) do
		local n = tonumber(tostring(t):match("^t(%d+)$"))
		if n and n >= 1 and n <= NTAGS then
			set[n] = true
			any = true
		end
	end
	return set, any
end

local function set_tags(w, set)
	local cur = wtags(w)
	for i = 1, NTAGS do
		if cur[i] and not set[i] then
			hl.dispatch(hl.dsp.window.tag({ tag = "-t" .. i, window = sel(w) }))
		elseif set[i] and not cur[i] then
			hl.dispatch(hl.dsp.window.tag({ tag = "+t" .. i, window = sel(w) }))
		end
	end
end

-- Starting tags from the plugin's `tags` window rule effect ("2 5", "2,5",
-- "all"), or nil if the window has none or the plugin isn't loaded
local function rule_tags(w)
	local p = hl.plugin and hl.plugin.hyprtagger
	if not (p and p.rule_tags) then
		return nil
	end
	local ok, raw = pcall(p.rule_tags, w.address)
	if not ok or type(raw) ~= "string" then
		return nil
	end
	local set = {}
	if raw:match("^%s*all%s*$") then
		for i = 1, NTAGS do
			set[i] = true
		end
		return set
	end
	for item in raw:gmatch("[^%s,]+") do
		local n = tonumber(item)
		if not n or n ~= math.floor(n) or n < 1 or n > NTAGS then
			notify_err(string.format("invalid tags rule %q for %s (use 1-%d or \"all\")", raw, w.class, NTAGS))
			return nil
		end
		set[n] = true
	end
	return next(set) and set or nil
end

-- Workspace a window with these tags should live on under the current view
local function home(tags)
	for k in pairs(tags) do
		if S.view.tags[k] then
			return S.view.primary
		end
	end
	return minkey(tags)
end

local function pertag(id)
	local p = S.pertag[id]
	if not p then
		p = { mfact = cfg.mfact, nmaster = cfg.nmaster, layout = cfg.layouts[1] }
		S.pertag[id] = p
	end
	return p
end

-----------------------------------------------------------------------
-- Global stack order
-----------------------------------------------------------------------

local function order_index(a)
	for i, x in ipairs(S.order) do
		if x == a then
			return i
		end
	end
end

local function order_remove(a)
	local i = order_index(a)
	if i then
		table.remove(S.order, i)
	end
end

local function order_add(a)
	if order_index(a) then
		return
	end
	if cfg.new_is_master then
		table.insert(S.order, 1, a)
	else
		S.order[#S.order + 1] = a
	end
end

local function rank_map()
	local r = {}
	for i, a in ipairs(S.order) do
		r[a] = i
	end
	return r
end

-- Windows on the active workspace, sorted by stack order
local function visible_sorted(include_floating)
	local aw = hl.get_active_workspace()
	if not aw then
		return {}
	end
	local r, list = rank_map(), {}
	for _, w in ipairs(aw:get_windows()) do
		if w.mapped ~= false and (include_floating or not w.floating) then
			list[#list + 1] = w
		end
	end
	table.sort(list, function(a, b)
		return (r[a.address] or math.huge) < (r[b.address] or math.huge)
	end)
	return list
end

-----------------------------------------------------------------------
-- Publishing tag state to the hyprtagger plugin
--
-- Without the plugin this does nothing and hyprtagger.lua works on its own. With
-- it, bars using ext-workspace-v1 see every viewed tag as active, occupied
-- tags as shown and empty tags as hidden.
-----------------------------------------------------------------------

local function plugin()
	local p = hl.plugin and hl.plugin.hyprtagger
	if p and p.set_state then
		return p
	end
end

-- `gone`: address of a window that is closing but still listed
local function publish(gone)
	local p = plugin()
	if not p then
		return
	end
	local occ = {}
	for _, w in ipairs(hl.get_windows()) do
		if managed(w) and w.address ~= gone then
			for k in pairs((wtags(w))) do
				occ[k] = true
			end
		end
	end
	local view, occupied = {}, {}
	for i = 1, NTAGS do
		if S.view.tags[i] then
			view[#view + 1] = i
		end
		if occ[i] then
			occupied[#occupied + 1] = i
		end
	end
	local ok, err = pcall(p.set_state, { view = view, occupied = occupied })
	if not ok then
		notify_err(err)
	end
end

-----------------------------------------------------------------------
-- Persistence (survives `hyprctl reload`, cleared on logout)
-----------------------------------------------------------------------

local function save(gone)
	publish(gone)
	-- Drop windows that no longer exist
	local alive, kept = {}, {}
	for _, w in ipairs(hl.get_windows()) do
		alive[w.address] = true
	end
	for _, a in ipairs(S.order) do
		if alive[a] then
			kept[#kept + 1] = a
		end
	end
	S.order = kept

	local out = { "return {\norder = {" }
	for _, a in ipairs(S.order) do
		out[#out + 1] = string.format("%q,", a)
	end
	out[#out + 1] = "},\npertag = {"
	for id, p in pairs(S.pertag) do
		out[#out + 1] =
			string.format("[%d] = { mfact = %.4f, nmaster = %d, layout = %q },", id, p.mfact, p.nmaster, p.layout)
	end
	out[#out + 1] = "},\nview = { primary = " .. S.view.primary .. ", tags = {"
	for k in pairs(S.view.tags) do
		out[#out + 1] = k .. ","
	end
	out[#out + 1] = "} },\n}\n"
	local f = io.open(STATE_FILE, "w")
	if f then
		f:write(table.concat(out))
		f:close()
	end
end

local function load()
	local alive = {}
	for _, w in ipairs(hl.get_windows()) do
		alive[w.address] = w
	end

	local chunk = loadfile(STATE_FILE)
	local ok, st = false, nil
	if chunk then
		ok, st = pcall(chunk)
	end
	if ok and type(st) == "table" then
		S.order = {}
		for _, a in ipairs(st.order or {}) do
			if alive[a] and not order_index(a) then
				S.order[#S.order + 1] = a
			end
		end
		for id, p in pairs(st.pertag or {}) do
			S.pertag[id] = { mfact = p.mfact, nmaster = p.nmaster, layout = p.layout }
		end
		if st.view and st.view.primary then
			local t = {}
			for _, k in ipairs(st.view.tags or {}) do
				t[k] = true
			end
			if next(t) then
				S.view = { tags = t, primary = st.view.primary }
			end
		end
	end

	-- Windows we know nothing about: append in on-screen reading order
	local unknown = {}
	for a, w in pairs(alive) do
		if not order_index(a) then
			unknown[#unknown + 1] = w
		end
	end
	table.sort(unknown, function(a, b)
		if a.at.x ~= b.at.x then
			return a.at.x < b.at.x
		end
		return a.at.y < b.at.y
	end)
	for _, w in ipairs(unknown) do
		S.order[#S.order + 1] = w.address
	end

	-- The screen is the source of truth for which tag is primary
	local aw = hl.get_active_workspace()
	if is_tag_ws(aw) and aw.id ~= S.view.primary then
		S.view = { tags = { [aw.id] = true }, primary = aw.id }
	end
end

-----------------------------------------------------------------------
-- Core: make the screen match the current view
-----------------------------------------------------------------------

local function realize()
	-- Tell the plugin first, so tag workspaces that are about to lose their
	-- windows to the primary one are kept alive and reported correctly
	publish()
	guarded(function()
		local p = S.view.primary
		local shown_ws = hl.get_active_workspace()
		local shown = shown_ws and shown_ws.id
		local was_focused = hl.get_active_window()

		for _, w in ipairs(hl.get_windows()) do
			if managed(w) then
				local tags, any = wtags(w)
				if not any then
					-- Window we've never tagged: its rule's tags, else where it is
					tags = rule_tags(w) or { [w.workspace.id] = true }
					set_tags(w, tags)
				end
				local h = home(tags)
				if w.workspace.id ~= h then
					-- A window leaving the workspace on screen would fade out, but
					-- Hyprland stops repainting it mid-fade and leaves a frozen
					-- "ghost". Skip the animation so it just disappears (like Mango);
					-- if the view switches workspace, the switch animates instead.
					local leaving = w.workspace.id == shown
					if leaving then
						hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = "1", window = sel(w) }))
					end
					hl.dispatch(hl.dsp.window.move({ workspace = h, follow = false, window = sel(w) }))
					if leaving then
						local s = sel(w)
						hl.timer(function()
							pcall(
								hl.dispatch,
								hl.dsp.window.set_prop({ prop = "no_anim", value = "unset", window = s })
							)
						end, { timeout = 400, type = "oneshot" })
					end
				end
			end
		end
		local aw = hl.get_active_workspace()
		if not aw or aw.id ~= p then
			hl.dispatch(hl.dsp.focus({ workspace = p }))
			-- Keep focus on the window you were using if it's still in view
			if was_focused and hl.get_window(sel(was_focused)) then
				local now = hl.get_window(sel(was_focused))
				if now.workspace and now.workspace.id == p then
					hl.dispatch(hl.dsp.focus({ window = sel(now) }))
				end
			end
		end
		-- Never leave focus on a window that just left the screen: give it
		-- to the top of the visible stack (or to nothing if the tag is empty)
		local fw = hl.get_active_window()
		if fw and fw.workspace and fw.workspace.id ~= p and not fw.workspace.special then
			local top = visible_sorted(true)[1]
			if top then
				hl.dispatch(hl.dsp.focus({ window = sel(top) }))
			else
				-- Tag is now empty. Hyprland can't clear focus directly, so hop
				-- to a throwaway empty workspace and back with animations off;
				-- coming back to an empty workspace leaves nothing focused. The
				-- throwaway workspace is removed automatically once left.
				local was = hl.get_config("animations.enabled")
				hl.config({ animations = { enabled = false } })
				hl.dispatch(hl.dsp.focus({ workspace = "name:tagsnull" }))
				hl.dispatch(hl.dsp.focus({ workspace = p }))
				hl.config({ animations = { enabled = was } })
			end
		end
	end)
	save()
end

-- Primary tag for a changed view, chosen so the screen switches to another
-- workspace when possible: the combined view is assembled off-screen and then
-- shown with the normal workspace animation, instead of windows popping in
-- and out of the current one. Prefers `preferred` (e.g. the tag just added).
local function switching_primary(tags, preferred)
	if preferred and tags[preferred] and preferred ~= S.view.primary then
		return preferred
	end
	local best
	for k in pairs(tags) do
		if k ~= S.view.primary and (not best or k < best) then
			best = k
		end
	end
	return best or S.view.primary
end

local function set_view(tags, primary)
	if primary == S.view.primary and same(tags, S.view.tags) then
		return
	end
	S.prev = { tags = copy(S.view.tags), primary = S.view.primary }
	S.view = { tags = tags, primary = primary }
	realize()
end

local function relayout()
	save()
	hl.dispatch(hl.dsp.layout("recalc"))
end

-----------------------------------------------------------------------
-- Layout: "lua:mtile"
-----------------------------------------------------------------------

-- Stack `list` vertically in a column at x with width w
local function column(list, area, x, w)
	local n = #list
	for i, t in ipairs(list) do
		local y0 = math.floor((i - 1) * area.h / n)
		local y1 = math.floor(i * area.h / n)
		t:place({ x = math.floor(x), y = area.y + y0, w = math.floor(w), h = y1 - y0 })
	end
end

local function slice(ts, from, to)
	local out = {}
	for i = from, to do
		out[#out + 1] = ts[i]
	end
	return out
end

local function tile(ctx, ts, pt)
	local a, n = ctx.area, #ts
	local nm = math.min(pt.nmaster, n)
	local mw = (nm == 0) and 0 or ((n > nm) and math.floor(a.w * pt.mfact) or a.w)
	column(slice(ts, 1, nm), a, a.x, mw)
	column(slice(ts, nm + 1, n), a, a.x + mw, a.w - mw)
end

-- Master in the middle, stack alternating right/left (dwm centeredmaster)
local function center_tile(ctx, ts, pt)
	local a, n = ctx.area, #ts
	local nm = math.min(pt.nmaster, n)
	if nm == 0 or n - nm < 2 then
		return tile(ctx, ts, pt)
	end
	local mw = math.floor(a.w * pt.mfact)
	local sw = math.floor((a.w - mw) / 2)
	column(slice(ts, 1, nm), a, a.x + sw, mw)
	local right, left = {}, {}
	for i = nm + 1, n do
		if (i - nm) % 2 == 1 then
			right[#right + 1] = ts[i]
		else
			left[#left + 1] = ts[i]
		end
	end
	column(left, a, a.x, sw)
	column(right, a, a.x + sw + mw, a.w - sw - mw)
end

local LAYOUTS = { tile = tile, center_tile = center_tile }

hl.layout.register("mtile", {
	recalculate = function(ctx)
		local ts = {}
		for _, t in ipairs(ctx.targets) do
			ts[#ts + 1] = t
		end
		if #ts == 0 then
			return
		end

		for _, t in ipairs(ts) do
			if t.window then
				order_add(t.window.address)
			end
		end
		local r = rank_map()
		local function rank(t)
			return (t.window and r[t.window.address]) or (#S.order + t.index)
		end
		table.sort(ts, function(a, b)
			return rank(a) < rank(b)
		end)

		local ws = ts[1].window and ts[1].window.workspace
		local pt = pertag(ws and ws.id or S.view.primary)
		local fn = LAYOUTS[pt.layout] or tile
		fn(ctx, ts, pt)
	end,
	-- Any message just forces a recalculation (used by relayout())
	layout_msg = function(ctx, msg)
		return true
	end,
})

-----------------------------------------------------------------------
-- Commands
-----------------------------------------------------------------------

-- SUPER + k views tag k. If other digit keys are being held at the same
-- time (SUPER + 1 + 2), view all held tags together instead. The first
-- tag you pressed stays primary, so the screen doesn't switch away.
function M.view(k)
	local held = { [k] = true }
	local chord = false
	for i = 1, NTAGS do
		if i ~= k and hl.is_key_down(tostring(i)) then
			held[i] = true
			chord = true
		end
	end
	if not chord then
		return set_view({ [k] = true }, k)
	end
	set_view(held, switching_primary(held, k))
end

function M.toggleview(k)
	local t = copy(S.view.tags)
	t[k] = (not t[k]) or nil
	if not next(t) then
		return
	end
	set_view(t, switching_primary(t, t[k] and k or nil))
end

function M.view_all()
	local t = {}
	for i = 1, NTAGS do
		t[i] = true
	end
	set_view(t, switching_primary(t))
end

function M.view_prev()
	if S.prev then
		set_view(S.prev.tags, S.prev.primary)
	end
end

local function retag_active(fn)
	local w = hl.get_active_window()
	if not managed(w) then
		return
	end
	local t = fn(wtags(w))
	if not t or not next(t) then
		return
	end
	guarded(set_tags, w, t)
	realize()
end

-- Move the focused window to tag k. With cfg.follow_tag (Mango default),
-- the view follows the window to its new tag and keeps it focused.
function M.tag(k)
	local w = hl.get_active_window()
	if not managed(w) then
		return
	end
	if not cfg.follow_tag then
		return retag_active(function()
			return { [k] = true }
		end)
	end
	guarded(set_tags, w, { [k] = true })
	if S.view.primary == k and same(S.view.tags, { [k] = true }) then
		realize()
	else
		set_view({ [k] = true }, k)
	end
	guarded(function()
		hl.dispatch(hl.dsp.focus({ window = sel(w) }))
	end)
end

function M.toggletag(k)
	retag_active(function(t)
		t[k] = (not t[k]) or nil
		return t
	end)
end

function M.tag_all()
	retag_active(function()
		local t = {}
		for i = 1, NTAGS do
			t[i] = true
		end
		return t
	end)
end

-- Move focused window to master; if it already is master, promote the next one
function M.zoom()
	local w = hl.get_active_window()
	if not w or w.floating then
		return
	end
	local list = visible_sorted(false)
	if #list < 2 then
		return
	end
	local target = w.address
	if list[1].address == target then
		target = list[2].address
	end
	order_remove(target)
	table.insert(S.order, 1, target)
	relayout()
	hl.dispatch(hl.dsp.focus({ window = "address:" .. target }))
end

function M.focusstack(d)
	local list = visible_sorted(true)
	local w = hl.get_active_window()
	if #list < 2 or not w then
		return
	end
	for i, x in ipairs(list) do
		if x.address == w.address then
			local nxt = list[(i - 1 + d) % #list + 1]
			hl.dispatch(hl.dsp.focus({ window = "address:" .. nxt.address }))
			return
		end
	end
end

function M.movestack(d)
	local list = visible_sorted(false)
	local w = hl.get_active_window()
	if #list < 2 or not w or w.floating then
		return
	end
	for i, x in ipairs(list) do
		if x.address == w.address then
			local other = list[(i - 1 + d) % #list + 1]
			local a, b = order_index(w.address), order_index(other.address)
			S.order[a], S.order[b] = S.order[b], S.order[a]
			relayout()
			return
		end
	end
end

function M.setmfact(d)
	local p = pertag(S.view.primary)
	p.mfact = math.max(0.1, math.min(0.9, p.mfact + d))
	relayout()
end

function M.incnmaster(d)
	local p = pertag(S.view.primary)
	p.nmaster = math.max(0, p.nmaster + d)
	relayout()
end

function M.cycle_layout()
	local p = pertag(S.view.primary)
	for i, name in ipairs(cfg.layouts) do
		if name == p.layout then
			p.layout = cfg.layouts[i % #cfg.layouts + 1]
			return relayout()
		end
	end
	p.layout = cfg.layouts[1]
	relayout()
end

-- For bars / debugging: `hyprctl repl 'return tags.status()'`
function M.status()
	local v = {}
	for k in pairs(S.view.tags) do
		v[#v + 1] = k
	end
	table.sort(v)
	local p = pertag(S.view.primary)
	return string.format(
		"view=%s primary=%d layout=%s nmaster=%d mfact=%.2f",
		table.concat(v, ","),
		S.view.primary,
		p.layout,
		p.nmaster,
		p.mfact
	)
end

-----------------------------------------------------------------------
-- Events
-----------------------------------------------------------------------

hl.on("window.open", function(w)
	if busy > 0 or not managed(w) then
		return
	end
	order_add(w.address)
	local t, tagged = wtags(w)
	if not tagged then
		-- A `tags` rule decides the starting tags; otherwise new windows get
		-- the tags being viewed (dwl/Mango), and windows a workspace rule sent
		-- elsewhere get that workspace's tag.
		local ws = w.workspace.id
		t = rule_tags(w) or ((ws == S.view.primary) and copy(S.view.tags) or { [ws] = true })
		guarded(set_tags, w, t)
	end
	if w.workspace.id ~= home(t) then
		realize()
	else
		save()
	end
end)

local function forget(w)
	if w and w.address then
		order_remove(w.address)
		save(w.address)
	end
end
hl.on("window.close", forget)
hl.on("window.destroy", forget)

-- Something other than us moved a window (old-style dispatcher, drag, rule):
-- treat the destination as its new tag
hl.on("window.move_to_workspace", function(w, ws)
	if busy > 0 or not w or not is_tag_ws(ws) then
		return
	end
	local _, tagged = wtags(w)
	if not tagged then
		-- Not adopted yet; window.open (or realize) assigns its starting tags
		return
	end
	if home(wtags(w)) == ws.id then
		return
	end
	local t = (ws.id == S.view.primary) and copy(S.view.tags) or { [ws.id] = true }
	guarded(set_tags, w, t)
	if ws.id ~= S.view.primary and S.view.tags[ws.id] then
		realize()
	else
		save()
	end
end)

-- Workspace switched by something other than us (bar click, urgent window):
-- follow it as a single-tag view
hl.on("workspace.active", function(ws)
	if busy > 0 or not is_tag_ws(ws) or ws.id == S.view.primary then
		return
	end
	set_view({ [ws.id] = true }, ws.id)
end)

-----------------------------------------------------------------------
-- Setup
-----------------------------------------------------------------------

hl.config({ general = { layout = "lua:mtile" } })

-- Restore state right away, so the first layout pass after a reload already
-- uses the saved order and per-tag settings
do
	local ok, err = pcall(load)
	if not ok then
		notify_err(err)
	end
end

-- If the hyprtagger plugin gets loaded (or reloaded) after us, hand it the
-- current state. Cheap: only acts when the plugin is present but empty.
hl.timer(function()
	local p = plugin()
	if p and p.has_state and not p.has_state() then
		publish()
	end
end, { timeout = 1000, type = "repeat" })

M.publish = publish

-- Moving windows / switching has to wait until the compositor is fully up
hl.timer(function()
	local ok, err = pcall(function()
		realize()
		relayout()
	end)
	if not ok then
		notify_err(err)
	end
end, { timeout = 50, type = "oneshot" })

-- Keybinds
local mod = "SUPER"
local function safe(fn, ...)
	local args = { ... }
	return function()
		local ok, err = pcall(fn, table.unpack(args))
		if not ok then
			notify_err(err)
		end
	end
end

for i = 1, NTAGS do
	hl.bind(mod .. " + " .. i, safe(M.view, i))
	hl.bind(mod .. " + CTRL + " .. i, safe(M.toggleview, i))
	hl.bind(mod .. " + SHIFT + " .. i, safe(M.tag, i))
	hl.bind(mod .. " + CTRL + SHIFT + " .. i, safe(M.toggletag, i))
end
hl.bind(mod .. " + 0", safe(M.view_all))
hl.bind(mod .. " + SHIFT + 0", safe(M.tag_all))
hl.bind(mod .. " + Tab", safe(M.view_prev))

hl.bind(mod .. " + Return", safe(M.zoom))
hl.bind(mod .. " + Down", safe(M.focusstack, 1))
hl.bind(mod .. " + Up", safe(M.focusstack, -1))
hl.bind(mod .. " + SHIFT + Down", safe(M.movestack, 1))
hl.bind(mod .. " + SHIFT + Up", safe(M.movestack, -1))
hl.bind(mod .. " + Left", safe(M.setmfact, -0.05))
hl.bind(mod .. " + Right", safe(M.setmfact, 0.05))
hl.bind(mod .. " + I", safe(M.incnmaster, 1))
hl.bind(mod .. " + D", safe(M.incnmaster, -1))
hl.bind(mod .. " + Space", safe(M.cycle_layout))

_G.hyprtagger = M
_G.tags = M -- short alias for `hyprctl repl 'return tags.status()'`
return M
