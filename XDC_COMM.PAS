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
  if (sw and $0F)=$03 then Mem[$0040:$0088]:=sw-1
  else if (sw and $0F)=$09 then Mem[$0040:$0088]:=sw-1;
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

procedure set160x100;
var
  which:byte;
begin
  which:=resolvedAdapter;
  videoAdapter:=which;
  case which of
    2:begin
      forceEga200;
      asm
        mov     ax,$0003
        int     10h
      end;
      {Same 100x2 scanline CRTC setup as CGA. The BIOS mode set above
       has already selected 200-line / 15.7 kHz timings.}
      setCrtc($04,$7F);
      setCrtc($05,$06);
      setCrtc($06,$64);
      setCrtc($07,$70);
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
