# DOS compilation lab

This folder rebuilds the XDC compiler (`xdc_comp`) with Turbo Pascal 7.0 inside DOSBox-X. The XDC sources are not modified. DOS binaries are launched only inside the emulator.

## Prerequisites

- DOSBox-X (`sudo apt install dosbox-x` on Ubuntu 24.04). The script starts it without a window (`SDL_VIDEODRIVER=dummy`).
- Your own copy of Turbo Pascal 7.0: the zip archive that contains `TP70/PASCAL.EXE`, or `PASCAL.EXE` itself (PKSFX 2.04g self-extractor). These files are not part of the repository.
- The submodules, from the repository root:

```
git submodule update --init --recursive
```

## Build

```
./lab/build.sh /path/to/tp7.zip
```

On the first run, the script:

1. extracts `PASCAL.EXE` from the zip archive with the host zip tool (it is not a DOS binary);
2. runs `PASCAL.EXE -d -o` inside DOSBox-X, which installs the `TP\` tree into `lab/tp/`;
3. runs `TPC.EXE` on `XDC_COMP.PAS`, with the units `C:\TP\UNITS`, `UNITS`, and `TPLibs\CGA\LIB`;
4. runs the produced `XDC_COMP.EXE` with no arguments, and writes the help text to `lab/out/HELP.TXT`.

Later runs reuse `lab/tp/` and no longer need the archive path. To reinstall: `rm -rf lab/tp`.

The compiler log is `lab/out/COMP.LOG`. A successful build ends with a line of the form `4097 lines, … bytes code, … bytes data`, with neither `Error` nor `Warning`.

## Player (`xdc_play`)

```
./lab/build.sh play
```

`XDC_PLAY.PAS` compiles its other units, then stops on `Error 15: File not found (SOUNDLIB.TPU)`. `SOUNDLIB.PAS` was removed upstream; this repository does not provide a replacement.

## TPC command

`S:` is the repository root, `O:` is `lab/out`, `C:\TP` is the Turbo Pascal installation.

```
TPC -UC:\TP\UNITS;S:\UNITS;S:\TPLIBS\CGA\LIB -EO:\ -B S:\XDC_COMP.PAS
```

## Ignored files

`lab/tp/`, `lab/dist/`, `lab/out/`, and `*.zip` files placed in `lab/` are ignored by git. Do not commit Borland files, the archive, or the produced `.EXE` and `.TPU` files.
