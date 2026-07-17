# Handoff: finish signing/notarization + GitHub release on the dev machine

Context for whoever picks this up (human or Claude session): this folder is a
complete, working macOS app project built on Todd's edit machine. Everything
compiles and runs; the only remaining work needs credentials that live on the
dev machine (Developer ID cert, notarytool profile, GitHub auth).

## What this is

**Cadence Doctor** — SwiftUI app that scans video for baked-in frame-cadence
damage (dropped-frame judder from bad rate conforms, dup/blend pulldown) and
repairs it with a motion-compensated ProRes rebuild. See README.md for the
detection/repair method. Universal binary (arm64 + x86_64), macOS 13+,
ffmpeg bundled in Contents/Helpers.

## Remaining tasks

1. **Rebuild here** (requires Xcode CLT):
   ```
   ./bundle_ffmpeg.sh   # re-vendor ffmpeg from THIS machine's Homebrew
   ./build.sh
   ```
   Note: bundle_ffmpeg.sh vendors the local Homebrew ffmpeg, which is
   single-arch. The arm64 edit machine produced an arm64 ffmpeg bundle. If this
   machine is Intel, its bundle will be x86_64. To ship truly universal
   helpers, lipo the two machines' vendor/Helpers trees together, or vendor
   static universal builds instead.

2. **Sign + notarize** (identity: `security find-identity -v -p codesigning`;
   profile: whatever Maxlo Transfer/Blaze releases use with notarytool):
   ```
   DEV_ID="Developer ID Application: <name> (<TEAMID>)" PROFILE=<profile> ./notarize.sh
   ```
   Produces stapled `Cadence Doctor.app` + `CadenceDoctor-v1.0.zip`.

3. **Publish to github.com/maxlo-tju** (repo doesn't exist yet):
   ```
   gh repo create maxlo-tju/cadence-doctor --public --source . --push
   gh release create v1.0 CadenceDoctor-v1.0.zip --title "Cadence Doctor 1.0" \
     --notes "First release. Scans for baked-in cadence damage and rebuilds clean ProRes."
   ```
   Optionally mirror the Sparkle appcast pattern of the other maxlo-tju
   `*-updates` repos later.

## State of the local git repo

One commit on `main`, no remote configured. Build artifacts, vendor/ and the
.app are gitignored — only source and scripts are tracked.
