#!/bin/zsh
# Builds without Xcode: SwiftPM can't run on Command Line Tools here (xcrun has no
# PlatformPath), so compile with swiftc directly.
#   ./build.sh          build Sony Log Monitor.app
#   ./build.sh check    build + run the self-check (color math + GPU vs CPU)
#   ./build.sh run      build + open the app
set -euo pipefail
cd "${0:a:h}"

BUILD=.build/manual
APP="$BUILD/Bon Log Monitor.app"
mkdir -p "$BUILD"
SWIFTC=(swiftc -O -target arm64-apple-macos13.0)
# Local fix: CLT ships a stale usr/include/swift/module.modulemap that redefines
# SwiftBridging; hide it with a VFS overlay instead of editing system files.
if [[ -f /Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap ]]; then
  mkdir -p "$BUILD/vfs" && : > "$BUILD/vfs/empty.modulemap"
  print -r -- "{ \"version\": 0, \"roots\": [ { \"name\": \"/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap\", \"type\": \"file\", \"external-contents\": \"$PWD/$BUILD/vfs/empty.modulemap\" } ] }" > "$BUILD/vfs/overlay.yaml"
  SWIFTC+=(-vfsoverlay "$PWD/$BUILD/vfs/overlay.yaml" -Xcc -ivfsoverlay -Xcc "$PWD/$BUILD/vfs/overlay.yaml")
fi

"${SWIFTC[@]}" -parse-as-library -module-name MonitorCore \
  -emit-library -static -emit-module -emit-module-path "$BUILD/MonitorCore.swiftmodule" \
  -o "$BUILD/libMonitorCore.a" Sources/MonitorCore/*.swift

"${SWIFTC[@]}" -I "$BUILD" -L "$BUILD" -lMonitorCore \
  -o "$BUILD/SelfCheck" Sources/SelfCheck/*.swift

# Camera control goes through libgphoto2 (brew install gphoto2): Sony's own SDK
# rejects the original ZV-E10.
BREW=$(brew --prefix)
[[ -f $BREW/include/gphoto2/gphoto2.h ]] || { echo "libgphoto2 missing: brew install gphoto2"; exit 1; }
clang -O2 -target arm64-apple-macos13.0 -I "$BREW/include" -c Sources/GPhotoBridge/gpbridge.c -o "$BUILD/gpbridge.o"

"${SWIFTC[@]}" -parse-as-library -I "$BUILD" -L "$BUILD" -lMonitorCore \
  -import-objc-header Sources/GPhotoBridge/gpbridge.h "$BUILD/gpbridge.o" \
  -L "$BREW/lib" -lgphoto2 -lgphoto2_port \
  -o "$BUILD/SonyLogMonitor" Sources/SonyLogMonitor/*.swift

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BUILD/SonyLogMonitor" "$APP/Contents/MacOS/SonyLogMonitor"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"

build_probe() {
  local sdk=Vendor/CrSDK
  [[ -d $sdk ]] || { echo "Sony SDK missing: put headers in $sdk/include and dylibs in $sdk/lib"; exit 1; }
  mkdir -p "$BUILD/probe"
  cp -R "$sdk/lib/" "$BUILD/probe/"
  clang++ -std=c++17 -O1 -I "$sdk/include" -L "$BUILD/probe" -lCr_Core \
    -Wl,-rpath,@executable_path -o "$BUILD/probe/probe" Tools/probe.cpp
}

case "${1:-}" in
  check) "$BUILD/SelfCheck" ;;
  probe)
    build_probe
    # USB serial of a plugged-in Sony camera (vendor 1356), for the direct-connect fallback.
    serial=$(ioreg -p IOUSB -l -w0 | awk '/\+-o /{ser=""} /kUSBSerialNumberString/{gsub(/"/,"",$NF); ser=$NF} /"USB Vendor Name" = "Sony"/{print ser; exit}')
    (cd "$BUILD/probe" && ./probe ${serial:-}) ;;
  run) open "$APP" ;;
esac
