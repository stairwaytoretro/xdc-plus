# xdc-plus

xdc-plus is an extension of Jim Leonard's (Trixter) XDC (X86 Delta Compiler), https://github.com/MobyGamer/XDC. Goal: add RGBI video modes, first CGA 160x100x16 (modified text mode), then EGA 320x200x16.

Imported upstream commit: 56a5dc1951e1f0b8747fe8fa4614c607e2f91c8b (https://github.com/MobyGamer/XDC, master branch).

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
