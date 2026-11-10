#!/usr/bin/env bash
# Build the 10 second clip and check Sound Blaster playback in DOSBox-X.
# Usage: ./lab/runsound.sh /path/to/tp7.zip
# DOS binaries run only inside the emulator.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LAB="$ROOT/lab"
OUT="$LAB/out"
CLIP="$LAB/clip"
CONF="$LAB/dosbox-x.conf"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/tp7.zip" >&2
  exit 1
fi

"$LAB/build.sh" "$1" play
python3 "$LAB/toneclip.py" "$CLIP"

python3 -c 'import sys; from pathlib import Path; data=sys.stdin.buffer.read().replace(b"\n", b"\r\n"); Path(sys.argv[1]).write_bytes(data if data.endswith(b"\r\n") else data + b"\r\n")' \
  "$OUT/MUX.BAT" <<EOF
@echo off
s:
cd \\lab\\clip
o:\\xdc_comp.exe CLIP.SCR > O:\\MUX.LOG
EOF

cat >"$OUT/session.conf" <<EOF
[autoexec]
mount c "$LAB/tp"
mount o "$OUT"
mount s "$ROOT"
o:
mux.bat
exit
EOF

echo "Muxing CLIP.XDV..."
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  dosbox-x -nogui -nomenu -nopromptfolder -fastlaunch -silent -exit \
  -conf "$CONF" -conf "$OUT/session.conf" -time-limit 300 \
  >"$OUT/dosbox-mux.log" 2>&1 || {
    echo "DOSBox-X mux failed. Log: $OUT/dosbox-mux.log" >&2
    exit 1
  }

if [[ ! -f "$CLIP/CLIP.XDV" ]]; then
  echo "CLIP.XDV was not produced. See $OUT/MUX.LOG" >&2
  exit 1
fi
echo "CLIP.XDV is $(wc -c <"$CLIP/CLIP.XDV") bytes"

# One keystroke in the BIOS buffer so the player does not wait forever.
python3 - "$OUT/STUFFKEY.COM" <<'PY'
import sys
from pathlib import Path
com = bytes([
    0xB8, 0x40, 0x00,
    0x8E, 0xD8,
    0xC7, 0x06, 0x1A, 0x00, 0x1E, 0x00,
    0xC7, 0x06, 0x1E, 0x00, 0x5A, 0x2C,
    0xC7, 0x06, 0x1C, 0x00, 0x20, 0x00,
    0xB8, 0x00, 0x4C,
    0xCD, 0x21,
])
Path(sys.argv[1]).write_bytes(com)
PY

run_play() {
  local name=$1
  local sbtype=$2
  local extra=$3
  local record=$4
  rm -f "$OUT/${name}.TXT" "$OUT/${name}.ALIVE" "$CLIP/DUMP.BIN" "$OUT/${name}.RAW"
  python3 -c 'import sys; from pathlib import Path; data=sys.stdin.buffer.read().replace(b"\n", b"\r\n"); Path(sys.argv[1]).write_bytes(data if data.endswith(b"\r\n") else data + b"\r\n")' \
    "$OUT/PLAYONE.BAT" <<EOF
@echo off
set BLASTER=A220 I7 D1
o:\\stuffkey.com
o:\\xdc_play.exe ${extra} /wDUMP.BIN s:\\lab\\clip\\CLIP.XDV > O:\\${name}.TXT
echo ALIVE> O:\\${name}.ALIVE
if exist DUMP.BIN ren DUMP.BIN ${name}.BIN
EOF
  cat >"$OUT/session.conf" <<EOF
[sdl]
output=surface

[dosbox]
machine=cga

[cpu]
cycles=8000
core=auto
cputype=auto

[mixer]
nosound=false
rate=44100

[sblaster]
sbtype=${sbtype}
sbbase=220
irq=7
dma=1
oplmode=opl2

[speaker]
pcspeaker=false

[autoexec]
mount c "$LAB/tp"
mount o "$OUT"
mount s "$ROOT"
o:
playone.bat
exit
EOF
  echo "Running ${name} (sbtype=${sbtype} ${extra})"
  local audio_env=()
  if [[ "$record" == "yes" ]]; then
    audio_env=(SDL_AUDIODRIVER=disk "SDL_DISKAUDIOFILE=$OUT/${name}.RAW" SDL_DISKAUDIODELAY=0)
  else
    audio_env=(SDL_AUDIODRIVER=dummy)
  fi
  env SDL_VIDEODRIVER=dummy "${audio_env[@]}" \
    dosbox-x -nogui -nomenu -nopromptfolder -fastlaunch -exit \
    -conf "$CONF" -conf "$OUT/session.conf" \
    -set "dosbox machine=cga" \
    -set "mixer nosound=false" \
    -set "sblaster sbtype=${sbtype}" \
    -set "sblaster sbbase=220" \
    -set "sblaster irq=7" \
    -set "sblaster dma=1" \
    -time-limit 90 \
    >"$OUT/dosbox-${name}.log" 2>&1 || {
      echo "DOSBox-X ${name} failed. Log: $OUT/dosbox-${name}.log" >&2
      exit 1
    }
  if [[ ! -f "$OUT/${name}.ALIVE" ]]; then
    echo "${name}: player did not return to DOS" >&2
    [[ -f "$OUT/dosbox-${name}.log" ]] && tail -40 "$OUT/dosbox-${name}.log" >&2
    exit 1
  fi
  echo "----- ${name}.TXT -----"
  cat "$OUT/${name}.TXT" || true
  if [[ "$name" == "nocard" ]]; then
    if ! grep -q "NOSOUND" "$OUT/${name}.TXT"; then
      echo "${name}: expected a message that suggests /NOSOUND" >&2
      exit 1
    fi
  else
    if [[ ! -f "$OUT/${name}.BIN" ]]; then
      echo "${name}: no video dump (playback did not finish)" >&2
      exit 1
    fi
  fi
}

run_play sb2 sb2 "/ADAPTER=CGA" yes
run_play nosound sb2 "/NOSOUND /ADAPTER=CGA" yes
run_play nocard none "" no

echo "Sound checks finished."
