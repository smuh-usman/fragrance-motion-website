#!/bin/bash
# Solve for the rectangle of the source still that a generated plate actually
# shows.
#
# Every image-to-video model tested reframes its input slightly: the plate is a
# zoomed view of the crop it was given. Rather than warping the plate to fit the
# rectangle we assumed, we search for the rectangle it genuinely corresponds to,
# and blend it back there. A coarse scale sweep about the centre, then a refine
# pass on the winner.
#
#   bash scripts/align-plate.sh <plate-frame.png> <source-crop.png>

set -e
PLATE="$1"
SOURCE="$2"
[ -z "$PLATE" ] || [ -z "$SOURCE" ] && { echo "usage: align-plate.sh <plate-frame> <source-crop>"; exit 1; }

PW=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$PLATE")
PH=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$PLATE")
SW=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$SOURCE")
SH=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$SOURCE")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

score() { # scale cx cy -> ssim
  local s=$1 cx=$2 cy=$3
  local cw ch x y
  cw=$(echo "$SW * $s / 1" | bc)
  ch=$(echo "$SH * $s / 1" | bc)
  x=$(echo "($SW - $cw) * $cx / 1" | bc)
  y=$(echo "($SH - $ch) * $cy / 1" | bc)
  ffmpeg -y -v error -i "$SOURCE" -vf "crop=${cw}:${ch}:${x}:${y},scale=${PW}:${PH}" "$TMP/c.png"
  ffmpeg -v error -i "$PLATE" -i "$TMP/c.png" -lavfi "ssim=stats_file=-" -f null - 2>&1 \
    | tail -1 | sed -E 's/.*All:([0-9.]+).*/\1/'
}

best_s=1; best_score=0
echo "coarse scale sweep (centred):"
for s in 0.78 0.82 0.86 0.90 0.94 0.98 1.00; do
  v=$(score "$s" 0.5 0.5)
  echo "  scale=$s  ssim=$v"
  if [ "$(echo "$v > $best_score" | bc -l)" = "1" ]; then best_score=$v; best_s=$s; fi
done

echo ""
echo "refine offsets at scale=$best_s:"
best_cx=0.5; best_cy=0.5
for cx in 0.30 0.40 0.50 0.60 0.70; do
  for cy in 0.30 0.50 0.70; do
    v=$(score "$best_s" "$cx" "$cy")
    if [ "$(echo "$v > $best_score" | bc -l)" = "1" ]; then
      best_score=$v; best_cx=$cx; best_cy=$cy
      echo "  cx=$cx cy=$cy ssim=$v  <- best"
    fi
  done
done

CW=$(echo "$SW * $best_s / 1" | bc)
CH=$(echo "$SH * $best_s / 1" | bc)
X=$(echo "($SW - $CW) * $best_cx / 1" | bc)
Y=$(echo "($SH - $CH) * $best_cy / 1" | bc)

echo ""
echo "best: ssim=$best_score  scale=$best_s  crop=${CW}x${CH}+${X}+${Y} (within the source crop)"
