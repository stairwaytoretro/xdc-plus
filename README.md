# XDC-Plus

XDC-Plus is an extension of Jim Leonard's (Trixter / Hornet) XDC (X86 Delta Compiler), https://github.com/MobyGamer/XDC. @StairwayToRetro maintains it, with help from Grok Bot. RGBI modes: CGA 160x100x16 (modified text mode, screen mode 5) and EGA 320x200x16 (BIOS mode 0Dh, screen mode 6).

The executables were renamed from XDC_PLAY/XDC_COMP to XDP_PLAY/XDP_COMP. Trixter's original XDC shipped those tools as XDC_PLAY and XDC_COMP.

The player is v0.1.0. The version is bumped when a merged pull request changes the player. A local test build may carry a suffix such as `v0.1.0-test1` and is not a release.

Imported upstream commit: 56a5dc1951e1f0b8747fe8fa4614c607e2f91c8b (https://github.com/MobyGamer/XDC, master branch).

Genuine IBM CGA shows snow in 80-column modes; there is no anti-snow handling for now.

`xdp_play` names the video card in the computer with `/ADAPTER=AUTO` (the default, same as omitting it), `/ADAPTER=CGA`, `/ADAPTER=EGA`, or `/ADAPTER=VGA`. That option selects the card, not the picture format. The format comes from the `.XDV` header `vidmode`.

## Player options

`XDP_PLAY /?` lists every switch. Switches start with `/` or `-`, are not case-sensitive, and can come before or after the file name in any order.

| Switch | Effect |
| --- | --- |
| `/?` or `/h` | Help screen |
| `/NOSOUND` or `/q` | No audio; frames are paced by the PIT at the source frame rate |
| `/ADAPTER=xxx` | Video card in this computer: `AUTO` (default), `CGA`, `EGA` or `VGA` |
| `/wNAME` | After playback, write the screen buffer to file `NAME` |
| `/kN` | Read `N` KB from disk in a single operation |
| `/p` | Presentation mode: no messages, no credits, no statistics. The last picture stays on screen at exit, to chain clips |
| `/r` | Same as `/p`, but return to the DOS text prompt at exit |
| `/d` | Show the queue depth indicator |

### `/p` and `/r`

With no switch, the player shows the credits, waits for a key, plays the clip, then returns to the DOS text prompt and prints the statistics.

`/p` is Trixter's presentation mode. Nothing is printed and playback starts at once. When the clip ends, the last picture stays on screen. Use it to chain clips from a batch file: the next clip starts without a flash back to text in between. DOS is back after the last clip, but the prompt is not usable: in mode 6 it appears as huge 40-column text over the picture, and in mode 5 it is invisible, so the picture looks frozen. Play the last clip with `/r` instead, or end the batch file with `MODE CO80`.

`/r` is the same as `/p`: no messages, playback starts at once. When the clip ends, the player returns to the DOS text prompt (the text mode DOS was in when the player started, or 80x25 colour text). `/p /r` is the same as `/r`.

```
@ECHO OFF
XDP_PLAY /p CLIP1.XDV
XDP_PLAY /p CLIP2.XDV
XDP_PLAY /r CLIP3.XDV
```

To end on a `/p` clip, add `MODE CO80` as the last line instead.

A failed start and Ctrl-Break always return to the text prompt.

## Screen modes

A compiler script sets `screenmode`. `xdp_comp` stores that value in the `.XDV` header `vidmode`, and `xdp_play` reads it from the header. `/ADAPTER=` selects the card only (meaningful for mode 5); do not force CGA on an EGA card. `/ADAPTER=CGA` on an EGA card shows nothing, because an EGA has no CGA mode register at 3D8h. Leave the default autodetect unless detection is wrong.

| `screenmode` | `vidmode` | Mode |
| --- | --- | --- |
| 1 | 1 | 160x200x16 composite (real CGA, composite output) |
| 2 | 2 | 640x200x2 (CGA, EGA or VGA) |
| 3 | 3 | 160x200x16 Tandy/PCjr |
| 4 | 4 | 240x128x2 HP 95LX |
| 5 | 5 | 160x100x16 RGBI text tweak (CGA, EGA or VGA) |
| 6 | 6 | 320x200x16 EGA planar, BIOS mode 0Dh (EGA or VGA) |

### Mode 6 (EGA 320x200x16)

`screenmode=6` (or `screenmode=320x200`) is BIOS mode 0Dh: 320x200, 16 colours, four bit planes at A000. A scanline is 40 bytes. The compiler buffer is the four planes back to back (32,000 bytes): plane 0 at offset 0, then 8,000, 16,000 and 24,000. Plane 0 is blue, plane 1 green, plane 2 red, plane 3 intensity, which is the default EGA palette in mode 0Dh and the same RGBI colours as CGA (colour 6 is brown). An 8-bit BMP is required. Each palette entry is mapped to the nearest of those 16 colours, so a file painted with the CGA RGBI palette keeps its indices.

The generated code is the same REP STOS / REP MOVS the other modes use, aimed at A000. Deltas are split on plane boundaries and emitted one plane at a time. The plane with the largest remaining delta goes first. Switching planes is one sequencer Map Mask write (`MOV AX,imm16` / `OUT DX,AX` to 3C4h, 4 bytes). A frame does that at most four times, and it skips a plane that has nothing to draw. Write mode 0, bit mask FFh and set/reset off are set once when the mode starts: a store replaces the whole byte in the enabled plane and leaves the other three planes alone, with no read-before-write. Latched copies are not used, because the new pixels come from the CPU, not from video memory.

The cycle budget is the same one modes 1–5 use: half of a 4.77 MHz frame (`76*262*4/2` = 39,824 cycles), scaled by `defaultFPS/sourcefps`. At 60 fps that is about 39,800 cycles. In the compiler's 8088 model a copied byte costs 19.2 cycles and a filled byte costs 13.7, so one frame can copy about 2,070 bytes or fill about 2,900. A map-mask switch is charged 48 cycles. A full 32,000-byte picture does not fit in one frame. Solid colour is cheap, because a run of 00h or FFh in a plane is a REP STOS, and a plane that did not change is not written. Arbitrary picture data takes about 15 frames to converge. The compiler keeps the leftovers and finishes them on the following frames, same as the CGA modes. The colour-bar test picture is 15,616 bytes against black, 15,360 of them runs, which is about six of these frames. Each later step of the square is 384 bytes and fits in one frame.

An 8 MHz 8088 (the Atari PC2) has about 8/4.77 ≈ 1.7 times as many CPU clocks per frame. The compiler does not raise the budget. EGA video memory adds wait states the CGA-derived constants do not measure, so a clip that stays inside this budget is the safe target for that machine, with some spare time if the bus keeps up.

Mode 6 needs EGA or VGA. `/ADAPTER=CGA`, or a machine whose BIOS looks like CGA only, makes the player stop with a message and leave the display in text mode. It does not set mode 0Dh. On EGA the player applies the same 200-line switch as mode 5 (Andrew Jenner: decrement switch nibble 3 or 9) before the BIOS mode set, so mode 0Dh is 200 lines at 15.7 kHz and syncs on a CGA monitor. Exit restores the startup text mode (80x25 in practice) and the original switch byte. `/p` leaves the graphics mode up; `/r` returns to the text prompt (see Player options). On VGA, mode 0Dh is the BIOS mode, usually 320x200 double-scanned to 400 lines at 70 Hz. A 15 kHz display should use the card's EGA state so the EGA path above is taken. The Morse KP800/16 in its VGA state answers the VGA BIOS call, so AUTO takes that 70 Hz path.

`lab/gen320.py` writes a short synthetic clip: sixteen horizontal colour bars and a 32x32 white square that steps right. `lab/run320.sh /path/to/tp7.zip` builds it with Turbo Pascal and `xdp_comp`. The first picture is held long enough for the runs to finish before the square moves. `/wNAME` on a mode 6 file writes 32,000 bytes, plane 0 then 1, 2 and 3, 40 bytes per scanline. Modes 1–5 still write 16,000 bytes from B800.

## Hardware test results

On an Atari PC2 (8088, built-in NSI Logic EVC315-S, CGA monitor via CGA2SCART to a Sony Trinitron TV), after a cold boot with the card in CGA mode, no option, `/ADAPTER=AUTO`, and `/ADAPTER=CGA` all display the 160x100 clip correctly. After a warm boot with the card in EGA mode (EGA switches 1110, CGA monitor), no option, `/ADAPTER=AUTO`, and `/ADAPTER=EGA` display correctly, and `/ADAPTER=CGA` shows nothing, as expected. This confirms that Jenner's 200-line switch works on this real EGA. The DOSBox-X 350-line behaviour is an emulator limit.

On an IBM PC/AT 5170 with a Morse KP800/16 EGA+VGA card in VGA mode (VGA output through a Guillemot VGA-to-SCART 15 kHz converter), `XDP_PLAY CLIP.XDV`, `/ADAPTER=AUTO`, and `/ADAPTER=VGA` all display the 160x100 clip correctly. Mode 5 is now confirmed on real CGA, EGA, and VGA hardware, with correct autodetection.

Mode 5 fills every cell with character 0xDE (right half-block): four background dots, then four foreground dots. Those two pixels are equal only when the character clock is 8 dots wide. CGA 80-column text is 8 dots (80 x 8 = 640). VGA mode 3 is 9 dots, and on the KP800 (Cirrus CL-GD510/520) that ninth column is a dark vertical gap. The same gap shows up with the card's DB9 output on a 15 kHz CGA monitor, because the VGA BIOS still answers INT 10h AX=1A00h and AUTO takes the VGA init path. Pure CGA mode has no ninth dot, and the bars are clean there. The EGA and VGA paths now select 8-dot characters after the BIOS mode set. On VGA, when the BIOS left the standard 100-character line, the 28.322 MHz text clock is exchanged for 25.175 MHz inside the same sequencer reset (28.322/9 = 25.175/8) and the horizontal CRTC totals stay as the BIOS set them, so a 31.5 kHz monitor keeps sync. Any other VGA timing keeps the BIOS clock and stretches the horizontal total by 9/8, so the faster character clock does not raise the horizontal frequency. `/ADAPTER=EGA` uses that VGA sequence when the BIOS answers the VGA call. An IBM EGA color mode is already 8-dot; its clocking register is write-only, so that path rewrites the mode-3 value 01h. The CGA path is unchanged.

On the same IBM PC/AT 5170, the Morse KP800/16 (Cirrus Logic CL-GD510A/520A, BIOS 2.20, official utility EAGLE 2.00) driving a 15 kHz CGA monitor or TV through its DB9 output plays the 160x100 clip in mode 5 with thin vertical fringes while the card is in its EGA state. Each vertical color bar starts with a one-dot sliver of the previous bar's color. Sync is stable and horizontal bars are clean. That fringe is separate from the ninth-dot gap above: between the EGA state and the state after `EAGLE CGA`, the only Cirrus extension differences were the chip personality (SR AF: EGA vs "CGA From EGA State") and EAGLE's soft lock (SR BE). Character width, panning, clocks, and the other registers were identical. After `EAGLE CGA`, the same clip and the same DIP switches play cleanly. `/ADAPTER=AUTO` (the default) then resolves to CGA, and `/ADAPTER=CGA` also works.

On this card, run `EAGLE CGA`, then `XDP_PLAY CLIP.XDV` (AUTO). Do not use `/ADAPTER=CGA` while the card is still in the EGA state. To return to EGA afterwards, run `EAGLE EGA` or reboot. No DIP switch change is needed. Other EGA cards, such as the NSI Logic EVC315-S built into the Atari PC2, are clean in mode 5 without this step. This note is specific to the KP800/16 and may apply to other Cirrus GD510A/520A boards.

DOSBox-X `machine=ega` does not keep Jenner's 200-line switch. The player writes 8 to 0040:0088 (was 9), and the mode set stores 9 again. The 160x100 picture is complete but sits in the top of a 350-line frame, with black below, and the 200-line palette is shown as 64-color EGA (the white border comes out light green). Autodetect on that machine selects EGA, not VGA. On the Atari PC2 EGA path above, the same switch does select 200 lines, so this 350-line result is a DOSBox-X limit. The init is not special-cased for the emulator.

## Audio

`xdp_play` plays the `.XDV` audio track on a Sound Blaster and uses the DMA IRQ as the frame clock, the same pacing upstream XDC got from `soundlib`. The unit is `XDC_SB.PAS`. It is 8-bit mono unsigned PCM.

```
SET BLASTER=A220 I7 D1
XDP_PLAY CLIP.XDV
```

`A` is the I/O port in hex, `I` is the IRQ, `D` is the 8-bit DMA channel. If `BLASTER` is unset, the player tries `A220 I7 D1`. Supported IRQs are 2, 3, 5, 7, and 9. On an AT, IRQ 2 is the cascade and is serviced as IRQ 9. On an XT there is one 8259, so IRQ 2 stays IRQ 2. DMA 0, 1, and 3 are accepted. Channel 1 is the default. Channel 2 is left for the floppy controller.

DSP 2.00 and newer use auto-init DMA (command `48h`, then `1Ch`). DSP 1.xx has no auto-init, so each IRQ restarts a single-cycle transfer (command `14h`). SB Pro and SB16 are driven with those same 8-bit commands.

The time constant is `256 - 1000000/rate`, using integer division, then clamped:

| DSP | Playback | Rate clamp |
| --- | --- | --- |
| 1.xx | single-cycle `14h` | 4000–22222 Hz (time constant 6–211) |
| 2.xx and 3.xx | auto-init `48h`+`1Ch` | 4000–21739 Hz (time constant 6–210) |
| 4.xx | auto-init `1Ch` in 8-bit compatible mode | 4000–45454 Hz (time constant 6–234) |

Command `1Ch` is the non-high-speed path. High-speed command `90h` is not used: on DSP 2.xx and 3.xx the chip ignores further commands until a reset, which fights a clean exit. DOSBox-X `sbtype=sb2` enforces the same time-constant cap of 210 unless the high-speed command is used. A clamped file plays a little slow, and the frames follow that clock.

If the DSP does not answer, the player prints the reason and returns to DOS. It does not switch to the timer. Run it again with `/NOSOUND` (or `/q`) to pace frames from the PIT and play no audio:

```
XDP_PLAY /NOSOUND CLIP.XDV
```

Exit, a failed start, and Ctrl-Break turn the speaker off, stop DMA, and restore the IRQ vector and the 8259 mask. `/p` still leaves the tweaked video mode up, as before; `/r` returns to the text prompt. With no switch, exit returns to the startup text mode (80x25 in practice).

Build `xdp_play` and `xdp_comp` with Turbo Pascal 7 and the default software floating point (`{$N-}`). Turbo Pascal 7 is not included. The player has to run on an 8088 that has no 8087. `xdp_comp` uses Turbo Vision's `MemAllocSeg` from the Turbo Pascal `MEMORY` unit.

`lab/toneclip.py` builds a 10 second 160x100 clip at 11040 Hz (184 samples per frame, 60 fps, so the compiler does not have to stretch the rate). `lab/clip/CLIP.SCR` is the script. `lab/runsound.sh` plays it in DOSBox-X.

## Related work

[Scali (Scalibq)](https://github.com/Scalibq/XDC) independently forked XDC in late 2023 and added PC speaker, Covox, Tandy/PCjr and Sound Blaster 1.x playback to the player. His write-up is [Video playback (with audio) on low-end MS-DOS machines](https://scalibq.wordpress.com/2024/01/01/video-playback-on-low-end-ms-dos-machines/). XDC-Plus is a separate project and does not use code from that fork.

## Licence

XDC-Plus is based on XDC by Jim Leonard (Trixter / Hornet) and extended by @StairwayToRetro, with help from Grok Bot.

Released under the MIT License: Copyright (c) 2014 Jim Leonard; Copyright (c) 2026 StairwayToRetro (XDC-Plus changes). See [LICENSE](LICENSE) and [THIRD_PARTY.md](THIRD_PARTY.md).

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
