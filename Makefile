CXXFLAGS ?= -O2 -g
CXXFLAGS += -shared -fPIC --no-gnu-unique -std=c++2b -Wall
PKGS = pixman-1 libdrm hyprland pangocairo libinput libudev wayland-server xkbcommon

all: hyprtagger.so

# Build to a temp file and rename, so a running Hyprland that has the old
# .so mapped is never handed a half-written file.
hyprtagger.so: main.cpp
	$(CXX) $(CXXFLAGS) main.cpp -o $@.tmp `pkg-config --cflags $(PKGS)`
	mv -f $@.tmp $@

clean:
	rm -f hyprtagger.so hyprtagger.so.tmp

.PHONY: all clean
