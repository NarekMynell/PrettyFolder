#!/bin/sh
# Renders the README's picture and animations into docs/, from a debug build of the app:
#
#   Scripts/make-readme-media.sh path/to/Debug/PrettyFolder.app docs
#
# The app draws every frame with its own views and icons (see App/ReadmeMedia) and
# ffmpeg turns the frames into GIFs. Needs ffmpeg: brew install ffmpeg
set -eu

app="$1"
docs="$2"
command -v ffmpeg >/dev/null || { echo "ffmpeg is needed: brew install ffmpeg" >&2; exit 1; }

frames="$(mktemp -d)"
trap 'rm -rf "$frames"' EXIT

"$app/Contents/MacOS/PrettyFolder" --readme-media "$frames" --pictures "$docs/pictures"

# 256 colors are plenty for the pictures too, at a third of the size.
for picture in hero depth; do
    ffmpeg -loglevel error -y -i "$frames/$picture.png" \
        -vf "format=rgb24,split[a][b];[a]palettegen=max_colors=256[p];[b][p]paletteuse=dither=sierra2_4a" \
        -pix_fmt pal8 "$docs/$picture.png"
    echo "Wrote $docs/$picture.png"
done
for scene in drop hover zoom turn fit; do
    # One palette for the whole animation keeps still parts still, so only what moves
    # is stored frame to frame. Ordered dithering and 20 frames a second keep photos
    # moving across the screen to a few megabytes.
    ffmpeg -loglevel error -y -framerate 25 -i "$frames/$scene/frame-%04d.png" \
        -vf "fps=20,format=rgb24,split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
        "$docs/$scene.gif"
    echo "Wrote $docs/$scene.gif"
done
