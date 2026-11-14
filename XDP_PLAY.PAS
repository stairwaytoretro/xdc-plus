{$M 2048,0,655360}
{$G-,F-,S-,R-}

{{$DEFINE DEBUG}

{{$DEFINE HP95LX} {Undefine to add support for an HP95LX}

{Audio is played on a Sound Blaster and the DMA IRQ paces each frame.
 /NOSOUND (or /q) keeps the PIT-paced silent path. If no card answers,
 the player prints the reason and tells you to use /NOSOUND.}

{todo:
-- add left/right skip by +/- 5 secs, 1 minute, 5 minutes
  - flash screen to register keypress? or just key click?
  also add spacebar for pause/play
}


{$IFDEF DEBUG}
{$S+,R+}
{$ENDIF}

Program xdp_play;

uses
  xdc_globals,
  xdc_common,
  ringbufu,
  objects,     {file stream support}
  support,     {basic support stuff I don't want to include CRT for}
  cmdlin,      {for parsing command-line options}
  tinterrupts, {8253 manipulation routines}
  dos,         {for getintvec/setintvec}
  xdc_sb       {Sound Blaster detection, DMA playback, teardown}
  ;

const
  {One version string, printed by writeProjectBanner on the startup
   credits and again on the end-of-playback stats. Bump it when a
   merged change alters the player. A local test build may add a
   suffix such as v0.1.0-test1; that build is not a release.}
  playerVersion='v0.1.0';

  {samplerate:word=22050;}
  maxsamplerate=45454;   {this is the maximum the Soundblaster Pro/2.0 can do}
  intfps:byte=24;
  realFPS:real=23.976;
  maxintfps=120;         {CGA CRT maxes out at 60Hz (slightly less, actually)}
  maxsndChunkSize=$4000; {a reasonable maximum to ensure we don't cross DMA
                         boundary}
  sndbufsize:word=0;     {size of actual sound buffer (2 chunks)}
  maxsndBufSize=maxsndChunkSize * 2;

  DataQueued:boolean=false; {If FALSE, then playback pauses while more
                            data is buffered from disk}
  numPauses:word=0;
  quiet:boolean=false;
  presenting:boolean=false;
  showpip:boolean=false;
  curPlayPacket:word=0;
  packetsLeft:word=0;
  minDiskRead:word=32;      {minimum disk I/O to perform, in KB}

  {to calculate CPU "utilization" of the player (actually the inverse of idle)}
  cpuUsageTicks:longint=0;
  cpuUsageCounter:longint=0;
  cpuUsageCounterIdle:longint=0;
  IOUsageTicks:longint=0;

  Int1CSave:pointer=nil;

var
  f:tDosStream;
  header:XDVHeader;
  playp:pointer;
  AVRing:TSlabRing;
  fname:string;
  timerOn:boolean;
  videoOn:boolean;
  int1COn:boolean;
  breakHooked:boolean;
  userBreak:boolean;
  old1B,old23:pointer;
  savedExit:pointer;

procedure userTickHandler; interrupt;
begin
  inc(cpuUsageTicks);
end;

{$IFDEF HP95LX}
procedure userTickHandler95LX; interrupt;
begin
  inc(cpuUsageTicks);
  play.callproc;
end;
{$ENDIF}

Procedure PrintHelp;
begin
  asm
        push    ds
        jmp     @start
@message:
        db 'Usage:  xdp_play <switches> [filename] <switches>',0dh,0ah
        db '  <filename> is the video to play',0dh,0ah
        db '  /? or /h   This help',0dh,0ah
        db '  /NOSOUND   Pace frames from the PIT, no audio',0dh,0ah
        db '  /q         Same as /NOSOUND',0dh,0ah
        db '  /ADAPTER=xxx  Video card in this computer: AUTO, CGA, EGA, VGA.',0dh,0ah
        db '             AUTO is the default (same as omitting the option).',0dh,0ah
        db '             This selects the card, not the picture format.',0dh,0ah
        db '             The format comes from the .XDV header vidmode.',0dh,0ah
        db '             vidmode 6 (320x200x16) needs EGA or VGA.',0dh,0ah
        db '  /wNAME     After playback, write the screen buffer to NAME.',0dh,0ah
        db '  /kN        How much KB to read in a single operation',0dh,0ah
        db '  /p         Presentation mode (no messages, stay in graphics mode)',0dh,0ah
        db '  /d         Displays queue depth indicator',0dh,0ah
        db '$'
@start:
        mov     ax,0900h
        lea     dx,@message
        mov     bx,cs
        mov     ds,bx
        int     21h
        pop     ds
  end;
  halt(255);
end;

function noSoundSwitch:boolean;
var
  i:integer;
  s:string;
begin
  noSoundSwitch:=is_param('q');
  for i:=1 to paramcount do begin
    s:=upstring(paramstr(i));
    if (s='/NOSOUND') or (s='-NOSOUND') then noSoundSwitch:=true;
  end;
end;

procedure PutVec(n:byte; p:pointer);
var
  slot:word;
begin
  slot:=word(n) shl 2;
  MemW[0:slot]:=Ofs(p^);
  MemW[0:slot+2]:=Seg(p^);
end;

procedure SilenceTimerDirect;
var
  p:pointer;
begin
  if not timerOn then exit;
  {Same channel-0 reload CleanUpTimer uses: mode 2, divisor 0 (18.2 Hz).}
  Port[$43]:=$34;
  Port[$40]:=0;
  Port[$40]:=0;
  move(BIOSTimerHandler,p,4);
  PutVec(8,p);
  timerOn:=false;
end;

procedure StopDevices;
begin
  {Both stops are idempotent. quiet is false until the command line is read,
   and SBHardStop does nothing until playback has been armed.}
  if not quiet then SBHardStop;
  if timerOn then SilenceTimerDirect;
end;

procedure CallFar(p:pointer);
begin
  asm
    pushf
    call dword ptr p
  end;
end;

procedure Break1B; interrupt;
begin
  StopDevices;
  userBreak:=true;
  if old1B<>nil then CallFar(old1B);
end;

procedure Break23; interrupt;
begin
  StopDevices;
  userBreak:=true;
  if videoOn then begin
    xdc_donevid;
    videoOn:=false;
  end;
  if int1COn then begin
    SetIntVec($1C,Int1CSave);
    int1COn:=false;
  end;
  if breakHooked then begin
    SetIntVec($1B,old1B);
    SetIntVec($23,old23);
    breakHooked:=false;
  end;
  halt(1);
end;

procedure HookBreak;
begin
  if breakHooked then exit;
  GetIntVec($1B,old1B);
  GetIntVec($23,old23);
  SetIntVec($1B,@Break1B);
  SetIntVec($23,@Break23);
  breakHooked:=true;
end;

procedure UnhookBreak;
begin
  if not breakHooked then exit;
  SetIntVec($1B,old1B);
  SetIntVec($23,old23);
  breakHooked:=false;
end;

{$F+}
procedure PlayerExit;
begin
  ExitProc:=savedExit;
  StopDevices;
  if int1COn then begin
    SetIntVec($1C,Int1CSave);
    int1COn:=false;
  end;
  UnhookBreak;
  if videoOn then begin
    xdc_donevid;
    videoOn:=false;
  end;
end;
{$F-}

procedure readAdapterFlag;
{ /ADAPTER= names the video card in this computer. It does not select
  the picture format; that comes from the .XDV header vidmode.
  AUTO is the default and means autodetect. }
var
  i:integer;
  s,val:string;
begin
  for i:=1 to paramcount do begin
    s:=upstring(paramstr(i));
    if (s='/CGA') or (s='-CGA') or (s='/EGA') or (s='-EGA')
       or (s='/VGA') or (s='-VGA') then begin
      writeln('Unknown switch: ',paramstr(i));
      writeln('Use /ADAPTER=AUTO, /ADAPTER=CGA, /ADAPTER=EGA, or /ADAPTER=VGA.');
      flush(Output);
      printHelp;
    end;
    if (copy(s,1,9)='/ADAPTER=') or (copy(s,1,9)='-ADAPTER=') then begin
      val:=copy(s,10,255);
      if val='AUTO' then videoAdapter:=0
      else if val='CGA' then videoAdapter:=1
      else if val='EGA' then videoAdapter:=2
      else if val='VGA' then videoAdapter:=3
      else begin
        writeln('Unknown video adapter: ',paramstr(i));
        writeln('Use /ADAPTER=AUTO, /ADAPTER=CGA, /ADAPTER=EGA, or /ADAPTER=VGA.');
        writeln('This names the video card in the computer, not the picture format.');
        flush(Output);
        printHelp;
      end;
    end;
  end;
end;

procedure writeProjectBanner;
begin
  writeln('XDC-Plus player ',playerVersion);
  writeln('Based on XDC by Trixter / Hornet');
  writeln('Extended by StairwayToRetro, with help from Grok Bot');
end;

Procedure prepPlayer;
var
  l:longint;
begin
  {handle user input}
  if (paramcount=0) or is_Param('h') or is_Param('?') then printHelp;
  {Reject a bad adapter before any mode set or disk read.}
  readAdapterFlag;
  if is_param('p') then presenting:=true;
  if is_param('d') then showpip:=true;
  if noSoundSwitch then quiet:=true;
  if quiet and (not presenting) then
    writeln('Silent playback: frames are paced by the PIT at the source frame rate.');
  if is_param('k') then minDiskRead:=param_int('k');
  if non_flag_count>0 then fname:=non_flag_param(1);
  if not fileexists(fname) then fatalerror(1,'Filename "'+fname+'" not found');

  f.init(fname,stOpenRead);
  if f.status<>stOK then fatalerror(2,'Problem opening media file: '+fname);
  {read header}
  f.read(header,sizeof(header));
  if header.signature[0]<>'X' {header should start with XDCV}
    then fatalerror(127,'Header signature doesn''t indicate XDCV file...');
  if header.vidmode=6 then
    if resolvedAdapter<2 then begin
      writeln('Screen mode 6 is 320x200x16 EGA (BIOS mode 0Dh).');
      writeln('It needs an EGA or VGA card. /ADAPTER=CGA was given, or this');
      writeln('computer has no EGA/VGA. Playback was not started.');
      flush(Output);
      halt(1);
    end;
  {load packet index}
  getmem(packetindex,header.numpackets);
  f.seek(f.getsize-header.numpackets);
  f.read(packetindex^,header.numpackets);
  {seek back to location of first packet}
  f.seek(sizeof(header));
  if (header.achunksize=0) or (header.achunksize>maxsndChunkSize) then
    fatalerror(5,'Audio chunk size is zero or larger than 16KB');
  if header.samplerate<1000 then
    fatalerror(5,'Audio sample rate is unusable');
  sndbufsize:=header.achunksize*2; {because buffer is actually divided into two IRQ firings}
  realfps:=header.samplerate / header.achunksize;
  intfps:=round(realFPS);
  if intfps<4 then intfps:=4; if intfps>maxintfps then intfps:=maxintfps;

  {startup screen, before idle calibration and the playback stats}
  if not presenting then writeProjectBanner;

  {setup and determine cpu idle counter rate}
  GetIntVec($1C,Int1CSave);
  SetIntVec($1C,@userTickHandler);
  int1COn:=true;
  {see how high counter goes for 1 tick when idle}
  if not presenting then writeln('Calibrating CPU idle counter... ');
  l:=cpuUsageTicks;
  repeat
    asm
        hlt
    end
  until l<>cpuUsageTicks; {wait until beginning of tick}
  l:=cpuUsageTicks;
  repeat
    inc(cpuUsageCounterIdle);
  until cpuUsageTicks >= l+8;
  cpuUsageCounterIdle:=cpuUsageCounterIdle div 8;

  {The ring then owns the rest of the heap, so the DMA buffer has to exist first.}
  if not quiet then begin
    setmemsize(sndbufsize);
    if play.p=nil then begin
      writeln('Not enough conventional memory for the DMA buffer.');
      writeln('Use /NOSOUND to play with the timer and no audio.');
      halt(4);
    end;
  end;
  AVRing.init(heapPtr,heapEnd); {from now on, we can't use getmem/new/malloc}
  packetsLeft:=header.numPackets;
  with header do begin
    l:=largestPacket div 1024;
    if minDiskRead>64-l then minDiskRead:=64-l;
    if minDiskRead<l then minDiskRead:=l;
  end;
  if not presenting then begin
    writeln('Video FPS:    ',realFPS:2:2);
    writeln('Video length: ',header.numpackets,' frames (',(header.numpackets/realfps)/60:2:2,' minutes)');
    writeln('Audio rate:   ',header.samplerate,' Hz');
    writeln('Using ',AVRing.slabsize div 1024,'KB of RAM for buffering');
    {more arith. checking buggery workarounds, argh}
    l:=header.largestpacket;
    l:=l * intfps;
    l:=l div 1024;
    writeln('This video could demand as much as ',l,' KB/s from your I/O subsystem.');
    writeln('Will read from disk in ',minDiskRead,'KB chunks.');
    writeln('Press key to begin playing.');
    readkeychar;
  end;
end;

procedure soundIntCallerCGA; far;
{
This is where the magic happens.  If we are executing in this code, it means
the sound card just got *finished* playing a buffer, which is our cue to
prepare the next frame.

No check for re-entrancy is performed in this particular snippet because
the parent code in the soundblaster and interrupt routines do that for us.
(In case it wasn't obvious, this is NOT an interrupt handler procedure!)
}

var
  sndBufp:pointer;    {temp pointer to where we should copy our new audio data}
  frameHp:pointer;    {temp pointer video data comes from}
  audioHp:pointer;    {pointer to audio}

begin
  if not quiet then begin
    sndbufp:=play.p; {point to dma buffer}
    if play.activeblock = 2 {If in one half, advance to the second half}
      then inc(word(sndbufp),header.achunksize);
  end;
{$IFNDEF HP95LX}
  {if requested, display a blinking pip onscreen showing queue depth}
  if showpip then asm
        mov     ax,$b800
        mov     es,ax
        mov     di,AVRing.numElements
        mov     cl,3
        shr     di,cl
        mov     ax,di
        or      ax,1000000000000001b
        stosw
  end;
{$ENDIF}
  if AVRing.isEmpty then begin
    if dataQueued then inc(numPauses);
    dataQueued:=false;
  end;
  if DataQueued then begin
    {get a handle to the packet}
    frameHp:=AVRing.retrieve;
    {get a handle to the audio data inside the packet}
    if not quiet then begin
      audioHp:=frameHp;
      inc(word(audioHp),(packetIndex^[curPlayPacket]*512)-header.achunksize);
      asm
        mov     dx,ds
        les     di,sndbufp
        cld
        mov     cx,header.achunksize
        lds     si,audioHp {don't need vars from DS any more so this is fine}
        rep     movsb
        mov     ds,dx
      end;
    end;
    {execute code in video portion of packet.  Normalized pointers allow:}
    asm
        xor     cx,cx           {Compiler output does not clear CH, so we must}
        call    framehp
        inc     curPlayPacket
    end;
  {if we are NOT allowed to pull AV from the FIFO queue:}
  end else if not quiet then begin
    asm
        les     di,sndbufp
        cld
        mov     cx,header.achunksize
        mov     al,$7f   {fill buffer with silence if we have nothing to put in it}
        rep     stosb
    end;
  end;
  {toggle sound double-buffer blocks}
  asm
        xor     play.activeblock,00000011b {toggles between 1 and 2}
  end;
end;

procedure enqueuefile;
const
  minElements:byte=3; {holdover from 8088flex where each packet was 2K=audiochunk}
  curPacket:word=0;
var
  oldticks:longint;
  numBytes,w,numPackets,commitSize:word;
  p:pointer;
begin
  {ensure we always have half a second's worth of data queued}
  {minElements:=intfps div 2;}
  minElements:=2;
  minDiskRead:=minDiskRead*1024; {convert KB to bytes outside of inner loop}
  {clear fat-finger typing so player doesn't immediately exit}
  if keypressed then repeat readkeychar until not keypressed;
  {must be atomic; 32-bit integer, 2 instructions to zero it, so we wrap it}
  asm
        pushf
        cli
  end;
  cpuUsageTicks:=0;
  asm
        popf
  end;
  cpuUsageCounter:=0;
  with AVRing do begin
    repeat
      if not isFull then begin {if we have space for video+audio data and some extra for handle}
        {determine how many packets to read in this access}
        numBytes:=0;
        numPackets:=0;
        while (packetsLeft>0) and (numBytes<minDiskRead) do begin
          inc(numBytes,(packetIndex^[curPacket+numPackets] * 512));
          inc(numPackets);
          dec(packetsLeft);
        end;
        {reserve an area in the ring buffer}
        p:=reserve(numBytes);
        {if reserve failed, then isFull is true}
        if (p=NIL) or (isFull) then begin
          {unravel what we did above}
          inc(packetsLeft,numPackets);
          {start loop over!}
          continue;
        end;
        {if we got here, we have an area of the slab to write data to}
        {read multiple packets into that area}
        oldticks:=cpuUsageTicks;
        f.read(p^,numBytes);
        inc(IOUsageTicks,cpuUsageTicks-oldticks);
        if f.status<>stOK then fatalerror(2,'disk error');
        {commit multiple packet locations into reserved area}
        for w:=0 to numPackets-1 do begin
          commitSize:=packetIndex^[curPacket]*512;
          if not commit(p,commitSize) then fatalerror(3,'commit failed');
          inc(word(p),commitSize);
          inc(curPacket);
        end;
        (*  The logic here was moved to the interrupt handler
        {If we have such a slow harddisk that we consumed all our data,
        leaving the ring buffer empty, PAUSE PLAYBACK to stop consuming}
        if (numElements < minElements) or isEmpty then begin
          if dataQueued then inc(numPauses);
          dataQueued:=false; {this must be atomic or else playback
          interrupt might try to play non-existent data.  Luckily, it
          compiles to a single instruction.}
        end;
        *)
      end else begin
        DataQueued:=true; {ring buffer is full, we're ready to play}
      end;
      inc(cpuUsageCounter); {record idle time}
      if keypressed then exit;
    {until we reach end of video stream (or file, if something went wrong)}
    until (packetsLeft=0) or (f.status<>stOK);
  end;
  f.done;
  {If entire file fit in RAM, play it. Don't leave here without playback enabled!}
  DataQueued:=true;
end;

Procedure primeSoundcard;
begin
  if initblaster <> 0 then begin
    if int1COn then begin
      SetIntVec($01C,Int1CSave);
      int1COn:=false;
    end;
    writeln(SBErrorText);
    halt(4);
  end;
  setmemsize(sndbufsize);
  if play.p=nil then begin
    writeln('Not enough conventional memory for the DMA buffer.');
    writeln('Use /NOSOUND to play with the timer and no audio.');
    halt(4);
  end;
  playp:=play.p;
  fillchar(playp^,sndbufsize,127); {init buffer with silence}
  play.callproc:=soundIntCallerCGA;
  initplay(0,play.p,sndbufsize,header.samplerate,snd_8bit+snd_mono+snd_nonsigned);
  if SBErrorText<>'' then begin
    SBHardStop;
    if int1COn then begin
      SetIntVec($01C,Int1CSave);
      int1COn:=false;
    end;
    writeln(SBErrorText);
    halt(4);
  end;
  if not presenting then writeln(getblasterstring,' initialized.');
end;

{$F+}
procedure noSoundIntCaller; Interrupt;

begin
  play.callproc;

  {We want to be nice, and will maintain the BIOS interrupt}
  inc(PITCycles,Chan0Counter); {Keep track of how many PIT cycles have gone by}
  if longrec(PITCycles).hi <> 0 then begin {Did we roll over?  Is it time to call the 18.2Hz BIOS handler?}
    longrec(PITCycles).hi:=0; {Update our PIT cycles counter}
    asm pushf end; {simulate an interrupt by pushing flags, then CALLing handler}
    BIOSTimerHandler; {this will acknowledge the interrupt}
  end
  else
    Port[$20] := $20; {send EndOfInterrupt to the PIC to ackn. the interrupt}
end;
{$F-}

procedure primeNoCard; {Instead of sound blaster, we will use the system timer}
begin
  play.callproc := soundIntCallerCGA;
  SetTimerExact(@noSoundIntCaller,trunc(PITFreq/realfps)); {set to fire at video's framerate}
  timerOn:=true;
end;

{$IFDEF HP95LX}
procedure primeNoCard95LX;
begin
  play.callproc := soundIntCallerCGA;
  SetIntVec($1C,@userTickHandler95LX);
end;
{$ENDIF}

Procedure shutItDown;
var
  i:byte;
begin
  StopDevices;
  if int1COn then begin
    SetIntVec($01C,Int1CSave); {stop counting ticks}
    int1COn:=false;
  end;
  UnhookBreak;

  if not presenting then begin
    if videoOn then begin
      xdc_donevid;
      videoOn:=false;
    end;
    writeProjectBanner;
    writeln('Playback statistics:');
    writeln('# of pauses during playback: ',numPauses);
    writeln('CPU was ',(100*(cpuUsageCounter div cpuUsageTicks)) div cpuUsageCounterIdle,'% idle');
    writeln((100*IOUsageTicks) div cpuUsageTicks,'% of total playback time was spent reading from disk');
    writeln('# of elements still in the ring: ',AVRing.numElements);
    writeln('Frames played: ',curPlayPacket);
    if not quiet then writeln('Sound Blaster IRQs: ',SBIRQCount);
  end else begin
    xdc_releasevid;
    videoOn:=false;
  end;
  AVRing.done;
  freemem(packetindex,header.numpackets);
  {A set Ctrl-Break flag makes COMMAND.COM abort the rest of a batch file
   when this program returns, so the machine looks dead.}
  Mem[$0040:$0071]:=Mem[$0040:$0071] and $7F;
  if keypressed then begin
    i:=0;
    repeat
      readkeychar;
      inc(i);
    until (not keypressed) or (i=16);
  end;
end;

procedure writeB800(s:string);
type
  TPlane=array[0..7999] of byte;
  TVid=array[0..15999] of byte;
var
  outf:file;
  note:text;
  plane:byte;
  planeP:^TPlane;
  vid:^TVid;
begin
  assign(outf,s);
  rewrite(outf,1);
  if header.vidmode=6 then begin
    {32000 bytes: plane 0, then 1, then 2, then 3. 40 bytes per line.}
    planeP:=Ptr($A000,0);
    for plane:=0 to 3 do begin
      PortW[$3CE]:=(word(plane) shl 8) or 4;
      blockwrite(outf,planeP^,egaPlaneBytes);
    end;
  end else begin
    vid:=Ptr($B800,0);
    blockwrite(outf,vid^,16000);
  end;
  close(outf);
  assign(note,'NOTE.TXT');
  rewrite(note);
  writeln(note,'adapter=',videoAdapter);
  writeln(note,'switches=',Mem[$0040:$0088]);
  if header.vidmode=6 then writeln(note,'vidmode=6');
  if egaSwitchesSaved then begin
    writeln(note,'switches_orig=',egaSwitchesOrig);
    writeln(note,'switches_forced=',egaSwitchesForced);
    writeln(note,'switches_after=',egaSwitchesAfter);
  end;
  close(note);
end;

procedure holdPicture;
{Wall-clock length depends on the PIT rate. The lab runs this near
 realtime so a screenshot can be taken while the tweaked mode is up.}
var
  start:longint;
begin
  start:=cpuUsageTicks;
  repeat until cpuUsageTicks>start+90; {about five seconds at 18.2 Hz}
end;

begin
  timerOn:=false;
  videoOn:=false;
  int1COn:=false;
  breakHooked:=false;
  userBreak:=false;
  savedExit:=ExitProc;
  ExitProc:=@PlayerExit;
  HookBreak;
  prepPlayer;
  if userBreak then halt(1);
  if quiet
{$IFDEF HP95LX}
    then primeNoCard95LX
{$ELSE}
    then primeNoCard
{$ENDIF}
    else primeSoundcard;
  xdc_setvid(header.vidmode);
  videoOn:=true;
  {if not presenting then writeln('Performing initial buffering...');}
  EnqueueFile;
  repeat
    {do nothing, because if we're here, we've loaded everything into RAM
    and are just waiting for everything to be played}
    inc(cpuUsageCounter); {record idle time}
  until AVRing.isempty or (not dataqueued) or userBreak;
  {Drop the BIOS Ctrl-Break flag so the statistics writeln is not aborted.}
  if userBreak then Mem[$0040:$0071]:=Mem[$0040:$0071] and $7F;
  if is_param('w') and (not userBreak) then begin
    writeB800(param_text('w'));
    holdPicture;
  end;
  shutItDown;
end.
