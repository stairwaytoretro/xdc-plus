{$R-,S-,G-}
{Sound Blaster playback for XDP_PLAY.

This is the small unit XDP_PLAY used to get from the third-party soundlib:
detection, a double-sized DMA buffer, and a per-chunk IRQ that calls
play.callproc. The IRQ is the playback clock. 8-bit mono unsigned PCM.

DSP 2.00 and newer use auto-init DMA (command 48h then 1Ch). DSP 1.xx has
no auto-init, so each IRQ restarts a single-cycle transfer (command 14h).
SB Pro and SB16 are driven with those same 8-bit commands.

Command 1Ch is the non-high-speed path. Creative's high-speed command 90h
ignores further DSP commands until a reset, which is a poor fit for a clean
exit on an 8088, so it is not used. The time constant is therefore clamped
to the non-high-speed limit on DSP 2.xx and 3.xx.

All inline code is 8086. The unit does not use the CRT unit (CRT would take
over the timer).
}

unit xdc_sb;

interface

const
  {Bit values OR-ed together by XDP_PLAY. Playback is always unsigned
   8-bit mono; the flags are accepted so the call site stays the same.}
  snd_8bit = 1;
  snd_16bit = 2;
  snd_mono = 4;
  snd_stereo = 8;
  snd_nonsigned = 16;
  snd_signed = 32;

{$F+}
type
  TSBProc = procedure;
{$F-}

var
  play: record
    p: pointer;          {DMA buffer, paragraph aligned, offset 0}
    activeblock: byte;   {1 or 2; the half the callback should refill}
    callproc: TSBProc;   {far procedure invoked at the end of each chunk}
  end;

function initblaster: integer;
function getblasterstring: string;
function SBErrorText: string;
procedure setmemsize(size: word);
procedure initplay(mode: word; buf: pointer; size, rate, flags: word);
procedure exitplay;
{Port-level stop. Safe to call from a hardware interrupt: no DOS calls.}
procedure SBHardStop;
function SBIRQCount: longint;

implementation

uses
  dos;

const
  {Time-constant limits. rate = 1000000 / (256 - tc), integer division.
   DSP 1.xx single-cycle tops out at 22222 Hz (tc 211).
   DSP 2.xx/3.xx command 1Ch tops out at tc 210 (21739 Hz). DOSBox-X
   sbtype=sb2 enforces that same cap unless the high-speed command is used.
   DSP 4.xx honors 1Ch across the full 8-bit range, up to 45454 Hz (tc 234).
   The floor is 4000 Hz (tc 6) on every DSP this unit talks to.}
  tcMin = 6;
  tcMax1 = 211;
  tcMax2 = 210;
  tcMax4 = 234;

var
  basePort: word;
  irq: byte;
  dma: byte;
  dspMajor, dspMinor: byte;
  autoInit: boolean;
  useSlave: boolean;     {true: IRQ is on the secondary 8259}
  picIrq: byte;          {line we actually unmask, 2 remapped to 9 on an AT}
  irqVec: byte;
  blasterFromEnv: boolean;
  envBad: boolean;
  dspArmed: boolean;
  inService: byte;
  bufSize: word;
  halfSize: word;
  timeConst: byte;
  playRate: word;        {Hz actually programmed, after the clamp}
  rateClamped: boolean;
  cardText: string;
  sbError: string;
  irqCount: longint;
  oldIRQ: pointer;
  savedMaster, savedSlave: byte;
  raw1, raw2: pointer;
  dmaPage0, dmaPage1: byte;
  dmaOfs0, dmaOfs1: word;
  oldExit: pointer;

{$F+}
procedure NullProc;
begin
end;
{$F-}

function SBErrorText: string;
begin
  SBErrorText := sbError;
end;

function SBIRQCount: longint;
begin
  SBIRQCount := irqCount;
end;

function UpStr(s: string): string;
var
  i: integer;
begin
  for i := 1 to length(s) do s[i] := UpCase(s[i]);
  UpStr := s;
end;

function IntStr(n: word): string;
var
  s: string;
begin
  str(n, s);
  IntStr := s;
end;

function HexDigit(n: word): char;
begin
  n := n and $F;
  if n < 10 then HexDigit := chr(ord('0') + n)
  else HexDigit := chr(ord('A') + n - 10);
end;

function HexWord(w: word): string;
begin
  HexWord := HexDigit(w shr 12) + HexDigit(w shr 8) + HexDigit(w shr 4) + HexDigit(w);
end;

function HexPort(w: word): string;
var
  s: string;
begin
  s := HexWord(w);
  while (length(s) > 1) and (s[1] = '0') do s := copy(s, 2, 255);
  HexPort := s;
end;

function Linear(p: pointer): longint;
begin
  Linear := longint(Seg(p^)) * 16 + Ofs(p^);
end;

{Find a paragraph-aligned window of `size` bytes inside the size+16 block
 that does not cross a 64KB physical page. DMA cannot cross that page.}
function Place(p: pointer; size: word): pointer;
var
  lin, aligned, limit: longint;
begin
  Place := nil;
  lin := Linear(p);
  limit := lin + longint(size) + 16;
  aligned := (lin + 15) and $FFFFFFF0;
  if (aligned + size <= limit) and ((aligned and $FFFF) + size <= 65536) then
    Place := Ptr(word(aligned shr 4), 0)
  else begin
    aligned := (lin and $FFFF0000) + 65536;
    if (aligned + size <= limit) and ((aligned and $FFFF) + size <= 65536) then
      Place := Ptr(word(aligned shr 4), 0);
  end;
end;

function ParseNum(s: string; hex: boolean; var n: word): boolean;
var
  i, digit: integer;
  c: char;
  v: longint;
begin
  ParseNum := false;
  if s = '' then exit;
  if UpCase(s[length(s)]) = 'H' then begin
    hex := true;
    s := copy(s, 1, length(s) - 1);
    if s = '' then exit;
  end;
  v := 0;
  for i := 1 to length(s) do begin
    c := UpCase(s[i]);
    if (c >= '0') and (c <= '9') then digit := ord(c) - 48
    else if hex and (c >= 'A') and (c <= 'F') then digit := ord(c) - 55
    else exit;
    if hex then v := v * 16 + digit else v := v * 10 + digit;
    if v > 65535 then exit;
  end;
  n := word(v);
  ParseNum := true;
end;

procedure ParseBlaster;
var
  s, tok: string;
  i: integer;
  n: word;
  key: char;
begin
  basePort := $220;
  irq := 7;
  dma := 1;
  blasterFromEnv := false;
  envBad := false;
  s := UpStr(GetEnv('BLASTER'));
  if s = '' then exit;
  blasterFromEnv := true;
  i := 1;
  while i <= length(s) do begin
    while (i <= length(s)) and ((s[i] = ' ') or (s[i] = #9)) do inc(i);
    if i > length(s) then exit;
    tok := '';
    while (i <= length(s)) and (s[i] <> ' ') and (s[i] <> #9) do begin
      tok := tok + s[i];
      inc(i);
    end;
    key := tok[1];
    tok := copy(tok, 2, 255);
    if key = 'A' then begin
      if not ParseNum(tok, true, n) then envBad := true else basePort := n;
    end else if key = 'I' then begin
      if not ParseNum(tok, false, n) then envBad := true else irq := n;
    end else if key = 'D' then begin
      if not ParseNum(tok, false, n) then envBad := true else dma := n;
    end;
  end;
end;

function SettingsText: string;
begin
  SettingsText := 'A' + HexPort(basePort) + ' I' + IntStr(irq) + ' D' + IntStr(dma);
end;

function Fail(msg: string): integer;
begin
  sbError := msg + #13#10 +
    'Set BLASTER (for example SET BLASTER=A220 I7 D1) or use /NOSOUND.';
  Fail := 1;
end;

procedure HintTried(var s: string);
begin
  if blasterFromEnv then
    s := s + ' BLASTER was ' + SettingsText + '.'
  else
    s := s + ' BLASTER is not set; tried A220 I7 D1.';
end;

{Write one DSP command byte. Returns false if the DSP stays busy.}
function WriteDSP(b: byte): boolean;
var
  spins: word;
begin
  spins := 0;
  while (Port[basePort + $C] and $80) <> 0 do begin
    inc(spins);
    if spins = 8000 then begin
      WriteDSP := false;
      exit;
    end;
  end;
  Port[basePort + $C] := b;
  WriteDSP := true;
end;

function ReadDSP(var b: byte): boolean;
var
  spins: word;
begin
  spins := 0;
  while (Port[basePort + $E] and $80) = 0 do begin
    inc(spins);
    if spins = 20000 then begin
      ReadDSP := false;
      exit;
    end;
  end;
  b := Port[basePort + $A];
  ReadDSP := true;
end;

function ResetDSP: boolean;
var
  i: word;
  saw: byte;
begin
  ResetDSP := false;
  saw := 0;
  Port[basePort + 6] := 1;
  {Hold reset for well over 3 microseconds, including on a fast machine.}
  for i := 1 to 200 do saw := saw xor Port[basePort + 6];
  Port[basePort + 6] := 0;
  if saw = $FF then saw := 0;
  for i := 1 to 20000 do begin
    if (Port[basePort + $E] and $80) <> 0 then begin
      if Port[basePort + $A] = $AA then begin
        ResetDSP := true;
        exit;
      end;
    end;
  end;
end;

{An AT has a second 8259 at A0h/A1h. An XT does not; port A1h does not
 latch. IRQ 2 on an AT is the cascade, and a card jumpered for IRQ 2 is
 wired to IRQ 9.}
function SlavePICPresent: boolean;
var
  old, neu: byte;
begin
  asm
    pushf
    cli
  end;
  old := Port[$A1];
  Port[$A1] := $AA;
  neu := Port[$A1];
  Port[$A1] := old;
  asm
    popf
  end;
  SlavePICPresent := neu = $AA;
end;

procedure MapIRQ;
begin
  useSlave := false;
  picIrq := irq;
  if irq = 9 then useSlave := true
  else if irq = 2 then begin
    if SlavePICPresent then begin
      useSlave := true;
      picIrq := 9;
    end;
  end;
  if useSlave then irqVec := $70 + (picIrq - 8)
  else irqVec := 8 + picIrq;
end;

function IRQBit(line: byte): byte;
begin
  if line >= 8 then IRQBit := line - 8 else IRQBit := line;
end;

function ClearBit(value, bit: byte): byte;
begin
  ClearBit := value and ($FF xor (1 shl bit));
end;

procedure MaskOurIRQ;
var
  m: byte;
begin
  if useSlave then begin
    m := Port[$A1];
    m := m or (1 shl IRQBit(picIrq));
    Port[$A1] := m;
  end else begin
    m := Port[$21];
    m := m or (1 shl picIrq);
    Port[$21] := m;
  end;
end;

procedure UnmaskOurIRQ;
begin
  if useSlave then begin
    {IRQ 2 on the master must stay unmasked or the slave never gets through.}
    Port[$21] := ClearBit(Port[$21], 2);
    Port[$A1] := ClearBit(Port[$A1], IRQBit(picIrq));
  end else
    Port[$21] := ClearBit(Port[$21], picIrq);
end;

function PicInService: boolean;
var
  b: byte;
begin
  if useSlave then begin
    Port[$A0] := $0B; {read ISR}
    b := Port[$A0];
    Port[$A0] := $0A; {back to IRR, which is what the BIOS expects}
    PicInService := (b and (1 shl IRQBit(picIrq))) <> 0;
  end else begin
    Port[$20] := $0B;
    b := Port[$20];
    Port[$20] := $0A;
    PicInService := (b and (1 shl picIrq)) <> 0;
  end;
end;

procedure SendEOI;
begin
  if useSlave then begin
    Port[$A0] := $60 + IRQBit(picIrq);
    Port[$20] := $62; {specific EOI for the cascade line, IRQ 2}
  end else
    Port[$20] := $60 + picIrq;
end;

procedure PutVec(n: byte; p: pointer);
var
  slot: word;
begin
  slot := word(n) shl 2;
  MemW[0:slot] := Ofs(p^);
  MemW[0:slot + 2] := Seg(p^);
end;

{lo/hi on a promoted integer are not the low and high bytes on every compiler.}
function ByteLo(n: word): byte;
begin
  ByteLo := n and $FF;
end;

function ByteHi(n: word): byte;
begin
  ByteHi := n shr 8;
end;

function DmaPagePort(ch: byte): byte;
begin
  case ch of
    0: DmaPagePort := $87;
    1: DmaPagePort := $83;
    3: DmaPagePort := $82;
  else
    DmaPagePort := $83;
  end;
end;

function DmaAddrPort(ch: byte): byte;
begin
  case ch of
    0: DmaAddrPort := $00;
    1: DmaAddrPort := $02;
    3: DmaAddrPort := $06;
  else
    DmaAddrPort := $02;
  end;
end;

function DmaCountPort(ch: byte): byte;
begin
  case ch of
    0: DmaCountPort := $01;
    1: DmaCountPort := $03;
    3: DmaCountPort := $07;
  else
    DmaCountPort := $03;
  end;
end;

{Program one DMA transfer. `count` is the byte count, not count-1.
 Read mode (memory to DAC), address increment. Auto-init wraps.}
procedure ProgramDMA(page: byte; ofs: word; count: word; auto: boolean);
var
  mode: byte;
  addrPort, countPort: byte;
begin
  if auto then mode := $58 or dma else mode := $48 or dma;
  addrPort := DmaAddrPort(dma);
  countPort := DmaCountPort(dma);
  dec(count);
  asm
    pushf
    cli
  end;
  Port[$0A] := dma or $04;
  Port[$0C] := 0;
  Port[$0B] := mode;
  Port[$0C] := 0;
  Port[addrPort] := ByteLo(ofs);
  Port[addrPort] := ByteHi(ofs);
  Port[DmaPagePort(dma)] := page;
  Port[$0C] := 0;
  Port[countPort] := ByteLo(count);
  Port[countPort] := ByteHi(count);
  Port[$0A] := dma and $03;
  asm
    popf
  end;
end;

procedure StopDMA;
begin
  Port[$0A] := dma or $04;
end;

{Start the half that is about to be heard. activeblock names the half that
 just finished and that callproc will refill, so the other half is next.}
procedure KickSingleCycle;
begin
  if play.activeblock = 1 then ProgramDMA(dmaPage1, dmaOfs1, halfSize, false)
  else ProgramDMA(dmaPage0, dmaOfs0, halfSize, false);
  WriteDSP($14);
  WriteDSP(ByteLo(halfSize - 1));
  WriteDSP(ByteHi(halfSize - 1));
end;

procedure CacheHalves;
var
  lin: longint;
begin
  lin := Linear(play.p);
  dmaPage0 := byte((lin shr 16) and $FF);
  dmaOfs0 := word(lin and $FFFF);
  lin := lin + halfSize;
  dmaPage1 := byte((lin shr 16) and $FF);
  dmaOfs1 := word(lin and $FFFF);
end;

procedure SBHardStop;
var
  junk: byte;
begin
  if not dspArmed then exit;
  dspArmed := false;
  inService := 0;
  asm
    pushf
    cli
  end;
  MaskOurIRQ;
  {Drop a latched interrupt, then silence the codec.}
  junk := Port[basePort + $E];
  WriteDSP($D3); {speaker off}
  WriteDSP($D0); {halt DMA}
  if autoInit then WriteDSP($DA);
  WriteDSP($D0);
  StopDMA;
  {Reset is port I/O only. It releases a DSP that is still requesting.}
  Port[basePort + 6] := 1;
  junk := Port[basePort + 6];
  Port[basePort + 6] := 0;
  junk := Port[basePort + $E];
  if junk = 0 then junk := Port[basePort + $A];
  Port[$21] := savedMaster;
  if useSlave then Port[$A1] := savedSlave;
  PutVec(irqVec, oldIRQ);
  asm
    popf
  end;
end;

procedure exitplay;
begin
  SBHardStop;
end;

procedure SBIRQ; interrupt;
var
  junk: byte;
  served: boolean;
begin
  {DOSBox-X often enters this handler with the 8259 in-service bit already
   clear. Skipping the EOI in that case leaves the card looping a buffer
   and the frame clock never runs. Acknowledge every entry. The call still
   returns the PIC to IRR read mode.}
  served := PicInService;
  if served then junk := 0 else junk := 1;
  junk := Port[basePort + $E];
  if junk = $FF then junk := 0;
  SendEOI;
  inc(irqCount);
  if inService <> 0 then begin
    if not autoInit then KickSingleCycle;
    exit;
  end;
  inService := 1;
  if not autoInit then KickSingleCycle;
  asm
    sti
  end;
  play.callproc;
  asm
    cli
  end;
  inService := 0;
end;

function TcMax: byte;
begin
  if dspMajor <= 1 then TcMax := tcMax1
  else if dspMajor >= 4 then TcMax := tcMax4
  else TcMax := tcMax2;
end;

procedure ChooseRate(rate: word);
var
  divisor: word;
  limit: byte;
begin
  rateClamped := false;
  if rate < 4000 then begin
    rate := 4000;
    rateClamped := true;
  end;
  limit := TcMax;
  {Largest rate this DSP will actually clock: 1000000 div (256-limit).}
  divisor := 1000000 div longint(rate);
  if divisor > (256 - tcMin) then begin
    divisor := 256 - tcMin;
    rateClamped := true;
  end;
  if divisor < (256 - limit) then begin
    divisor := 256 - limit;
    rateClamped := true;
  end;
  if divisor = 0 then divisor := 1;
  timeConst := byte(256 - divisor);
  playRate := word(1000000 div longint(divisor));
end;

procedure BuildCardText;
var
  minor: string;
  irqName: string;
  modeName: string;
begin
  str(dspMinor, minor);
  if length(minor) < 2 then minor := '0' + minor;
  if useSlave and (irq = 2) then irqName := '2/9' else irqName := IntStr(irq);
  if autoInit then modeName := 'auto-init' else modeName := 'single-cycle';
  cardText := 'DSP ' + IntStr(dspMajor) + '.' + minor +
    ' at ' + HexPort(basePort) + 'h, IRQ ' + irqName +
    ', DMA ' + IntStr(dma) + ', ' + modeName;
end;

function getblasterstring: string;
var
  s: string;
begin
  s := cardText;
  if playRate <> 0 then begin
    s := s + ', ' + IntStr(playRate) + ' Hz';
    if rateClamped then s := s + ' (clamped)';
  end;
  getblasterstring := s;
end;

function initblaster: integer;
var
  why: string;
begin
  sbError := '';
  playRate := 0;
  irqCount := 0;
  ParseBlaster;
  if envBad then begin
    initblaster := Fail('BLASTER is not valid (' + GetEnv('BLASTER') + ').');
    exit;
  end;
  if (basePort < $200) or (basePort > $360) then begin
    initblaster := Fail('BLASTER port ' + HexPort(basePort) + 'h is out of range.');
    exit;
  end;
  if not (irq in [2, 3, 5, 7, 9]) then begin
    initblaster := Fail('BLASTER IRQ ' + IntStr(irq) +
      ' is not supported. Use 2, 3, 5, 7, or 9.');
    exit;
  end;
  if not (dma in [0, 1, 3]) then begin
    initblaster := Fail('BLASTER DMA ' + IntStr(dma) +
      ' is not supported. Use 0, 1, or 3.');
    exit;
  end;
  MapIRQ;
  if not ResetDSP then begin
    why := 'No Sound Blaster answered (DSP reset failed).';
    HintTried(why);
    initblaster := Fail(why);
    exit;
  end;
  if not WriteDSP($E1) then begin
    initblaster := Fail('DSP at ' + HexPort(basePort) + 'h did not take the version command.');
    exit;
  end;
  if not ReadDSP(dspMajor) or not ReadDSP(dspMinor) then begin
    initblaster := Fail('DSP at ' + HexPort(basePort) + 'h did not report a version.');
    exit;
  end;
  if dspMajor = 0 then begin
    initblaster := Fail('DSP at ' + HexPort(basePort) + 'h reported version 0.0.');
    exit;
  end;
  autoInit := dspMajor >= 2;
  BuildCardText;
  {Leave the card quiet until initplay.}
  WriteDSP($D3);
  initblaster := 0;
end;

procedure setmemsize(size: word);
var
  got: pointer;
begin
  if (play.p <> nil) and (bufSize = size) then exit;
  play.p := nil;
  bufSize := 0;
  if (size < 2) or (size > $8000) then exit;
  {size + 16 is computed as a longint. A word above 32767 must not pass
   through a signed 16-bit add.}
  if longint(size) + 16 > maxavail then exit;
  if longint(size) + 16 > 65535 then exit;
  getmem(raw1, word(longint(size) + 16));
  got := Place(raw1, size);
  if got = nil then begin
    if longint(size) + 16 > maxavail then exit;
    getmem(raw2, word(longint(size) + 16));
    got := Place(raw2, size);
  end;
  if got = nil then exit;
  play.p := got;
  bufSize := size;
  play.activeblock := 1;
end;

function StartDSP: boolean;
begin
  StartDSP := false;
  if not WriteDSP($D1) then exit; {speaker on; SB1/SB2 stay silent without this}
  if not WriteDSP($40) then exit;
  if not WriteDSP(timeConst) then exit;
  if autoInit then begin
    ProgramDMA(dmaPage0, dmaOfs0, bufSize, true);
    if not WriteDSP($48) then exit;
    if not WriteDSP(ByteLo(halfSize - 1)) then exit;
    if not WriteDSP(ByteHi(halfSize - 1)) then exit;
    if not WriteDSP($1C) then exit;
  end else begin
    ProgramDMA(dmaPage0, dmaOfs0, halfSize, false);
    if not WriteDSP($14) then exit;
    if not WriteDSP(ByteLo(halfSize - 1)) then exit;
    if not WriteDSP(ByteHi(halfSize - 1)) then exit;
  end;
  StartDSP := true;
end;

procedure initplay(mode: word; buf: pointer; size, rate, flags: word);
begin
  if mode <> 0 then begin
    sbError := 'Only Sound Blaster playback mode 0 is supported. Use /NOSOUND.';
    exit;
  end;
  {Signed, stereo, or 16-bit would not match the XDV chunks.}
  if (flags and (snd_16bit or snd_stereo or snd_signed)) <> 0 then begin
    sbError := 'This player only sends 8-bit mono unsigned PCM. Use /NOSOUND.';
    exit;
  end;
  if dspArmed then SBHardStop;
  if buf <> nil then play.p := buf;
  if (play.p = nil) or (size < 2) or (rate < 1000) then begin
    sbError := 'Sound buffer or sample rate is unusable. Use /NOSOUND.';
    exit;
  end;
  bufSize := size;
  halfSize := size div 2;
  if halfSize = 0 then begin
    sbError := 'Audio chunk is empty. Use /NOSOUND.';
    exit;
  end;
  ChooseRate(rate);
  CacheHalves;
  fillchar(play.p^, bufSize, 127);
  play.activeblock := 1;
  GetIntVec(irqVec, oldIRQ);
  savedMaster := Port[$21];
  if useSlave then savedSlave := Port[$A1];
  inService := 0;
  irqCount := 0;
  SetIntVec(irqVec, @SBIRQ);
  dspArmed := true;
  asm
    pushf
    cli
  end;
  UnmaskOurIRQ;
  if not StartDSP then begin
    asm
      popf
    end;
    SBHardStop;
    sbError := 'DSP at ' + HexPort(basePort) + 'h rejected the playback command. Use /NOSOUND.';
    exit;
  end;
  asm
    popf
  end;
  BuildCardText;
end;

{$F+}
procedure UnitExit;
begin
  ExitProc := oldExit;
  exitplay;
end;
{$F-}

begin
  play.p := nil;
  play.activeblock := 1;
  play.callproc := NullProc;
  dspArmed := false;
  inService := 0;
  bufSize := 0;
  playRate := 0;
  irqCount := 0;
  sbError := '';
  cardText := 'Sound Blaster';
  raw1 := nil;
  raw2 := nil;
  autoInit := false;
  useSlave := false;
  oldExit := ExitProc;
  ExitProc := @UnitExit;
end.
