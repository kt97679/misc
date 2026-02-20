#!/bin/bash

set -eu -o pipefail

FFMPEG_HOME=$HOME/Downloads/ffmpeg-master-latest-linux64-gpl/bin/
CRF=20

src="$@"
cat <<EOF
nice $FFMPEG_HOME/ffmpeg -i "$src" -map 0:v:0 -map 0:a -map 0:s? -c:v libx265 -crf 20 -preset slow -c:a libopus -ac 2 -b:a 96k -c:s copy -dn /var/tmp/"$(basename "$src" | sed -e 's/[.][^.]*$//')".mkv
EOF
