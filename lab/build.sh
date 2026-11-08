#!/usr/bin/env bash
# Compile XDC_COMP.PAS avec Turbo Pascal 7 dans DOSBox-X.
# Les binaires DOS ne sont jamais lancés sur l'hôte.
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
      echo "  tp7.zip ou PASCAL.EXE : copie personnelle de Turbo Pascal 7 (obligatoire au premier lancement)."
      echo "  play : tente aussi XDC_PLAY.PAS (échoue sans SOUNDLIB)."
      exit 0
      ;;
    *)
      if [[ -n "$SRC" ]]; then
        echo "Argument inattendu: $arg" >&2
        exit 1
      fi
      SRC=$arg
      ;;
  esac
done

if ! command -v dosbox-x >/dev/null 2>&1; then
  echo "dosbox-x est introuvable. Sur Ubuntu : sudo apt install dosbox-x" >&2
  exit 1
fi

if [[ ! -f "$ROOT/UNITS/SUPPORT.PAS" || ! -f "$ROOT/TPLibs/CGA/LIB/M6845CTL.PAS" ]]; then
  echo "Sous-modules absents. Depuis la racine : git submodule update --init --recursive" >&2
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
        echo "DOSBox-X a échoué ($label). Journal : $OUT/dosbox-${label}.log" >&2
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
    echo "Turbo Pascal 7 n'est pas installé dans lab/tp." >&2
    echo "Passez votre archive : $0 /chemin/vers/tp7.zip" >&2
    exit 1
  fi
  if [[ ! -f "$SRC" ]]; then
    echo "Fichier introuvable: $SRC" >&2
    exit 1
  fi
  rm -rf "$DIST/unpack"
  mkdir -p "$DIST/unpack"
  # L'archive zip fournie par l'utilisateur n'est pas un binaire DOS.
  # PASCAL.EXE (PKSFX) est copié puis exécuté uniquement dans DOSBox-X.
  if unzip -l "$SRC" 2>/dev/null | grep -q 'PASCAL.EXE'; then
    unzip -o -q "$SRC" -d "$DIST/unpack"
  else
    cp -f "$SRC" "$DIST/unpack/PASCAL.EXE"
  fi
  installer=$(find "$DIST/unpack" -iname 'PASCAL.EXE' -type f | head -n 1 || true)
  if [[ -z "$installer" ]]; then
    echo "PASCAL.EXE introuvable dans $SRC" >&2
    exit 1
  fi
  install_dir=$(cd "$(dirname "$installer")" && pwd)
  # PKSFX 2.04g : -d recrée les répertoires stockés dans l'archive (TP\BIN, TP\UNITS, ...).
  emit_crlf "$OUT/INSTALL.BAT" <<'EOF'
@echo off
d:\pascal.exe -d -o c:\ > c:\inst.log
EOF
  # C: reçoit l'arborescence TP\. Le .BAT est sur O:.
  cat >"$OUT/session.conf" <<EOF
[autoexec]
mount c "$TP"
mount o "$OUT"
mount d "$install_dir"
o:
install.bat
exit
EOF
  echo "Installation de Turbo Pascal 7 dans lab/tp (DOSBox-X)..."
  run_dosbox install
  if ! tpc_present; then
    echo "Installation incomplète. Voir $TP/INST.LOG et $OUT/dosbox-install.log" >&2
    exit 1
  fi
  echo "TPC.EXE installé."
fi

emit_crlf "$OUT/BUILD.BAT" <<EOF
@echo off
s:
cd \\
c:\\tp\\bin\\tpc.exe -UC:\\TP\\UNITS;S:\\UNITS;S:\\TPLIBS\\CGA\\LIB -EO:\\ -B S:\\XDC_COMP.PAS > O:\\COMP.LOG
o:\\xdc_comp.exe > O:\\HELP.TXT
EOF

if [[ "$PLAY" -eq 1 ]]; then
  emit_crlf "$OUT/BUILD.BAT" <<EOF
@echo off
s:
cd \\
c:\\tp\\bin\\tpc.exe -UC:\\TP\\UNITS;S:\\UNITS;S:\\TPLIBS\\CGA\\LIB -EO:\\ -B S:\\XDC_COMP.PAS > O:\\COMP.LOG
o:\\xdc_comp.exe > O:\\HELP.TXT
c:\\tp\\bin\\tpc.exe -UC:\\TP\\UNITS;S:\\UNITS;S:\\TPLIBS\\CGA\\LIB -EO:\\ -B S:\\XDC_PLAY.PAS > O:\\PLAY.LOG
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

echo "Compilation de XDC_COMP.PAS..."
run_dosbox build

log="$OUT/COMP.LOG"
exe="$OUT/XDC_COMP.EXE"
help="$OUT/HELP.TXT"
if [[ ! -f "$log" || ! -f "$exe" ]] || ! grep -q "bytes code" "$log"; then
  echo "La compilation a échoué." >&2
  [[ -f "$log" ]] && cat "$log" >&2
  exit 1
fi
if grep -q "Error " "$log"; then
  echo "Le compilateur a signalé une erreur." >&2
  cat "$log" >&2
  exit 1
fi

echo
echo "===== COMP.LOG ====="
cat "$log"
echo
echo "===== XDC_COMP.EXE sans argument ====="
cat "$help"
echo
echo "Binaire: $exe ($(wc -c <"$exe") octets)"

if [[ "$PLAY" -eq 1 ]]; then
  echo
  echo "===== PLAY.LOG ====="
  if [[ ! -f "$OUT/PLAY.LOG" ]]; then
    echo "PLAY.LOG absent." >&2
    exit 1
  fi
  cat "$OUT/PLAY.LOG"
  echo
  if grep -q "File not found (SOUNDLIB.TPU)" "$OUT/PLAY.LOG"; then
    echo "Échec attendu : SOUNDLIB.TPU est absent (SOUNDLIB.PAS retiré d'upstream)."
  elif grep -q "bytes code" "$OUT/PLAY.LOG" && ! grep -q "Error " "$OUT/PLAY.LOG"; then
    echo "XDC_PLAY.EXE a été produit."
  else
    echo "Échec inattendu de XDC_PLAY." >&2
    exit 1
  fi
fi
