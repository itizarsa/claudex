APP     := Claudex
BUNDLE  := build/$(APP).app
BIN     := .build/release/claudex
ICONSET := build/$(APP).iconset
ICNS    := build/$(APP).icns
PLIST   := $(BUNDLE)/Contents/Info.plist
ZIP     := build/$(APP)-$(VERSION).zip

# Marketing version is set by hand; the build number is the commit count, which rises on every
# commit and never repeats. macOS compares it when deciding whether a login item has changed.
VERSION ?= 0.1.0
BUILD   := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

# A self-signed identity keeps the signature, and so Launch at login, stable across updates.
# Gatekeeper still treats it as unverified; the Homebrew cask clears quarantine instead.
# Without the certificate in a keychain, builds fall back to ad-hoc.
SIGN_IDENTITY ?= $(shell security find-certificate -c claudex-codesign >/dev/null 2>&1 && echo claudex-codesign || echo -)

# swift-testing ships with the toolchain but sits outside the default search paths under
# Command Line Tools, and Testing.framework loads lib_TestingInterop.dylib by rpath. Naming
# both directories is what turns "no such module 'Testing'" into a test run. Under a full
# Xcode the frameworks are already on the path, so the flags stay empty there.
DEVDIR   := $(shell xcode-select -p)
TESTFW   := $(wildcard $(DEVDIR)/Library/Developer/Frameworks)
TESTLIB  := $(DEVDIR)/Library/Developer/usr/lib
TESTARGS := $(if $(TESTFW),-Xswiftc -F -Xswiftc $(TESTFW) -Xlinker -rpath -Xlinker $(TESTFW) -Xlinker -rpath -Xlinker $(TESTLIB))

.PHONY: all build test icon bundle zip install uninstall verify run prototype clean

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
	# The signature has to be stable across a copy, which is what SMAppService checks.
	codesign --force --sign "$(SIGN_IDENTITY)" --options runtime $(BUNDLE)
	@echo "built $(BUNDLE) ($(VERSION) build $(BUILD), signed $(SIGN_IDENTITY))"

verify: bundle
	codesign --verify --deep --strict --verbose=2 $(BUNDLE)
	@/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $(PLIST) | sed 's/^/build /'

# The release asset the Homebrew cask installs.
zip: verify
	rm -f $(ZIP)
	ditto -c -k --keepParent $(BUNDLE) $(ZIP)
	@echo "built $(ZIP)"

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
	@echo "tokenmaxx accounts and credentials are untouched"

run: bundle
	pkill -x claudex 2>/dev/null || true
	open $(BUNDLE)

prototype:
	open Sources/claudex/App/UsagePopover.prototype.html

clean:
	rm -rf .build build
