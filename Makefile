APP     := Claudex
BUNDLE  := build/$(APP).app
BIN     := .build/release/claudex
ICONSET := build/$(APP).iconset
ICNS    := build/$(APP).icns
PLIST   := $(BUNDLE)/Contents/Info.plist

# Marketing version is set by hand; the build number is the commit count, which rises on every
# commit and never repeats. macOS compares it when deciding whether a login item has changed.
VERSION := 0.1.0
BUILD   := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

# swift-testing ships with the toolchain but sits outside the default search paths under
# Command Line Tools, and Testing.framework loads lib_TestingInterop.dylib by rpath. Naming
# both directories is what turns "no such module 'Testing'" into a test run. Under a full
# Xcode the frameworks are already on the path, so the flags stay empty there.
DEVDIR   := $(shell xcode-select -p)
TESTFW   := $(wildcard $(DEVDIR)/Library/Developer/Frameworks)
TESTLIB  := $(DEVDIR)/Library/Developer/usr/lib
TESTARGS := $(if $(TESTFW),-Xswiftc -F -Xswiftc $(TESTFW) -Xlinker -rpath -Xlinker $(TESTFW) -Xlinker -rpath -Xlinker $(TESTLIB))

.PHONY: all build test icon bundle install uninstall verify run prototype clean

all: bundle

build:
	swift build -c release

test:
	swift test $(TESTARGS)

# The binary draws its own icon, so the mark cannot drift from the ring in the menu bar.
icon: build
	rm -rf $(ICONSET) $(ICNS)
	mkdir -p $(ICONSET)
	$(BIN) --appicon build/icon-1024.png
	for size in 16 32 128 256 512; do \
	  sips -z $$size $$size build/icon-1024.png --out $(ICONSET)/icon_$${size}x$${size}.png >/dev/null; \
	  double=$$((size * 2)); \
	  sips -z $$double $$double build/icon-1024.png --out $(ICONSET)/icon_$${size}x$${size}@2x.png >/dev/null; \
	done
	iconutil -c icns $(ICONSET) -o $(ICNS)

bundle: build icon
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/claudex
	cp Resources/Info.plist $(PLIST)
	cp $(ICNS) $(BUNDLE)/Contents/Resources/$(APP).icns
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(PLIST)
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD)" $(PLIST)
	# Ad-hoc, because there is no Developer ID here and the app is built where it runs. The
	# signature still has to be stable across a copy, which is what SMAppService checks.
	codesign --force --sign - --options runtime $(BUNDLE) 2>/dev/null || \
	  codesign --force --sign - $(BUNDLE)
	@echo "built $(BUNDLE) ($(VERSION) build $(BUILD))"

verify: bundle
	codesign --verify --deep --strict --verbose=2 $(BUNDLE)
	@/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $(PLIST) | sed 's/^/build /'

# SMAppService keys a login item to the bundle's location, so the app has to live somewhere
# stable for "launch at login" to survive. /Applications is that place.
install: bundle
	pkill -x claudex 2>/dev/null || true
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/
	open /Applications/$(APP).app
	@echo "installed /Applications/$(APP).app"

uninstall:
	pkill -x claudex 2>/dev/null || true
	rm -rf /Applications/$(APP).app
	@echo "removed /Applications/$(APP).app"
	@echo "turn off Launch at login before uninstalling, or clear it in System Settings > General > Login Items"
	@echo "accounts and tokens are left in ~/Library/Application Support/claudex and the Keychain"

run: bundle
	pkill -x claudex 2>/dev/null || true
	open $(BUNDLE)

prototype:
	open Sources/claudex/App/UsagePopover.prototype.html

clean:
	rm -rf .build build
