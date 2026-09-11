APP     := Claudex
BUNDLE  := build/$(APP).app
BIN     := .build/release/claudex

.PHONY: all build bundle install run prototype clean

all: bundle

build:
	swift build -c release

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/claudex
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - --options runtime $(BUNDLE) 2>/dev/null || \
	  codesign --force --sign - $(BUNDLE)
	@echo "built $(BUNDLE)"

install: bundle
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/
	@echo "installed /Applications/$(APP).app"

run: bundle
	pkill -x claudex 2>/dev/null || true
	open $(BUNDLE)

prototype:
	open Sources/claudex/App/UsagePopover.prototype.html

clean:
	rm -rf .build build
