unit xdc_common;
{procedures and functions common to both the encoder and player}

interface

procedure xdc_setvid(b:byte); {set video mode}
procedure xdc_donevid; {mode 3, then restore any EGA switch byte}
procedure xdc_releasevid; {restore the EGA switch byte; leave the CRTC alone}
procedure fatalerr(s:string);

var
  egaSwitchesSaved:boolean;
  egaSwitchesOrig:byte;
  egaSwitchesForced:byte; {value stored at 0040:0088 before the mode set}
  egaSwitchesAfter:byte;  {value read back after the mode set}

implementation

uses
  xdc_globals,xdc_log,m6845ctl;

const
  {200-line RGBI palette: intensity is bit 4, not secondary green.}
  ega200Pal:array[0..16] of byte=(
    $00,$01,$02,$03,$04,$05,$06,$07,
    $10,$11,$12,$13,$14,$15,$16,$17,
    $00);

procedure fillTextDE;
{8000 cells of character 0xDE, attribute 0. Matches the compiler's previous frame.}
begin
  asm
    mov     ax,$B800
    mov     es,ax
    xor     di,di
    cld
    mov     ax,$00DE
    mov     cx,8000
    rep     stosw
  end;
end;

procedure cursorOff;
begin
  asm
    mov     ah,1
    mov     cx,$2000
    int     10h
  end;
end;

procedure blinkOffBIOS;
begin
  asm
    mov     ax,$1003
    xor     bl,bl
    int     10h
  end;
end;

procedure setCrtc(index,value:byte);
begin
  PortW[$3D4]:=(word(value) shl 8) or index;
end;

procedure forceEga200;
{Andrew Jenner: low nibble 3 or 9 means a 350-line monitor.
 Decrementing it selects the matching 200-line switch value (2 or 8)
 so the BIOS mode set stays at 200 lines / 15.7 kHz.}
var
  sw:byte;
begin
  sw:=Mem[$0040:$0088];
  egaSwitchesOrig:=sw;
  egaSwitchesSaved:=true;
  if (sw and $0F)=$03 then sw:=sw-1
  else if (sw and $0F)=$09 then sw:=sw-1;
  egaSwitchesForced:=sw;
  Mem[$0040:$0088]:=sw;
end;

procedure setEga200Palette;
begin
  asm
    push    es
    push    ds
    pop     es
    mov     ax,$1002
    mov     dx,offset ega200Pal
    int     10h
    pop     es
  end;
end;

function resolvedAdapter:byte;
var
  alv,blv:byte;
begin
  if videoAdapter<>0 then begin
    resolvedAdapter:=videoAdapter;
    exit;
  end;
  alv:=0;
  asm
    mov     ax,$1A00
    int     10h
    mov     alv,al
  end;
  if alv=$1A then begin
    resolvedAdapter:=3; {VGA BIOS answered INT 10h AX=1A00h}
    exit;
  end;
  blv:=$10;
  asm
    mov     ah,$12
    mov     bl,$10
    int     10h
    mov     blv,bl
  end;
  if blv<>$10 then resolvedAdapter:=2 else resolvedAdapter:=1;
end;

function vgaBiosPresent:boolean;
{INT 10h AX=1A00h. True when a VGA BIOS answers, including a VGA BIOS
 that is driving a 15 kHz EGA/CGA monitor.}
var
  alv:byte;
begin
  alv:=0;
  asm
    mov     ax,$1A00
    int     10h
    mov     alv,al
  end;
  vgaBiosPresent:=(alv=$1A);
end;

procedure seqSyncReset;
{Synchronous reset: bit 1 clear, bit 0 set. Clearing bit 0 is an
 asynchronous reset, which tri-states the outputs and can drop sync
 and video RAM. Both bits must be 1 again before the sequencer runs.}
begin
  PortW[$3C4]:=$0100;
end;

procedure seqRun;
begin
  PortW[$3C4]:=$0300;
end;

procedure force8DotEga;
{IBM color text is 8 dots wide. Mode 7 (MDA) is the only IBM EGA mode
 that uses 9-dot clocks, and the mode-3 clocking value is 01h: 8 dots,
 CRTC gets 4 of 5 memory cycles. The register is write-only on IBM EGA,
 so it cannot be read-modified. Writing 01h puts a clone that left 9-dot
 clocks back on 8 dots, and writes the value a real EGA BIOS just stored.
 The miscellaneous clock is left alone. EGA clock select is 14 or 16 MHz,
 not the VGA 25/28 MHz pair, and that register is write-only too.}
begin
  seqSyncReset;
  PortW[$3C4]:=$0101;
  seqRun;
end;

procedure stretchHorizontalTotal(ht:byte);
{The character clock is now 9/8 of what the BIOS programmed. VGA counts
 horizontal total as the register value plus 5. Stretch that count by
 9/8 so the line keeps its period. The 80 displayed columns stay put;
 the added clocks sit after the sync pulse, in the border before the
 next line.}
var
  total:word;
  vre:byte;
begin
  total:=(word(ht)+5)*9;
  total:=(total+4) div 8;
  if (total<word(ht)+5) or (total>260) then exit;
  {Bit 7 of vertical retrace end write-protects CRTC registers 0-7.}
  Port[$3D4]:=$11;
  vre:=Port[$3D5];
  Port[$3D5]:=vre and $7F;
  setCrtc(0,Lo(total-5));
  Port[$3D4]:=$11;
  Port[$3D5]:=vre;
end;

procedure force8DotVga;
{VGA mode 3 is 9-dot text at 28.322 MHz (80 x 9 = 720). Character 0xDE
 is a right half-block, four background dots and four foreground dots,
 and the ninth column is one dot wide. On an IBM VGA that column repeats
 the foreground for glyphs C0h-DFh, so the two 160x100 pixels are 4 and 5
 dots. On a Cirrus CL-GD510/520 it is a dark gap, the pinstripe in the
 color bars. 8-dot clocks make the halves equal (80 x 8 = 640), which is
 what the CGA path already programs.

 28.322/9 = 25.175/8, and the CRTC counts characters, not dots. Selecting
 the 25.175 MHz clock in the same reset keeps a 31.5 kHz line. That swap
 is only for the standard text line (clock select 01, horizontal total
 5Fh, 80 columns, dot clock not divided). Any other timing keeps the BIOS
 clock, and the horizontal total is stretched by 9/8 so the faster
 character clock does not raise the horizontal frequency.}
var
  clock,misc,ht,hde:byte;
  swapped:boolean;
begin
  Port[$3C4]:=1;
  clock:=Port[$3C5];
  if (clock and $01)<>0 then exit;
  misc:=Port[$3CC];
  Port[$3D4]:=0;
  ht:=Port[$3D5];
  Port[$3D4]:=1;
  hde:=Port[$3D5];
  swapped:=false;
  seqSyncReset;
  {Bit 0 selects 8 dots. Every other clocking-mode bit stays, including
   bit 3 (dot clock divided by 2) and bit 5 (screen off).}
  PortW[$3C4]:=(word((clock and $3F) or $01) shl 8) or $01;
  if ((misc and $0C)=$04) and ((clock and $08)=0)
     and (ht=$5F) and (hde=$4F) then begin
    Port[$3C2]:=misc and $F3;
    swapped:=true;
  end;
  seqRun;
  if not swapped then stretchHorizontalTotal(ht);
end;

procedure set160x100;
var
  which:byte;
  vga:boolean;
begin
  which:=resolvedAdapter;
  videoAdapter:=which;
  case which of
    2:begin
      forceEga200;
      vga:=vgaBiosPresent;
      asm
        mov     ax,$0003
        int     10h
      end;
      egaSwitchesAfter:=Mem[$0040:$0088];
      {A VGA BIOS can be told this machine is an EGA. Mode 3 on that
       BIOS is still the 9-dot text mode, so use the VGA sequence when
       the BIOS answers. An IBM EGA gets the write-only 01h rewrite.}
      if vga then force8DotVga else force8DotEga;
      {Jenner: the 200-line BIOS mode set already has 200 scanlines.
       R9=1 makes each row 2 scanlines, so 200/2 = 100 rows. The CGA
       register numbers are not the EGA CRTC map (R6 is vertical total
       there, not vertical displayed) and must not be written.}
      setCrtc($09,$01);
      blinkOffBIOS;
      setEga200Palette;
      cursorOff;
    end;
    3:begin
      asm
        mov     ax,$0003
        int     10h
      end;
      blinkOffBIOS;
      force8DotVga;
      {400-line VGA text: 100 rows of 4 scanlines. Vertical totals stay
       at the BIOS 400-line values; only the row height changes.}
      setCrtc($09,$03);
      cursorOff;
    end;
  else
    {CGA, and anything we could not identify.}
    asm
      mov     ax,$0003
      int     10h
    end;
    setCrtc($04,$7F);
    setCrtc($05,$06);
    setCrtc($06,$64);
    setCrtc($07,$70);
    setCrtc($09,$01);
    cursorOff;
    Port[$3D8]:=$09; {80-column text, blink off}
  end;
  fillTextDE;
end;

procedure xdc_releasevid;
begin
  if egaSwitchesSaved then begin
    Mem[$0040:$0088]:=egaSwitchesOrig;
    egaSwitchesSaved:=false;
  end;
end;

procedure xdc_donevid;
begin
  asm
    mov     ax,$0003
    int     10h
  end;
  xdc_releasevid;
end;

procedure xdc_setvid(b:byte);
{1=160x200x16, 2=640x200x2, 3=160x200x16 Tandy/PCjr, 4=240x128x2 HP 95LX,
 5=160x100x16 RGBI text tweak}
begin
  case b of
    1:asm
      mov ax,0006
      int 10h
      {turn on colorburst}
      mov dx,m6845_mode_ctl
      mov al,c_videosignal_enable+c_graphics_enable+c_640x200_enable
      out dx,al
    end;
    2:asm
      mov ax,0006
      int 10h
    end;
    3:asm
      mov ax,0008
      int 10h
    end;
{$IFDEF HP95LX}
    4:asm
      mov ax,0020h
      int 10h
    end;
{$ENDIF}
    5:set160x100;
  end;
end;

procedure fatalerr(s:string);
begin
  s:='FATAL ERROR: '+s;
  if logging then stderr(s);
  xdc_donevid;
  writeln(s);
  halt(1);
end;

end.
