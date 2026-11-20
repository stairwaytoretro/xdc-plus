# Third-party code

This file lists code that XDC-Plus builds on, where it comes from, and which parts the build actually compiles. The XDC-Plus changes are under the MIT licence in [LICENSE](LICENSE).

## XDC

The compiler and player started from [XDC](https://github.com/MobyGamer/XDC) by Jim Leonard (Trixter / Hornet). That project is MIT licensed, Copyright (c) 2014 Jim Leonard. The imported commit is `56a5dc1951e1f0b8747fe8fa4614c607e2f91c8b`.

## Units the build compiles

`lab/build.sh` runs Turbo Pascal 7 with this unit search path:

```
C:\TP\UNITS;S:\UNITS;S:\TPLIBS\CGA\LIB
```

`C:\TP\UNITS` is the Turbo Pascal installation. `S:\UNITS` is the UNITS submodule. `S:\TPLIBS\CGA\LIB` is one directory of the TPLibs submodule. No other directory from those repositories is searched.

These are the units the program sources name, and the units those pull in:

| Unit | File | Named by | From |
| --- | --- | --- | --- |
| support | `UNITS/SUPPORT.PAS` | `XDP_COMP`, `XDP_PLAY`, `XDC_DELT`; also `RTEH` | MobyGamer/UNITS |
| cmdlin | `UNITS/CMDLIN.PAS` | `XDP_PLAY` | MobyGamer/UNITS |
| tinterrupts | `UNITS/TINTERRU.PAS` | `XDP_PLAY` | MobyGamer/UNITS |
| ringbufu | `UNITS/RINGBUFU.PAS` | `XDP_PLAY` | MobyGamer/UNITS |
| rteh | `UNITS/RTEH.PAS` | `XDP_COMP` | MobyGamer/UNITS |
| m6845ctl | `TPLibs/CGA/LIB/M6845CTL.PAS` | `XDC_COMM` and `TINTERRU` | MobyGamer/TPLibs |
| objects | Turbo Pascal `OBJECTS` | `XDP_PLAY`, `XDP_COMP`, `XDC_DELT`, `RINGBUFU` | Borland, not included |
| memory | Turbo Pascal `MEMORY` | `XDP_COMP` | Borland, not included |
| dos | Turbo Pascal `DOS` | `XDP_PLAY`, `XDP_COMP`, `XDC_SB`, `SUPPORT`, `TINTERRU` | Borland, not included |

`SUPPORT` uses Borland's `DOS` only. `RINGBUFU` uses Borland's `OBJECTS` only. `RTEH` uses `SUPPORT`. `CMDLIN` and `M6845CTL` use no other unit. `TINTERRU` uses `M6845CTL` and Borland's `DOS`.

### MobyGamer/UNITS and MobyGamer/TPLibs

Both are git submodules. This repository points at them and does not store their files:

- [MobyGamer/UNITS](https://github.com/MobyGamer/UNITS) at `7088996c035a4b539417db3dc50c957b3b8123c8`
- [MobyGamer/TPLibs](https://github.com/MobyGamer/TPLibs) at `b3a123ddeb82635b0cd858fade2e0b6602555aff`

Neither repository has a licence file. `SUPPORT`, `TINTERRU`, `RINGBUFU`, `RTEH`, and `M6845CTL` are Jim Leonard's units and carry no licence notice of their own. The header of `TINTERRU.PAS` calls it Trixter's interrupt and timer unit and thanks Mark Feldman, Kris Heidenstrom, and Klaus Hartnegg.

On 20 November 2026, Jim Leonard confirmed by email to the XDC-Plus maintainer that his units in these two repositories may be treated as MIT-licensed, under the same terms as XDC, Copyright (c) Jim Leonard. XDC-Plus relies on that permission for the source and for the distributed binaries.

`CMDLIN.PAS` is by Jim Walsh. Its header says "This is completely public domain". A later fix in that file is credited to Trixter.

The other files in the UNITS submodule are not referenced by this build.

The rest of TPLibs is unused by XDC-Plus and keeps its own licences. That includes TTOT, SPAWNO (`spwno413`), STREAM16, EXELINKR, and the rest of the CGA tree. The only TPLibs file the build compiles is `CGA/LIB/M6845CTL.PAS`.

## Turbo Pascal 7

Borland Turbo Pascal 7 is not included. The runtime units, including `SYSTEM`, `DOS`, `OBJECTS`, and `MEMORY`, must be supplied by the user. `lab/build.sh` takes your own copy and does not store it in this repository.

## Sound Blaster

`XDC_SB.PAS` is an original from-scratch Sound Blaster unit. It replaces Stefan Goehler's SOUNDLIB, which original XDC used. Only SOUNDLIB's interface names are kept, so the player call sites stay the same. The unit contains none of SOUNDLIB's code, and SOUNDLIB is not included here.
