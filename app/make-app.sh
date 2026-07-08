#!/bin/sh
# Assembles VoiceInject.app: SwiftUI app + bundled Go daemon.
set -eu

cd "$(dirname "$0")"
REPO_ROOT=$(cd .. && pwd)

echo "Building Go daemon..."
(cd "$REPO_ROOT" && go build ./cmd/voice-inject)

echo "Building Swift app..."
swift build -c release

APP=VoiceInject.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Info.plist "$APP/Contents/Info.plist"
cp .build/release/VoiceInject "$APP/Contents/MacOS/VoiceInjectApp"
cp "$REPO_ROOT/voice-inject" "$APP/Contents/MacOS/voice-inject"

echo "Ad-hoc signing..."
codesign --force --deep --sign - "$APP"

echo "Done: $(pwd)/$APP"
