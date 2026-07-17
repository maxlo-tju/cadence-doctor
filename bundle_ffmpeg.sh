#!/bin/zsh
# Bundles the local Homebrew ffmpeg/ffprobe plus their entire dylib closure
# into vendor/Helpers, rewriting install names to @loader_path so the tools
# run from inside the .app with no Homebrew installed.
set -e
cd "$(dirname "$0")"

SRC_FFMPEG=${SRC_FFMPEG:-/opt/homebrew/bin/ffmpeg}
SRC_FFPROBE=${SRC_FFPROBE:-/opt/homebrew/bin/ffprobe}
HELPERS=vendor/Helpers

rm -rf "$HELPERS"
mkdir -p "$HELPERS"
cp "$SRC_FFMPEG" "$HELPERS/ffmpeg"
cp "$SRC_FFPROBE" "$HELPERS/ffprobe"
chmod +w "$HELPERS"/*

deps_of() {
    otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -E '^/opt/homebrew|^/usr/local' || true
}

# Collect transitive dylib closure
typeset -A seen
queue=()
for b in "$HELPERS/ffmpeg" "$HELPERS/ffprobe"; do
    for d in $(deps_of "$b"); do queue+=("$d"); done
done
while (( ${#queue} )); do
    d=${queue[1]}
    queue=(${queue[2,-1]})
    base=$(basename "$d")
    [[ -n ${seen[$base]:-} ]] && continue
    seen[$base]=1
    real=$(realpath "$d")
    cp "$real" "$HELPERS/$base"
    chmod +w "$HELPERS/$base"
    for dd in $(deps_of "$HELPERS/$base"); do queue+=("$dd"); done
done

# Rewrite references: everything lives side by side -> @loader_path/<name>
for f in "$HELPERS"/*; do
    base=$(basename "$f")
    if [[ "$base" == *.dylib ]]; then
        install_name_tool -id "@loader_path/$base" "$f" 2>/dev/null
    fi
    for d in $(deps_of "$f"); do
        install_name_tool -change "$d" "@loader_path/$(basename "$d")" "$f" 2>/dev/null
    done
    codesign --force -s - "$f" 2>/dev/null
done

echo "bundled $(ls "$HELPERS" | wc -l | tr -d ' ') files, $(du -sh "$HELPERS" | awk '{print $1}')"
left=$(otool -L "$HELPERS"/* 2>/dev/null | grep -c '/opt/homebrew' || true)
echo "leftover homebrew references: $left (must be 0)"
