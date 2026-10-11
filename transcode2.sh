#!/bin/bash

set -eu -o pipefail

CRF=20

src="$@"
cat <<EOF
nice ffmpeg -i "$src" -map 0:v:0 -map 0:a -map 0:s? -c:v libx265 -crf 20 -preset slow -c:a libopus -ac 2 -b:a 96k -c:s srt -dn /var/tmp/"$(basename "$src" | sed -e 's/[.][^.]*$//')".mkv
EOF
