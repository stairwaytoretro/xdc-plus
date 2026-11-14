#!/usr/bin/env bash
# Compile XDP_COMP.PAS with Turbo Pascal 7 inside DOSBox-X.
# DOS binaries are never launched on the host.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LAB="$ROOT/lab"
TP="$LAB/tp"
DIST="$LAB/dist"
OUT="$LAB/out"
CONF="$LAB/dosbox-x.conf"

PLAY=0
SRC=""
for arg in "$@"; do
  case "$arg" in
    play|--play) PLAY=1 ;;
    -h|--help)
      echo "Usage: $0 [tp7.zip|PASCAL.EXE] [play]"
      echo "  tp7.zip or PASCAL.EXE: your own copy of Turbo Pascal 7 (required on the first run)."
      echo "  play: also compiles XDP_PLAY.PAS (links XDC_SB.PAS)."
      exit 0
      ;;
    *)
      if [[ -n "$SRC" ]]; then
        echo "Unexpected argument: $arg" >&2
        exit 1
      fi
      SRC=$arg
      ;;
  esac
done

if ! command -v dosbox-x >/dev/null 2>&1; then
  echo "dosbox-x was not found. On Ubuntu: sudo apt install dosbox-x" >&2
  exit 1
fi

if [[ ! -f "$ROOT/UNITS/SUPPORT.PAS" || ! -f "$ROOT/TPLibs/CGA/LIB/M6845CTL.PAS" ]]; then
  echo "Submodules are missing. From the repository root: git submodule update --init --recursive" >&2
  exit 1
fi

mkdir -p "$TP" "$DIST" "$OUT"

run_dosbox() {
  local label=$1
  SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    dosbox-x -nogui -nomenu -nopromptfolder -fastlaunch -silent -exit \
      -conf "$CONF" -conf "$OUT/session.conf" \
      -time-limit 180 \
      >"$OUT/dosbox-${label}.log" 2>&1 || {
        echo "DOSBox-X failed ($label). Log: $OUT/dosbox-${label}.log" >&2
        exit 1
      }
}

emit_crlf() {
  local dest=$1
  python3 -c 'import sys; from pathlib import Path; data=sys.stdin.buffer.read().replace(b"\n", b"\r\n"); Path(sys.argv[1]).write_bytes(data if data.endswith(b"\r\n") else data + b"\r\n")' "$dest"
}

tpc_present() {
  [[ -f "$TP/TP/BIN/TPC.EXE" && -f "$TP/TP/BIN/TURBO.TPL" && -f "$TP/TP/UNITS/OBJECTS.TPU" ]]
}

if ! tpc_present; then
  if [[ -z "$SRC" ]]; then
    echo "Turbo Pascal 7 is not installed in lab/tp." >&2
    echo "Pass your archive: $0 /path/to/tp7.zip" >&2
    exit 1
  fi
  if [[ ! -f "$SRC" ]]; then
    echo "File not found: $SRC" >&2
    exit 1
  fi
  rm -rf "$DIST/unpack"
  mkdir -p "$DIST/unpack"
  # The zip archive supplied by the user is not a DOS binary.
  # PASCAL.EXE (PKSFX) is copied, then executed only inside DOSBox-X.
  if unzip -l "$SRC" 2>/dev/null | grep -q 'PASCAL.EXE'; then
    unzip -o -q "$SRC" -d "$DIST/unpack"
  else
    cp -f "$SRC" "$DIST/unpack/PASCAL.EXE"
  fi
  installer=$(find "$DIST/unpack" -iname 'PASCAL.EXE' -type f | head -n 1 || true)
  if [[ -z "$installer" ]]; then
    echo "PASCAL.EXE not found in $SRC" >&2
    exit 1
  fi
  install_dir=$(cd "$(dirname "$installer")" && pwd)
  # PKSFX 2.04g: -d recreates the directories stored in the archive (TP\BIN, TP\UNITS, ...).
  emit_crlf "$OUT/INSTALL.BAT" <<'EOF'
@echo off
d:\pascal.exe -d -o c:\ > c:\inst.log
EOF
  # C: receives the TP\ tree. The .BAT is on O:.
  cat >"$OUT/session.conf" <<EOF
[autoexec]
mount c "$TP"
mount o "$OUT"
mount d "$install_dir"
o:
install.bat
exit
EOF
  echo "Installing Turbo Pascal 7 into lab/tp (DOSBox-X)..."
  run_dosbox install
  if ! tpc_present; then
    echo "Incomplete installation. See $TP/INST.LOG and $OUT/dosbox-install.log" >&2
    exit 1
  fi
  echo "TPC.EXE installed."
fi

emit_crlf "$OUT/BUILD.BAT" <<EOF
@echo off
s:
cd \\
c:\\tp\\bin\\tpc.exe -UC:\\TP\\UNITS;S:\\UNITS;S:\\TPLIBS\\CGA\\LIB -EO:\\ -B S:\\XDP_COMP.PAS > O:\\COMP.LOG
o:\\xdp_comp.exe > O:\\HELP.TXT
EOF

if [[ "$PLAY" -eq 1 ]]; then
  emit_crlf "$OUT/BUILD.BAT" <<EOF
@echo off
s:
cd \\
c:\\tp\\bin\\tpc.exe -UC:\\TP\\UNITS;S:\\UNITS;S:\\TPLIBS\\CGA\\LIB -EO:\\ -B S:\\XDP_COMP.PAS > O:\\COMP.LOG
o:\\xdp_comp.exe > O:\\HELP.TXT
c:\\tp\\bin\\tpc.exe -UC:\\TP\\UNITS;S:\\UNITS;S:\\TPLIBS\\CGA\\LIB -EO:\\ -B S:\\XDP_PLAY.PAS > O:\\PLAY.LOG
EOF
fi

cat >"$OUT/session.conf" <<EOF
[autoexec]
mount c "$TP"
mount o "$OUT"
mount s "$ROOT"
o:
build.bat
exit
EOF

echo "Compiling XDP_COMP.PAS..."
run_dosbox build

log="$OUT/COMP.LOG"
exe="$OUT/XDP_COMP.EXE"
help="$OUT/HELP.TXT"
if [[ ! -f "$log" || ! -f "$exe" ]] || ! grep -q "bytes code" "$log"; then
  echo "The compilation failed." >&2
  [[ -f "$log" ]] && cat "$log" >&2
  exit 1
fi
if grep -q "Error " "$log"; then
  echo "The compiler reported an error." >&2
  cat "$log" >&2
  exit 1
fi

echo
echo "===== COMP.LOG ====="
cat "$log"
echo
echo "===== XDP_COMP.EXE with no arguments ====="
cat "$help"
echo
echo "Binary: $exe ($(wc -c <"$exe") bytes)"

if [[ "$PLAY" -eq 1 ]]; then
  echo
  echo "===== PLAY.LOG ====="
  if [[ ! -f "$OUT/PLAY.LOG" ]]; then
    echo "PLAY.LOG is missing." >&2
    exit 1
  fi
  cat "$OUT/PLAY.LOG"
  echo
  if [[ -f "$OUT/XDP_PLAY.EXE" ]] && grep -q "bytes code" "$OUT/PLAY.LOG" && ! grep -q "Error " "$OUT/PLAY.LOG"; then
    echo "XDP_PLAY.EXE was produced."
  else
    echo "XDP_PLAY failed to compile." >&2
    exit 1
  fi
fi
