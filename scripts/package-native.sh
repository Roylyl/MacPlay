#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET_ARCH="${MACPLAY_ARCH:-$(uname -m)}"
case "$TARGET_ARCH" in x64) TARGET_ARCH=x86_64;; aarch64) TARGET_ARCH=arm64;; esac
REQUIRED_ARCHES=("$TARGET_ARCH")
if [[ "$TARGET_ARCH" == universal ]]; then REQUIRED_ARCHES=(arm64 x86_64); fi
source scripts/prepare-macos-runtime.sh
NODE_BIN="${MACPLAY_NODE_BIN:-$NODE_BIN}"
APP="${MACPLAY_APP_OUTPUT:-$PWD/dist/MacPlay.app}"
RES="$APP/Contents/Resources"
RECEIVER="$RES/runtime/MacPlayReceiver.app"
mkdir -p "$APP/Contents/MacOS" "$RES/runtime" "$RES/engine/node_modules" "$RES/driver" "$RES/gstreamer"
cp build/MacPlay "$APP/Contents/MacOS/MacPlay"
mkdir -p "$RECEIVER/Contents/MacOS" "$RECEIVER/Contents/Resources"
cp "$NODE_BIN" "$RECEIVER/Contents/MacOS/MacPlayReceiver"
rm -f "$RES/runtime/node"
cp assets/icons/mac/macplay.icns "$RECEIVER/Contents/Resources/MacPlay.icns"
cat > "$RECEIVER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.roylyl.macplay.receiver</string>
<key>CFBundleName</key><string>MacPlay</string><key>CFBundleDisplayName</key><string>MacPlay</string>
<key>CFBundleExecutable</key><string>MacPlayReceiver</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.4</string><key>CFBundleVersion</key><string>41</string>
<key>CFBundleIconFile</key><string>MacPlay</string><key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/><key>NSHighResolutionCapable</key><true/>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>zh-Hant</string></array>
<key>NSLocalNetworkUsageDescription</key><string>MacPlay通过本地网络接收iPhone的CarPlay音视频。</string>
<key>NSMicrophoneUsageDescription</key><string>MacPlay使用麦克风进行语音控制和通话。</string>
</dict></plist>
PLIST
cp -R build/engine/. "$RES/engine/"
node scripts/package-engine-dependencies.mjs "$RES/engine/node_modules"
for mod in livi-crypto livi-gst-video; do
 mkdir -p "$RES/engine/node_modules/$mod/build/Release"
 cp "native/$mod/index.js" "native/$mod/package.json" "$RES/engine/node_modules/$mod/"
 cp "native/$mod/build/Release/"*.node "$RES/engine/node_modules/$mod/build/Release/"
done
HELPERD_BIN="${MACPLAY_HELPERD_BIN:-native/livi-helperd/target/release/livi-helperd}"
if [[ ! -f "$HELPERD_BIN" && -f "native/livi-helperd/target/x86_64-apple-darwin/release/livi-helperd" ]]; then
  HELPERD_BIN="native/livi-helperd/target/x86_64-apple-darwin/release/livi-helperd"
elif [[ ! -f "$HELPERD_BIN" && -f "native/livi-helperd/target/aarch64-apple-darwin/release/livi-helperd" ]]; then
  HELPERD_BIN="native/livi-helperd/target/aarch64-apple-darwin/release/livi-helperd"
fi
cp "$HELPERD_BIN" native/macplay-bluetooth/macplay-bluetooth "$RES/driver/"

# Refuse a package whose runtime cannot execute on its advertised architecture.
for required in "${REQUIRED_ARCHES[@]}"; do
  for binary in "$APP/Contents/MacOS/MacPlay" "$RECEIVER/Contents/MacOS/MacPlayReceiver" "$RES/driver/"* "$RES/engine/node_modules/"*/build/Release/*.node; do
    lipo -verify_arch "$required" "$binary"
  done
done
rm -rf "$RES/gstreamer"
mkdir -p "$RES/gstreamer"
cp -R assets/gstreamer/macos-arm64 "$RES/gstreamer/macos-arm64"
ln -sfn macos-arm64 "$RES/gstreamer/macos-x64"
if [[ -n "${MACPLAY_GSTREAMER_EXTRA:-}" ]]; then
  cp -R "$MACPLAY_GSTREAMER_EXTRA/lib/." "$RES/gstreamer/macos-arm64/lib/"
fi
if [[ -n "${MACPLAY_APPLEMEDIA_UNIVERSAL:-}" ]]; then
  cp "$MACPLAY_APPLEMEDIA_UNIVERSAL" "$RES/gstreamer/macos-arm64/lib/gstreamer-1.0/libgstapplemedia.dylib"
fi
for required in "${REQUIRED_ARCHES[@]}"; do
  while IFS= read -r -d '' binary; do
    lipo -verify_arch "$required" "$binary"
  done < <(find "$RES/gstreamer/macos-arm64" -type f \( -name '*.dylib' -o -name 'gst-*' \) -print0)
done

cp assets/icons/mac/macplay.icns "$RES/MacPlay.icns"
mkdir -p "$RES/donation"
cp assets/donation/wechat.jpg assets/donation/alipay.jpg assets/donation/alipayhk.jpg "$RES/donation/"
cp -R native/App/Resources/*.lproj "$RES/"
cp -R native/App/Resources/*.lproj "$RECEIVER/Contents/Resources/"
mkdir -p "$RES/icons"
cp assets/icons/carplay/macplay-256.png assets/icons/carplay/macplay-512.png "$RES/icons/"
mkdir -p "$RES/authentication"
cp assets/authentication/identity.pk8 assets/authentication/certificate.p7b assets/authentication/SOURCE.txt "$RES/authentication/"
cp LICENSE NOTICE "$RES/"
cp -R assets/licenses "$RES/ThirdParty-LICENSES"
cp -R assets/gstreamer/LICENSES "$RES/GStreamer-LICENSES"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.roylyl.macplay</string>
<key>CFBundleName</key><string>MacPlay</string><key>CFBundleDisplayName</key><string>MacPlay</string>
<key>CFBundleExecutable</key><string>MacPlay</string><key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.4</string><key>CFBundleVersion</key><string>41</string>
<key>CFBundleIconFile</key><string>MacPlay</string><key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>zh-Hant</string></array>
<key>NSBluetoothAlwaysUsageDescription</key><string>MacPlay通过Mac蓝牙与iPhone建立CarPlay连接。</string>
<key>NSLocalNetworkUsageDescription</key><string>MacPlay通过本地网络接收iPhone的CarPlay音视频。</string>
<key>NSLocationUsageDescription</key><string>macOS要求定位权限才能读取当前Wi-Fi名称。MacPlay仅用此权限读取网络信息，不保存位置信息。</string>
<key>NSLocationWhenInUseUsageDescription</key><string>macOS要求定位权限才能读取当前Wi-Fi名称。MacPlay仅用此权限读取网络信息，不保存位置信息。</string>
<key>NSMicrophoneUsageDescription</key><string>MacPlay使用麦克风进行Siri语音控制和通话。</string>
</dict></plist>
PLIST
ADDON="$RES/engine/node_modules/livi-gst-video/build/Release/gst_video.node"
while IFS= read -r rp; do install_name_tool -delete_rpath "$rp" "$ADDON" 2>/dev/null || true; done < <(otool -l "$ADDON" | awk '/LC_RPATH/{getline;getline;print $2}')
install_name_tool -add_rpath '@loader_path/../../../../../gstreamer/macos-x64/lib' "$ADDON"
install_name_tool -add_rpath '@loader_path/../../../../../gstreamer/macos-arm64/lib' "$ADDON"
for bin in "$RECEIVER/Contents/MacOS/MacPlayReceiver" "$RES/driver/"* "$RES/engine/node_modules/"*/build/Release/*.node; do codesign --force --sign - "$bin"; done
codesign --force --sign - "$RECEIVER"
codesign --force --deep --sign - "$APP"
if [[ "${1:-}" != "--app-only" ]]; then
 mkdir -p build/dmg
 ln -sfn /Applications build/dmg/Applications
 rm -rf build/dmg/MacPlay.app
 ditto "$APP" build/dmg/MacPlay.app

 hdiutil create -ov -volname MacPlay -srcfolder build/dmg -format UDZO "dist/MacPlay-1.2.4-${TARGET_ARCH}.dmg"
fi
