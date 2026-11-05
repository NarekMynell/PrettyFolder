#!/bin/sh
# Renders the README's animations into docs/, from a debug build of the app:
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

"$app/Contents/MacOS/PrettyFolder" --readme-media "$frames" --pictures "$docs/pictures" --pointer 1.35

# gif <name> <scene> <first second> <last second> <speed>
# One palette for the whole animation keeps still parts still, so only what moves is stored
# frame to frame. Small and at 15 frames a second, they fit side by side in the README.
gif() {
    ffmpeg -loglevel error -y -framerate 25 -ss "$3" -to "$4" -i "$frames/$2/frame-%04d.png" \
        -vf "setpts=PTS/$5,fps=15,scale=360:-1:flags=lanczos,format=rgb24,split[a][b];[a]palettegen=max_colors=192:stats_mode=full[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
        "$docs/$1.gif"
    echo "Wrote $docs/$1.gif ($(($(wc -c < "$docs/$1.gif") / 1024)) KB)"
}

gif drop drop 0 9.2 1.3
gif buttons buttons 0.6 7.9 1.15
gif frame frame 0 6.7 1
gif picture picture 0 7 1
gif several several 0 6.6 1
gif everything everything 0 7.5 1
