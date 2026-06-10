.PHONY: build build-release deploy install test swift-test format lint check clean

build:
	swift build --arch arm64

build-release:
	./generate.sh --ignore-xcodeproj --ignore-cmd-help --ignore-shell-parser
	swift build -c release --arch arm64 --product aerospace
	xcodebuild clean build -scheme AeroSpace -destination "generic/platform=macOS" -configuration Release -derivedDataPath .xcode-build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual
	rm -rf .release && mkdir .release
	cp -r ".xcode-build/Build/Products/Release/AeroSpace.app" .release
	cp -r .build/arm64-apple-macosx/release/aerospace .release

deploy: build-release install

install:
	osascript -e 'tell application "AeroSpace" to quit' 2>/dev/null || true
	pkill -x AeroSpace 2>/dev/null || true
	sleep 1
	rm -rf /Applications/AeroSpace.app
	cp -r .release/AeroSpace.app /Applications/AeroSpace.app
	cp .release/aerospace /opt/homebrew/bin/aerospace
	open /Applications/AeroSpace.app

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
	rm -rf .release .xcode-build .build
