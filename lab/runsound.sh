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
o:\\xdp_comp.exe CLIP.SCR > O:\\MUX.LOG
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
  -conf "$CONF" -conf "$OUT/session.conf" -time-limit 600 \
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
  local machine=$2
  local sbtype=$3
  local extra=$4
  local record=$5
  local twice=${6:-no}
  rm -f "$OUT/${name}.TXT" "$OUT/${name}.OK" "$OUT/${name}.BIN" "$OUT/${name}.RAW" "$OUT/${name}2.TXT" "$OUT/${name}2.OK"
  {
    echo '@echo off'
    echo 'set BLASTER=A220 I7 D1'
    echo 'o:\stuffkey.com'
    echo "o:\\xdp_play.exe ${extra} /wDUMP.BIN s:\\lab\\clip\\CLIP.XDV > O:\\${name}.TXT"
    echo "echo OK> O:\\${name}.OK"
    echo "if exist DUMP.BIN ren DUMP.BIN ${name}.BIN"
    if [[ "$twice" == "yes" ]]; then
      echo 'o:\stuffkey.com'
      echo "o:\\xdp_play.exe ${extra} s:\\lab\\clip\\CLIP.XDV > O:\\${name}2.TXT"
      echo "echo SECOND> O:\\${name}2.OK"
    fi
  } | python3 -c 'import sys; from pathlib import Path; data=sys.stdin.buffer.read().replace(b"\n", b"\r\n"); Path(sys.argv[1]).write_bytes(data if data.endswith(b"\r\n") else data + b"\r\n")' \
    "$OUT/PLAYONE.BAT"
  cat >"$OUT/session.conf" <<EOF
[sdl]
output=surface

[dosbox]
machine=${machine}

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
  echo "Running ${name} (machine=${machine} sbtype=${sbtype} ${extra})"
  local audio_env=()
  if [[ "$record" == "no" ]]; then
    audio_env=(SDL_AUDIODRIVER=dummy)
  else
    audio_env=(SDL_AUDIODRIVER=disk "SDL_DISKAUDIOFILE=$OUT/${name}.RAW" SDL_DISKAUDIODELAY=0)
  fi
  env SDL_VIDEODRIVER=dummy "${audio_env[@]}" \
    dosbox-x -nogui -nomenu -nopromptfolder -fastlaunch -exit \
    -conf "$OUT/session.conf" \
    -time-limit 90 \
    >"$OUT/dosbox-${name}.log" 2>&1 || {
      echo "DOSBox-X ${name} failed. Log: $OUT/dosbox-${name}.log" >&2
      exit 1
    }
  # DOS stores 8.3 names in uppercase. The Linux mount is case-sensitive.
  local ok txt bin
  ok=$(find "$OUT" -maxdepth 1 -iname "${name}.OK" -print -quit)
  txt=$(find "$OUT" -maxdepth 1 -iname "${name}.TXT" -print -quit)
  bin=$(find "$OUT" -maxdepth 1 -iname "${name}.BIN" -print -quit)
  if [[ -z "$ok" ]]; then
    echo "${name}: player did not return to DOS" >&2
    [[ -f "$OUT/dosbox-${name}.log" ]] && tail -40 "$OUT/dosbox-${name}.log" >&2
    exit 1
  fi
  echo "----- ${name}.TXT -----"
  cat "$txt" || true
  if [[ "$name" == "nocard" ]]; then
    if ! grep -q "NOSOUND" "$txt"; then
      echo "${name}: expected a message that suggests /NOSOUND" >&2
      exit 1
    fi
  else
    if [[ -z "$bin" ]]; then
      echo "${name}: no video dump (playback did not finish)" >&2
      exit 1
    fi
  fi
  if [[ "$twice" == "yes" ]]; then
    local ok2
    ok2=$(find "$OUT" -maxdepth 1 -iname "${name}2.OK" -print -quit)
    if [[ -z "$ok2" ]]; then
      echo "${name}: second run did not return to DOS" >&2
      exit 1
    fi
  fi
  if [[ "$record" == "discard" ]]; then
    rm -f "$OUT/${name}.RAW"
  fi
}

# record=yes keeps the disk capture. record=discard uses the disk driver
# so the DSP exists, then deletes the capture. record=no is the dummy driver.
run_play sb2 cga sb2 "/ADAPTER=CGA" discard
run_play sb2again cga sb2 "/ADAPTER=CGA" discard
run_play nosound cga sb2 "/NOSOUND /ADAPTER=CGA" no
run_play nocard cga none "" no
run_play vgaonly vgaonly sb2 "/ADAPTER=VGA" discard

echo "Sound checks finished."
