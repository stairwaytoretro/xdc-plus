# xdc-plus

xdc-plus is an extension of Jim Leonard's (Trixter) XDC (X86 Delta Compiler), https://github.com/MobyGamer/XDC. Goal: add RGBI video modes, first CGA 160x100x16 (modified text mode), then EGA 320x200x16.

Imported upstream commit: 56a5dc1951e1f0b8747fe8fa4614c607e2f91c8b (https://github.com/MobyGamer/XDC, master branch).

Genuine IBM CGA shows snow in 80-column modes; there is no anti-snow handling for now.

`xdc_play` names the video card in the computer with `/ADAPTER=AUTO` (the default, same as omitting it), `/ADAPTER=CGA`, `/ADAPTER=EGA`, or `/ADAPTER=VGA`. That option selects the card, not the picture format. The format comes from the `.XDV` header `vidmode`.

## Screen modes

A compiler script sets `screenmode`. `xdc_comp` stores that value in the `.XDV` header `vidmode`, and `xdc_play` reads it from the header. `/ADAPTER=` selects the card only (meaningful for mode 5); do not force CGA on an EGA card. `/ADAPTER=CGA` on an EGA card shows nothing, because an EGA has no CGA mode register at 3D8h. Leave the default autodetect unless detection is wrong.

| `screenmode` | `vidmode` | Mode |
| --- | --- | --- |
| 1 | 1 | 160x200x16 composite (real CGA, composite output) |
| 2 | 2 | 640x200x2 (CGA, EGA or VGA) |
| 3 | 3 | 160x200x16 Tandy/PCjr |
| 4 | 4 | 240x128x2 HP 95LX |
| 5 | 5 | 160x100x16 RGBI text tweak (CGA, EGA or VGA) |

## Hardware test results

On an Atari PC2 (8088, built-in NSI Logic EVC315-S, CGA monitor via CGA2SCART to a Sony Trinitron TV), after a cold boot with the card in CGA mode, no option, `/ADAPTER=AUTO`, and `/ADAPTER=CGA` all display the 160x100 clip correctly. After a warm boot with the card in EGA mode (EGA switches 1110, CGA monitor), no option, `/ADAPTER=AUTO`, and `/ADAPTER=EGA` display correctly, and `/ADAPTER=CGA` shows nothing, as expected. This confirms that Jenner's 200-line switch works on this real EGA. The DOSBox-X 350-line behaviour is an emulator limit.

DOSBox-X `machine=ega` does not keep Jenner's 200-line switch. The player writes 8 to 0040:0088 (was 9), and the mode set stores 9 again. The 160x100 picture is complete but sits in the top of a 350-line frame, with black below, and the 200-line palette is shown as 64-color EGA (the white border comes out light green). Autodetect on that machine selects EGA, not VGA. On the Atari PC2 EGA path above, the same switch does select 200 lines, so this 350-line result is a DOSBox-X limit. The init is not special-cased for the emulator.

---

XDC
===

XDC 8088+CGA video/animation compiler

This repository contains the source code and other files for the XDC
video/animation system for 8088-based PCs with a CGA card.  For more
information, consult x86dc.wordpress.com

The code is, likely to your extreme shock and disgust, written entirely in
16-bit real-mode pascal with some inline assembler.  This was initially done on
purpose so that timing compiled code could be done directly on the target
hardware.  It was found during development that careful measurement and
calculation could achieve >95% accuracy, but it was too close to a competition
deadline to rewrite quickly, so here it is.  You can run it in DOSBox or a
virtual session (ie. Windows XP in VirtualBox) without any trouble, albeit with
some DOS-era limitations such as required 8.3 filenames.

Compiling the code as-is requires Turbo Pascal 7.0 as well as some files from
MobyGamer/TPLibs and MobyGamer/UNITS.
