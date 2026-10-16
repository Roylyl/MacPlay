#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
TARGET_ARCH="${MACPLAY_ARCH:-$(uname -m)}"
for arg in "$@"; do case "$arg" in --arch=*) TARGET_ARCH="${arg#*=}";; esac; done
case "$TARGET_ARCH" in x64|x86_64) ARCHES=(x86_64);; arm64|aarch64) ARCHES=(arm64);; universal) ARCHES=(arm64 x86_64);; *) echo "Unknown architecture: $TARGET_ARCH" >&2; exit 1;; esac
for arch in "${ARCHES[@]}"; do
  triple=aarch64-apple-darwin; node_arch=arm64
  if [[ "$arch" == x86_64 ]]; then triple=x86_64-apple-darwin; node_arch=x64; fi
  stage="build/architectures/$arch"
  mkdir -p "$stage"
  swiftc -parse-as-library -O -target "$arch-apple-macosx14.0" -framework SwiftUI -framework AppKit -framework CoreWLAN -framework SystemConfiguration -framework CoreLocation -framework IOKit -framework IOBluetooth -framework CoreAudio -framework MediaPlayer native/App/MacPlay.swift native/App/ApplicationLifecycle.swift native/App/About.swift native/App/Localization.swift native/App/ConnectionPolicy.swift native/App/AudioHardwareMonitor.swift native/App/DiagnosticRedactor.swift native/App/ReceiverCommandPipe.swift native/App/SystemQuery.swift native/App/DisplayCapabilities.swift native/App/NetworkInterfaces.swift native/App/NowPlayingState.swift native/App/NowPlayingFeed.swift -o "$stage/MacPlay"
  clang -fobjc-arc -arch "$arch" -mmacosx-version-min=14.0 -framework Foundation -framework AppKit -framework IOBluetooth -sectcreate __TEXT __info_plist native/macplay-bluetooth/Info.plist native/macplay-bluetooth/main.m -o "$stage/macplay-bluetooth"
  node scripts/build-native.mjs "--arch=$node_arch"
  cp native/livi-crypto/build/Release/livi_crypto.node native/livi-gst-video/build/Release/gst_video.node "$stage/"
  cargo build --release --target "$triple" --manifest-path native/livi-helperd/Cargo.toml -p livi-helperd
  cp "native/livi-helperd/target/$triple/release/livi-helperd" "$stage/"
done
mkdir -p build/combined
for name in MacPlay macplay-bluetooth livi_crypto.node gst_video.node livi-helperd; do
  if [[ ${#ARCHES[@]} == 2 ]]; then
    lipo -create "build/architectures/arm64/$name" "build/architectures/x86_64/$name" -output "build/combined/$name"
  else cp "build/architectures/${ARCHES[0]}/$name" "build/combined/$name"; fi
done
cp build/combined/MacPlay build/MacPlay
cp build/combined/macplay-bluetooth native/macplay-bluetooth/macplay-bluetooth
cp build/combined/livi_crypto.node native/livi-crypto/build/Release/livi_crypto.node
cp build/combined/gst_video.node native/livi-gst-video/build/Release/gst_video.node
node node_modules/typescript/bin/tsc -p native/Engine/tsconfig.json
export MACPLAY_ARCH="$TARGET_ARCH"
export MACPLAY_HELPERD_BIN="$PWD/build/combined/livi-helperd"
APP_ONLY=false
for arg in "$@"; do if [[ "$arg" == --app-only ]]; then APP_ONLY=true; fi; done
if $APP_ONLY; then bash scripts/package-native.sh --app-only
else bash scripts/package-native.sh; fi
