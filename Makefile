# StageSolo — builds a universal (Apple silicon + Intel) app bundle.
#   make           build build/StageSolo.app
#   make install   copy it to ~/Applications and start it
#   make clean
# Signing: if your keychain has a code-signing certificate named "StageSolo Dev", builds are signed with
# it and macOS keeps the Accessibility permission across rebuilds. Otherwise builds are ad-hoc signed and
# macOS treats each one as a new app: after installing, remove StageSolo from System Settings → Privacy &
# Security → Accessibility and allow it again.

APP        := build/StageSolo.app
BIN        := $(APP)/Contents/MacOS/StageSolo
DEST       := $(HOME)/Applications/StageSolo.app
SWIFTC     := swiftc -swift-version 5 -O
SIGN       := $(shell security find-certificate -c "StageSolo Dev" >/dev/null 2>&1 && echo "StageSolo Dev" || echo -)
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: all install clean

all: $(BIN)

$(BIN): StageSolo.swift Info.plist
	mkdir -p $(APP)/Contents/MacOS
	$(SWIFTC) -target arm64-apple-macos13.0 StageSolo.swift -o build/StageSolo-arm64
	$(SWIFTC) -target x86_64-apple-macos13.0 StageSolo.swift -o build/StageSolo-x86_64
	lipo -create build/StageSolo-arm64 build/StageSolo-x86_64 -output $(BIN)
	cp Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign "$(SIGN)" $(APP)

install: $(BIN)
	-pkill -x StageSolo
	rm -rf "$(DEST)"
	cp -R $(APP) "$(DEST)"
	$(LSREGISTER) -f "$(DEST)"
	open "$(DEST)"

clean:
	rm -rf build
