#!/usr/bin/env bash
# Exports the 小熊伴学 logo from brand/source/*.svg to PNGs and copies them to every place that uses them:
# brand/png, the iPad app icon, the Android launcher icon and the web pages' favicons and brand marks.
# Needs rsvg-convert and ImageMagick (brew install librsvg imagemagick). Run from anywhere: scripts/brand-export.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/brand/source"
png="$root/brand/png"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$png"

# Render each source once at 1024px, then scale down: fine felt and stitch detail survives better than rendering small.
for name in logo-round logo-square logo-square-rounded plush-bear android-background android-foreground; do
  rsvg-convert -w 1024 -h 1024 "$src/$name.svg" -o "$tmp/$name.png"
done
resize() { magick "$1" -filter Lanczos -resize "${2}x${2}" -strip "$3"; }
opaque() { magick "$1" -filter Lanczos -resize "${2}x${2}" -background '#6fbf82' -alpha remove -alpha off -strip "$3"; }

for s in 1024 512 256 128 64 32; do
  resize "$tmp/logo-round.png" $s "$png/logo-round-$s.png"
  resize "$tmp/logo-square-rounded.png" $s "$png/logo-square-rounded-$s.png"
done
for s in 1024 512 256 180 128; do opaque "$tmp/logo-square.png" $s "$png/logo-square-$s.png"; done
for s in 1024 512; do resize "$tmp/plush-bear.png" $s "$png/plush-bear-$s.png"; done

# iPad / iPhone app icon: one opaque 1024px square, iOS rounds the corners itself.
opaque "$tmp/logo-square.png" 1024 "$root/ipad/LittleBearTutor/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

# Android adaptive launcher icon: 108dp layers per density (mipmap-anydpi-v26/ic_launcher.xml puts them together).
res="$root/app/src/main/res"
for pair in mdpi:108 hdpi:162 xhdpi:216 xxhdpi:324 xxxhdpi:432; do
  dir="$res/mipmap-${pair%%:*}"; size="${pair##*:}"
  mkdir -p "$dir"
  opaque "$tmp/android-background.png" "$size" "$dir/ic_launcher_background.png"
  resize "$tmp/android-foreground.png" "$size" "$dir/ic_launcher_foreground.png"
done

# Web pages: each page is served from its own folder, so each gets its own copies.
for page in site teacher parent hanzi poems; do
  dir="$root/web/$page/brand"
  mkdir -p "$dir"
  resize "$tmp/logo-square-rounded.png" 64 "$dir/favicon.png"
  opaque "$tmp/logo-square.png" 180 "$dir/apple-touch-icon.png"
done
for page in site teacher parent hanzi poems; do resize "$tmp/logo-round.png" 144 "$root/web/$page/brand/logo-round.png"; done

echo "brand assets exported"
