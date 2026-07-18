#!/bin/zsh
# Builds a UNIVERSAL (arm64 + x86_64) self-contained ffmpeg/ffprobe bundle in
# vendor/Helpers from Homebrew's official bottles — no local ffmpeg install
# needed, and no dependency on the build machine's macOS version.
#
# For each architecture it downloads the ffmpeg bottle plus dependencies for
# BOTTLE_TAG_{ARM64,X86_64}, extracts them, walks the dylib closure, rewrites
# install names to @loader_path, then lipo-glues the two trees together.
#
# Bottle tags pin the minimum macOS of the helpers (sonoma = macOS 14).
set -e
cd "$(dirname "$0")"

BOTTLE_TAG_ARM64=${BOTTLE_TAG_ARM64:-arm64_sonoma}
BOTTLE_TAG_X86_64=${BOTTLE_TAG_X86_64:-sonoma}
STAGE=${STAGE:-$(mktemp -d /tmp/ffbundle.XXXXXX)}
CACHE="$(brew --cache)/downloads"
HELPERS=vendor/Helpers

# Bottles ship with @@HOMEBREW_PREFIX@@/@@HOMEBREW_CELLAR@@ placeholder
# install names (rewritten by brew at pour time); match those too.
deps_of() {
    otool -L "$1" | tail -n +2 | awk '{print $1}' \
        | grep -E '^/opt/homebrew|^/usr/local|^@@HOMEBREW' || true
}

build_tree() {
    local tag=$1 out=$2
    echo "== $tag =="
    brew fetch --bottle-tag "$tag" --deps ffmpeg >/dev/null

    local extracted="$STAGE/$tag"
    mkdir -p "$extracted" "$out"
    for tgz in "$CACHE"/*."$tag".bottle*.tar.gz; do
        tar -xzf "$tgz" -C "$extracted"
    done

    # Index every extracted dylib by basename for closure resolution
    typeset -A index
    for d in "$extracted"/*/*/lib/*.dylib(N); do
        index[$(basename "$d")]="$d"
    done

    cp "$extracted"/ffmpeg/*/bin/ffmpeg "$out/ffmpeg"
    cp "$extracted"/ffmpeg/*/bin/ffprobe "$out/ffprobe"
    chmod +w "$out"/*

    typeset -A seen
    queue=()
    for b in "$out/ffmpeg" "$out/ffprobe"; do
        for d in $(deps_of "$b"); do queue+=("$d"); done
    done
    while (( ${#queue} )); do
        d=${queue[1]}
        queue=(${queue[2,-1]})
        base=$(basename "$d")
        [[ -n ${seen[$base]:-} ]] && continue
        seen[$base]=1
        src=${index[$base]:-}
        if [[ -z "$src" ]]; then
            echo "ERROR: cannot resolve $d in extracted bottles" >&2
            exit 1
        fi
        cp "$(realpath "$src")" "$out/$base"
        chmod +w "$out/$base"
        for dd in $(deps_of "$out/$base"); do queue+=("$dd"); done
    done

    for f in "$out"/*; do
        base=$(basename "$f")
        if [[ "$base" == *.dylib ]]; then
            install_name_tool -id "@loader_path/$base" "$f" 2>/dev/null
        fi
        for d in $(deps_of "$f"); do
            install_name_tool -change "$d" "@loader_path/$(basename "$d")" "$f" 2>/dev/null
        done
        codesign --force -s - "$f" 2>/dev/null
    done
    echo "$tag: $(ls "$out" | wc -l | tr -d ' ') files"
}

build_tree "$BOTTLE_TAG_ARM64"  "$STAGE/helpers-arm64"
build_tree "$BOTTLE_TAG_X86_64" "$STAGE/helpers-x86_64"

# Both trees must contain the same files, or the lipo below is wrong
diff <(ls "$STAGE/helpers-arm64") <(ls "$STAGE/helpers-x86_64")

rm -rf "$HELPERS"
mkdir -p "$HELPERS"
for f in "$STAGE/helpers-arm64"/*; do
    base=$(basename "$f")
    lipo -create "$f" "$STAGE/helpers-x86_64/$base" -output "$HELPERS/$base"
    codesign --force -s - "$HELPERS/$base" 2>/dev/null
done

echo "bundled $(ls "$HELPERS" | wc -l | tr -d ' ') universal files, $(du -sh "$HELPERS" | awk '{print $1}')"
left=$(otool -L "$HELPERS"/* 2>/dev/null | grep -c '/opt/homebrew\|/usr/local' || true)
echo "leftover homebrew references: $left (must be 0)"
lipo -info "$HELPERS/ffmpeg"
