#!/bin/bash
# Build build/AITodo.app dari Sources/AITodo/*.swift
# Syarat: macOS 13+ dengan Xcode Command Line Tools  →  xcode-select --install
# Opsi:   ARCH=universal ./scripts/build.sh   (arm64 + x86_64, dipakai di GitHub Actions)
set -e
cd "$(dirname "$0")/.."

APP="build/AITodo.app"
SRC=(Sources/AITodo/*.swift)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▶ Compile..."
if [ "${ARCH:-}" = "universal" ]; then
  swiftc -O -swift-version 5 -target arm64-apple-macos13.0  "${SRC[@]}" -o build/AITodo-arm64
  swiftc -O -swift-version 5 -target x86_64-apple-macos13.0 "${SRC[@]}" -o build/AITodo-x86_64
  lipo -create build/AITodo-arm64 build/AITodo-x86_64 -output "$APP/Contents/MacOS/AITodo"
  rm -f build/AITodo-arm64 build/AITodo-x86_64
else
  swiftc -O -swift-version 5 "${SRC[@]}" -o "$APP/Contents/MacOS/AITodo"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▶ Codesign (ad-hoc)..."
# designated requirement cukup identifier → izin notifikasi & Keychain tetap berlaku setelah update
codesign --force --sign - --identifier id.local.aitodo \
  --requirements '=designated => identifier "id.local.aitodo"' "$APP"

echo "✅ Selesai: $APP"
echo "   Pasang:  cp -R $APP /Applications/ && open /Applications/AITodo.app"
