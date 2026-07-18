# Cadence Doctor

Native macOS app that scans video clips for baked-in frame-cadence damage and
repairs them with a motion-compensated rebuild — the workflow developed for the
AA203 Vienna stock clips.

## What it detects

The scanner measures inter-frame motion (low-res grayscale `tblend` difference,
one value per frame transition) across the whole clip, then classifies:

- **SKIP CADENCE** (repairable) — periodic double-size motion jumps, e.g. one
  dropped frame every N. The fingerprint of a nearest-frame rate conform
  (30p→25p etc.) baked into the file. Period AND phase are detected per clip.
- **NEEDS REVIEW** — periodic duplicate/blend frames (classic pulldown /
  frame-blend conform). These need `fieldmatch`/`decimate`-style removal, not a
  rebuild; the app flags them rather than guessing.
- **IRREGULAR** — aperiodic motion spikes (VFR damage, stutter): manual review.
- **CLEAN** — no cadence defect found. Interlaced-flagged files are routed to
  review as well.

## What the repair does

1. Remaps every frame to its true temporal position:
   `setpts = (N + floor((N + period-1-phase) / period)) / source_fps`
2. Synthesizes the missing frames and resamples to the target rate with
   `minterpolate` (mci / aobmc / bidir) — restoring true real-time motion.
3. Encodes ProRes (HQ/422/LT), `yuv422p10le`, copies color tags and start
   timecode, `-vendor apl0`.
4. Verifies: probes the output frame count against the expected count and
   re-runs the cadence scan on the result. Green "FIXED ✓ VERIFIED" means both
   passed; amber means open it and check by eye.

Note: restoring true speed makes clips longer than the damaged source
(e.g. 25.7s → 30.8s for a period-5 skip). Re-check out-points on shots already
cut in.

## Requirements

- macOS 14+ (Apple Silicon or Intel).
- Nothing else: universal ffmpeg/ffprobe are bundled in the app. (If the
  bundled copies are removed, the app falls back to /opt/homebrew/bin,
  /usr/local/bin, /opt/local/bin.)

## Usage

Drag clips or entire folders (e.g. a TURNOVERS directory) into the window —
scanning starts immediately, two clips at a time. Repairs run one at a time
(minterpolate saturates the CPU). Pick target rate (23.976/25/29.97), ProRes
profile, and output folder in the header. Output files get a rate suffix
(`_2398p.mov` etc.) and land in the chosen folder (default
`~/Desktop/CADENCE_FIXED`). Existing outputs with the same name are overwritten.

## Rebuilding from source

```
./build.sh
```

Requires Xcode Command Line Tools. The app is ad-hoc signed; it runs locally
but will need re-signing for distribution to other machines.
