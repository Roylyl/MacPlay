#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

PKG_CONFIG_BIN="${PKG_CONFIG:-pkg-config}"
GST_LIBDIR="$("$PKG_CONFIG_BIN" --variable=libdir gstreamer-1.0)"
GST_RUNTIME="${MACPLAY_GSTREAMER_RUNTIME:-$PWD/assets/gstreamer/macos-arm64}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macplay-resize.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
read -r -a GST_CFLAGS <<< "$("$PKG_CONFIG_BIN" --cflags gstreamer-app-1.0 gstreamer-video-1.0)"
read -r -a GST_LIBS <<< "$("$PKG_CONFIG_BIN" --libs gstreamer-app-1.0 gstreamer-video-1.0)"
BASELINE=0
if [[ -n "${MACPLAY_WINDOW_SOURCE:-}" ]]; then BASELINE=1; fi
clang++ -std=c++17 -Wno-deprecated-declarations -mmacosx-version-min=14.0 \
  "${GST_CFLAGS[@]}" "-DMACPLAY_WINDOW_SOURCE=\"${MACPLAY_WINDOW_SOURCE:-gst_video_mac.mm}\"" \
  "-DMACPLAY_RESIZE_BASELINE=$BASELINE" \
  -Inative/livi-gst-video/src \
  native/livi-gst-video/src/macplay_resize.test.mm \
  "${GST_LIBS[@]}" -Wl,-rpath,"$GST_LIBDIR" \
  -framework Cocoa -framework QuartzCore -framework AVFoundation \
  -o "$TEST_DIR/macplay-resize"

DYLD_LIBRARY_PATH="$GST_RUNTIME/lib:$GST_LIBDIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
GST_PLUGIN_PATH="$GST_RUNTIME/lib/gstreamer-1.0" GST_PLUGIN_SYSTEM_PATH= \
GST_REGISTRY="$TEST_DIR/registry.bin" GST_REGISTRY_FORK=no \
  "$TEST_DIR/macplay-resize"
