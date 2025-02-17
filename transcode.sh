#!/bin/bash

set -eu -o pipefail

FFMPEG_HOME=$HOME/Downloads/ffmpeg-git-20240629-amd64-static
CRF=20

src="$@"
fps=$($FFMPEG_HOME/ffprobe "$src" |& grep -v mjpeg | grep -oP "[\d.]+(?=\sfps)")
echo nice $FFMPEG_HOME/ffmpeg -i \""$src"\" -r $fps -acodec libmp3lame -vcodec libx265 -map 0 -map -v -map V -crf $CRF \"/var/tmp/$(basename "$src" | sed -e 's/[.][^.]*$//')\".mkv
