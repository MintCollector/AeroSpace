.PHONY: build build-release deploy install test swift-test format lint check clean

# Stable local code-signing identity. A self-signed cert (vs ad-hoc "-") gives the app a
# stable designated requirement, so macOS Accessibility/TCC grants persist across rebuilds
# instead of re-prompting every deploy. Create once via Certificate Assistant or:
#   openssl req -x509 -newkey rsa:2048 -keyout k.key -out c.crt -days 3650 -nodes \
#     -subj "/CN=AeroSpace Local" -addext "extendedKeyUsage=critical,codeSigning"
#   openssl pkcs12 -export -legacy -out c.p12 -inkey k.key -in c.crt -passout pass:PW
#   security import c.p12 -k ~/Library/Keychains/login.keychain-db -P PW -T /usr/bin/codesign
# Override with: make deploy CODESIGN_IDENTITY="Developer ID Application: ..."
CODESIGN_IDENTITY ?= AeroSpace Local

build:
	swift build --arch arm64

build-release:
	./generate.sh --ignore-xcodeproj --ignore-cmd-help
	swift build -c release --arch arm64 --product aerospace
	cd ./xcode && xcodebuild clean build -scheme AeroSpace -destination "generic/platform=macOS" -configuration Release -derivedDataPath .xcode-build CODE_SIGN_IDENTITY="$(CODESIGN_IDENTITY)" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual
	rm -rf .release && mkdir .release
	cp -r "xcode/.xcode-build/Build/Products/Release/AeroSpace.app" .release
	cp -r "$$(swift build -c release --arch arm64 --show-bin-path)/aerospace" .release
	codesign --force --sign "$(CODESIGN_IDENTITY)" .release/aerospace
	codesign --verify --strict .release/AeroSpace.app
	codesign --verify --strict .release/aerospace

deploy: build-release install

# The restart drops every window onto a visible workspace: keep-windows puts each one back
# (workspace, order, layout, focus, aero-helper's labels). Retry with ./script/keep-windows.py restore
install:
	./script/keep-windows.py save
	osascript -e 'tell application "AeroSpace" to quit' 2>/dev/null || true
	pkill -x AeroSpace 2>/dev/null || true
	sleep 1
	mkdir -p /Applications/AeroSpace.app
	rsync -a --delete .release/AeroSpace.app/ /Applications/AeroSpace.app/
	cp .release/aerospace /opt/homebrew/bin/aerospace
	open /Applications/AeroSpace.app
	./script/keep-windows.py restore

test:
	./test.sh

swift-test:
	./swift-test.sh

format:
	./format.sh

lint:
	./lint.sh

check:
	swift build --arch arm64

clean:
	rm -rf .release xcode/.xcode-build .build
