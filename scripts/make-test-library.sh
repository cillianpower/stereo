#!/bin/bash
set -e
# Usage: scripts/make-test-library.sh <dir>   — synthetic tagged library for IntegrationTests (needs ffmpeg).
M="$1"; rm -rf "$M"; mkdir -p "$M"
mk_album() {
  local artist="$1" album="$2" year="$3" genre="$4" color="$5" n="$6" codec="$7" gapless="$8"
  local dir="$M/$artist/$album"; mkdir -p "$dir"
  ffmpeg -loglevel error -y -f lavfi -i "color=c=$color:s=600x600" -frames:v 1 "$dir/cover.jpg"
  local rate=44100 len=$((44100*12))
  for i in $(seq 1 $n); do
    local title="$album Track $i" ext=flac
    local cargs=(-c:a flac -sample_fmt s16)
    if [ "$codec" = mp3 ]; then ext=mp3; cargs=(-c:a libmp3lame -b:a 192k); fi
    local start=$(( (i-1)*len )) end=$(( i*len )) src filt
    if [ "$gapless" = yes ]; then
      src="aevalsrc=0.4*sin(2*PI*(220+40*sin(2*PI*t/30))*t):s=$rate:d=$(( n*12 ))"
      filt="atrim=start_sample=$start:end_sample=$end,asetpts=N/SR/TB"
    else
      src="sine=f=$((200+i*60)):r=$rate:d=12"; filt="volume=0.6"
    fi
    ffmpeg -loglevel error -y -f lavfi -i "$src" -af "$filt" -ac 2 "${cargs[@]}" \
      -metadata title="$title" -metadata artist="$artist" -metadata album_artist="$artist" -metadata album="$album" \
      -metadata date="$year" -metadata genre="$genre" -metadata track="$i/$n" \
      -metadata REPLAYGAIN_TRACK_GAIN="-$((3+i)).50 dB" -metadata REPLAYGAIN_TRACK_PEAK="0.9$i" \
      -metadata REPLAYGAIN_ALBUM_GAIN="-5.00 dB" -metadata REPLAYGAIN_ALBUM_PEAK="0.99" \
      "$dir/$(printf %02d $i) $title.$ext"
  done
}
mk_album "Test Signals" "Continuous Sweep" 2024 Ambient "0x3b5bdb" 4 flac yes
mk_album "Test Signals" "Plain Tones" 2021 Electronic "0xe8590c" 3 flac no
mk_album "Sigur Rós Tribute" "Ágætis Tones" 1999 "Post-Rock" "0x2b8a3e" 3 mp3 no
