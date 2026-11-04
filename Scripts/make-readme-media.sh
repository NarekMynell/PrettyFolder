#!/bin/sh
# Renders the README's picture and animations into docs/, from a debug build of the app:
#
#   Scripts/make-readme-media.sh path/to/Debug/PrettyFolder.app docs
#
# The app draws every frame with its own views and icons (see App/ReadmeMedia) and
# ffmpeg turns the frames into GIFs. Needs ffmpeg: brew install ffmpeg
# docs/hero.gif is cut from the trailer, so it is not made here.
set -eu

app="$1"
docs="$2"
command -v ffmpeg >/dev/null || { echo "ffmpeg is needed: brew install ffmpeg" >&2; exit 1; }

frames="$(mktemp -d)"
trap 'rm -rf "$frames"' EXIT

"$app/Contents/MacOS/PrettyFolder" --readme-media "$frames" --pictures "$docs/pictures" --pointer 1.35

# 256 colors are plenty for the pictures too, at a third of the size.
ffmpeg -loglevel error -y -i "$frames/depth.png" \
    -vf "scale=840:-1:flags=lanczos,format=rgb24,split[a][b];[a]palettegen=max_colors=256[p];[b][p]paletteuse=dither=sierra2_4a" \
    -pix_fmt pal8 "$docs/depth.png"
echo "Wrote $docs/depth.png"

# gif <name> <scene> <first second> <last second> <speed>
# One palette for the whole animation keeps still parts still, so only what moves is stored
# frame to frame. Small and at 15 frames a second, they fit side by side in the README.
gif() {
    ffmpeg -loglevel error -y -framerate 25 -ss "$3" -to "$4" -i "$frames/$2/frame-%04d.png" \
        -vf "setpts=PTS/$5,fps=15,scale=360:-1:flags=lanczos,format=rgb24,split[a][b];[a]palettegen=max_colors=192:stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
        "$docs/$1.gif"
    echo "Wrote $docs/$1.gif ($(($(wc -c < "$docs/$1.gif") / 1024)) KB)"
}

gif drop drop 0 5.8 1.2
gif remove hover 0.6 2.45 1
gif choose hover 2.2 5.5 1
gif open hover 5.3 7.9 1
gif menu menu 0 4 1
gif clear clear 0 9.2 1.3
gif size size 0 5.4 1
gif shape shape 0 5.4 1
gif zoom zoom 0 5.5 1
gif cover cover 0 4.2 1
gif part part 0 4.2 1
gif fit fit 0 4.4 1
gif turn turn 0 4.8 1
gif quarter quarter 0 5.8 1.1
gif keys keys 0 5.2 1
gif several several 0 5.6 1
gif default default 0 6.2 1
gif copies copies 0 5.8 1
gif removeall removeall 0 5.2 1
