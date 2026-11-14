#!/usr/bin/env bash
# Build a synthetic 320x200x16 clip and, optionally, play it.
# Usage: ./lab/run320.sh /path/to/tp7.zip [ega|vga|cga|auto]
# DOS binaries run only inside DOSBox-X.
# With no machine argument the clip is compiled and left in lab/out/ega.
# cga checks that the player refuses mode 6. ega and vga play it.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LAB="$ROOT/lab"
OUT="$LAB/out"
CLIP="$OUT/ega"
CONF="$LAB/dosbox-x.conf"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/tp7.zip [ega|vga|cga|auto]" >&2
  exit 1
fi

"$LAB/build.sh" "$1"
python3 "$LAB/gen320.py" "$CLIP"

python3 -c 'import sys; from pathlib import Path; data=sys.stdin.buffer.read().replace(b"\n", b"\r\n"); Path(sys.argv[1]).write_bytes(data if data.endswith(b"\r\n") else data + b"\r\n")' \
  "$OUT/PLAY320.BAT" <<EOF
@echo off
s:
cd \\
c:\\tp\\bin\\tpc.exe -UC:\\TP\\UNITS;S:\\UNITS;S:\\TPLIBS\\CGA\\LIB -EO:\\ -B S:\\XDP_PLAY.PAS > O:\\PLAY.LOG
if errorlevel 1 goto fail
c:\\tp\\bin\\tpc.exe -UC:\\TP\\UNITS;S:\\UNITS;S:\\TPLIBS\\CGA\\LIB -EO:\\ -B S:\\XDP_COMP.PAS > O:\\COMP.LOG
if errorlevel 1 goto fail
o:
cd \\ega
o:\\xdp_comp.exe CLIP.SCR > O:\\CLIPLOG.TXT
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
play320.bat
exit
EOF

echo "Compiling XDP_PLAY, XDP_COMP and the 320x200 clip..."
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  dosbox-x -nogui -nomenu -nopromptfolder -fastlaunch -silent -exit \
  -conf "$CONF" -conf "$OUT/session.conf" -time-limit 600 \
  >"$OUT/dosbox-play320.log" 2>&1 || {
    echo "DOSBox-X failed. Log: $OUT/dosbox-play320.log" >&2
    exit 1
  }

if [[ ! -f "$CLIP/CLIP.XDV" ]]; then
  echo "CLIP.XDV was not produced. See $OUT/COMP.LOG, $OUT/PLAY.LOG and $CLIP/CLIP.LOG" >&2
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

rm -f "$CLIP/DUMP.BIN" "$CLIP/NOTE.TXT" "$OUT/PLAYOUT.TXT"
python3 -c 'import sys; from pathlib import Path; data=sys.stdin.buffer.read().replace(b"\n", b"\r\n"); Path(sys.argv[1]).write_bytes(data if data.endswith(b"\r\n") else data + b"\r\n")' \
  "$OUT/SHOW320.BAT" <<EOF
@echo off
o:
cd \\ega
o:\\xdp_play.exe /NOSOUND /p ${FLAG} /wDUMP.BIN CLIP.XDV > O:\\PLAYOUT.TXT
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
show320.bat
exit
EOF

echo "Playing on machine=${MACHINE} ${FLAG}"
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  dosbox-x -nogui -nomenu -nopromptfolder -fastlaunch -silent -exit \
  -conf "$CONF" -conf "$OUT/session.conf" -time-limit 90 \
  >"$OUT/dosbox-320-${MACHINE}.log" 2>&1 || {
    echo "DOSBox-X playback failed. Log: $OUT/dosbox-320-${MACHINE}.log" >&2
    exit 1
  }

if [[ "$MACHINE" == "cga" ]]; then
  if ! grep -q "EGA" "$OUT/PLAYOUT.TXT"; then
    echo "CGA run did not refuse mode 6. See $OUT/PLAYOUT.TXT" >&2
    exit 1
  fi
  echo "CGA refusal:"
  cat "$OUT/PLAYOUT.TXT"
  exit 0
fi

if [[ ! -f "$CLIP/DUMP.BIN" ]]; then
  echo "No video dump. Log: $OUT/dosbox-320-${MACHINE}.log" >&2
  exit 1
fi
echo "Dump: $CLIP/DUMP.BIN ($(wc -c <"$CLIP/DUMP.BIN") bytes)"
[[ -f "$CLIP/NOTE.TXT" ]] && cat "$CLIP/NOTE.TXT"
