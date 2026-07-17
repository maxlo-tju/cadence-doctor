#!/bin/zsh
# Builds Cadence Doctor.app from source. Requires Xcode Command Line Tools.
set -e
cd "$(dirname "$0")"
APP="Cadence Doctor.app"

mkdir -p build
echo "Compiling arm64…"
swiftc -O -swift-version 5 -parse-as-library \
    -target arm64-apple-macosx13.0 \
    Sources/CadenceDoctorApp.swift \
    -o build/CadenceDoctor-arm64
echo "Compiling x86_64…"
swiftc -O -swift-version 5 -parse-as-library \
    -target x86_64-apple-macosx13.0 \
    Sources/CadenceDoctorApp.swift \
    -o build/CadenceDoctor-x86_64
lipo -create build/CadenceDoctor-arm64 build/CadenceDoctor-x86_64 \
    -output build/CadenceDoctor

# Regenerate icon if missing
if [ ! -f AppIcon.icns ]; then
    swift IconGen.swift icon_1024.png
    rm -rf AppIcon.iconset && mkdir AppIcon.iconset
    for s in 16 32 128 256 512; do
        sips -z $s $s icon_1024.png --out AppIcon.iconset/icon_${s}x${s}.png >/dev/null
        d=$((s*2))
        sips -z $d $d icon_1024.png --out AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
    done
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp build/CadenceDoctor "$APP/Contents/MacOS/CadenceDoctor"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Embed ffmpeg/ffprobe + dylibs if vendored (run ./bundle_ffmpeg.sh to create)
if [ -d vendor/Helpers ]; then
    mkdir -p "$APP/Contents/Helpers"
    cp -R vendor/Helpers/ "$APP/Contents/Helpers/"
    for f in "$APP/Contents/Helpers"/*; do
        codesign --force -s - "$f"
    done
fi

codesign --force -s - "$APP"
echo "Built: $(pwd)/$APP"
