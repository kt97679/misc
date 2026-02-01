#!/bin/bash

set -eu -o pipefail

FFMPEG_HOME=$HOME/Downloads/ffmpeg-master-latest-linux64-gpl/bin/
CRF=20

src="$@"
echo nice $FFMPEG_HOME/ffmpeg -i \""$src"\" -map 0 -c copy -c:v libx265 -crf $CRF -preset slow -c:a libopus -b:a 96k -dn /var/tmp/\"$(basename "$src" | sed -e 's/[.][^.]*$//')\".mkv
