CXXFLAGS ?= -O2 -g
CXXFLAGS += -shared -fPIC --no-gnu-unique -std=c++2b -Wall
PKGS = pixman-1 libdrm hyprland pangocairo libinput libudev wayland-server xkbcommon

all: hyprtagger.so

# Always rebuild: packaged headers retain build-time mtimes, so timestamps
# cannot reliably detect a Hyprland upgrade and prevent an API hash mismatch.
# Build to a temporary file and rename to preserve any currently mapped .so.
hyprtagger.so: FORCE
	$(CXX) $(CXXFLAGS) main.cpp -o $@.tmp `pkg-config --cflags $(PKGS)`
	mv -f $@.tmp $@

FORCE:

clean:
	rm -f hyprtagger.so hyprtagger.so.tmp

.PHONY: all clean FORCE
