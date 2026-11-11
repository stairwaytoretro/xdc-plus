#!/usr/bin/env bash
# Build the silent player and play a generated 160x100 clip.
# Usage: ./lab/run160.sh /path/to/tp7.zip [cga|ega|vgaonly]
# DOS binaries run only inside DOSBox-X.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LAB="$ROOT/lab"
OUT="$LAB/out"
CLIP="$OUT/clip"
CONF="$LAB/dosbox-x.conf"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/tp7.zip [cga|ega|vgaonly]" >&2
  exit 1
fi

"$LAB/build.sh" "$1"

python3 "$LAB/gen160.py" "$CLIP"

# Compile the player, then the clip. O: is lab/out, S: is the repo root.
python3 -c 'import sys; from pathlib import Path; data=sys.stdin.buffer.read().replace(b"\n", b"\r\n"); Path(sys.argv[1]).write_bytes(data if data.endswith(b"\r\n") else data + b"\r\n")' \
  "$OUT/PLAY160.BAT" <<EOF
@echo off
s:
cd \\
c:\\tp\\bin\\tpc.exe -UC:\\TP\\UNITS;S:\\UNITS;S:\\TPLIBS\\CGA\\LIB -EO:\\ -B S:\\XDC_PLAY.PAS > O:\\PLAY.LOG
if errorlevel 1 goto fail
o:
cd \\clip
o:\\xdc_comp.exe CLIP.SCR > O:\\CLIPLOG.TXT
goto end
:fail
echo TPC failed
:end
EOF

cat >"$OUT/session.conf" <<EOF
[autoexec]
mount c "$LAB/tp"
mount o "$OUT"
mount s "$ROOT"
o:
play160.bat
exit
EOF

echo "Compiling XDC_PLAY and the 160x100 clip..."
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  dosbox-x -nogui -nomenu -nopromptfolder -fastlaunch -silent -exit \
  -conf "$CONF" -conf "$OUT/session.conf" -time-limit 180 \
  >"$OUT/dosbox-play160.log" 2>&1 || {
    echo "DOSBox-X failed. Log: $OUT/dosbox-play160.log" >&2
    exit 1
  }

if [[ ! -f "$CLIP/CLIP.XDV" ]]; then
  echo "CLIP.XDV was not produced. See $OUT/PLAY.LOG and $CLIP/CLIP.LOG" >&2
  exit 1
fi

MACHINE=${2:-}
if [[ -z "$MACHINE" ]]; then
  echo "Clip is ready: $CLIP/CLIP.XDV"
  echo "Per-frame lines are in $CLIP/CLIP.LOG"
  exit 0
fi

case "$MACHINE" in
  cga) FLAG=/ADAPTER=CGA ;;
  ega) FLAG=/ADAPTER=EGA ;;
  vga|vgaonly) MACHINE=vgaonly; FLAG=/ADAPTER=VGA ;;
  auto) FLAG= ;;
  *) echo "Unknown machine: $MACHINE" >&2; exit 1 ;;
esac

rm -f "$CLIP/DUMP.BIN" "$CLIP/NOTE.TXT"
python3 -c 'import sys; from pathlib import Path; data=sys.stdin.buffer.read().replace(b"\n", b"\r\n"); Path(sys.argv[1]).write_bytes(data if data.endswith(b"\r\n") else data + b"\r\n")' \
  "$OUT/SHOW160.BAT" <<EOF
@echo off
o:
cd \\clip
o:\\xdc_play.exe /NOSOUND /p ${FLAG} /wDUMP.BIN CLIP.XDV
EOF

cat >"$OUT/session.conf" <<EOF
[sdl]
fullscreen=false
output=surface
windowresolution=original

[dosbox]
machine=${MACHINE}

[cpu]
cycles=4000

[autoexec]
mount c "$LAB/tp"
mount o "$OUT"
mount s "$ROOT"
o:
show160.bat
exit
EOF

echo "Playing on machine=${MACHINE} ${FLAG}"
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  dosbox-x -nogui -nomenu -nopromptfolder -fastlaunch -silent -exit \
  -conf "$CONF" -conf "$OUT/session.conf" -time-limit 60 \
  >"$OUT/dosbox-${MACHINE}.log" 2>&1 || {
    echo "DOSBox-X playback failed. Log: $OUT/dosbox-${MACHINE}.log" >&2
    exit 1
  }

if [[ ! -f "$CLIP/DUMP.BIN" ]]; then
  echo "No video dump. Log: $OUT/dosbox-${MACHINE}.log" >&2
  exit 1
fi
echo "Dump: $CLIP/DUMP.BIN"
[[ -f "$CLIP/NOTE.TXT" ]] && cat "$CLIP/NOTE.TXT"
