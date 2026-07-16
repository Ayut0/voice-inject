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
# Contents/Resources/, not Contents/MacOS/: see the comment on
# AppModel.daemonBinaryURL() for why the daemon can't live next to
# VoiceInjectApp in Contents/MacOS/.
cp "$REPO_ROOT/voice-inject" "$APP/Contents/Resources/voice-inject"

echo "Ad-hoc signing..."
# The daemon binary needs its own signature: it's a loose executable
# under Contents/Resources/, not a nested bundle, so the outer --deep
# sign below only seals it as a resource (content hash) rather than
# re-signing it as code - leaving its original go-build signature
# invalid the moment `cp` changes its containing path, and the OS
# refuses to exec a binary whose embedded signature doesn't verify.
codesign --force --sign - "$APP/Contents/Resources/voice-inject"
codesign --force --deep --sign - "$APP"

echo "Done: $(pwd)/$APP"
