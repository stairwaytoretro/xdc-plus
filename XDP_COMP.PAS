program xdp_comp;
{$I+}

{
"xdc" (x86 differential compiler) animation compiler for 8088+CGA systems.
The basic operation of the animation system is to determine differences
between frames and turn those differences into x86 code that can be directly
executed to update the visible screen buffer.  By staying within available
bandwidth, we can stress the system no more than we do with the earlier
8088flex system, which has known performance characteristics on real 8088+CGA
hardware.

The major bandwidth constraint is time it takes to update the screen, which we
will initially cap at the same time a 2000-byte REP MOVSW takes to execute.
Secondary bandwidth constraint is the size of the compiled code, which must
not exceed whatever limits the user requests.

Some useful terminology that will help you understand this source code:

- Delta: An area in a new frame that is different than the same area in the
old/previous frame.  This area will need to be updated in the visible screen
buffer.  Areas are defined as a screen buffer starting and ending offset.  (A
Delta can be though of as a "strip" of new frame data 1 pixel high and 1..N
bytes long.)

- Slice: A Delta that contains at least two different byte values.

- Run: A Delta consisting of only one value.  A run can be encoded using
an optimized x86 form (REP STOSW) that is faster and takes up less space than
REP MOVSW.

- Delta List: (abbreviated as List) A data structure that helps us manipulate
and optimize all found deltas.  This can be implemented any number of ways
(trie, linked list, etc.) but I choose to implement as a TSortedCollection
(sorted array of object pointers) for speed and simplicity.

- Code bytes: CS:IP x86 opcodes that execute directly to update the screen.

- Data bytes: DS:SI data that is copied to the screen by code bytes.

Some design decisions that will help you understand this code:

- All deltas are stored in a data structure that is always maintained sorted
from "largest onscreen change of bytes" to the smallest.  In other words,
the first entries in the list of deltas are always the ones that change the
most amount of pixels on the screen, and then entries at the end of the list
change the fewest.  This automatic, enforced sorting helps to simplify some
decision-making logic when optimizing and encoding deltas to x86 code.  (This
will help you understand why some processing occurs in specific directions
up or down the list.)

- Source was kept 16-bit real-mode DOS compatible so that the option of
compiling an animation directly on the target hardware, using measurements
taken directly from the hardware, was kept open as a future option.  This
would allow proper encoding/timing on non-8088 non-CGA architectures, such as
286+VGA.  (The compiler currently only counts cycles for an 8088+CGA target.)
My sincere apologies for this -- someday I or someone else will convert it
to a modern 64-bit environment...

- 16-bit DOS architecture uses segmented pointers.  This code enforces and
relies on normalized pointers (where offset is 0) to reduce required logic
and increase processing speed.

- ALL optimizations are for size.  The only case where this has a guaranteed
speed benefit is in run handling, as runs are replayed with REP MOVS.

To deal with varying input types, the compiler and muxer are controlled via an
input script with the following syntax:

# any line beginning with a hash is a comment
  so are lines that begin with one or more spaces, or are blank
  Comments MUST be on lines by themselves
sourcefps=xx.xx          input playback rate
encodefps=xx.xx          forced playback rate; meant for creating 60fps output
waveinput=filename.wav   location of 8-bit PCM audio data

                         !IMPORTANT! If an audio file is supplied, it means
                         we are not encoding to individual files, but creating
                         a full video+audio muxed file.  The output filename
                         will be the same as the input script + '.xdv'

debug=x                  debug level in log.  0=none; 1-3 increases verbosity
screenmode=xxx           Screen mode of next frame.  1=160x200x16, 2=640x200,
                         3=Tandy 160x200x16, 5 or 160x100=160x100x16 RGBI,
                         6 or 320x200=EGA 320x200x16 planar (BIOS 0Dh).
                         (for the next three, a value of "on" will turn the
                         feature on without changing the value, and a
                         numeric value will set the feature's value.)
shavepixels=xxx          enables/disables pixel shaving
shavedeltas=xxx          enables/disables delta shaving
combinedeltas=xxx        enables/disables delta combination (slow!)

...anything else (like filename.ext) will be interpreted as a frame to load.

The above is not a complete description of the script directives; consult
the official documentation at x86dc.wordpress.com for the full list.

}

uses
  support,objects,memory,dos,
  xdc_globals,xdc_log,xdc_common,xdc_deltas,xdc_codegeneration,
  rteh; {more descriptive runtime error messages}

const
  drift:real=1.0;

  frameIntegrity:byte=75;
  muxing:boolean=false; {if muxing, we're creating a full video+audio file}
  padAlign=secSize; {align payloads to sector sizes}

  totalDumpedBytes:longint=0;
  totalDumpedDeltas:longint=0;
  totalEncodedBytes:longint=0;
  maxEncodedBytes:longint=0;
  numEncodedFrames:longint=0;
  numEncodedRuns:longint=0;
  numEncodedSlices:longint=0;
  numUniqueFrames:longint=0;
  leastCyclesRemaining:longint=$FFFFFFF;

  maxEncBufSize=10*1024;

  {Default EGA palette in mode 0Dh, which is the CGA RGBI set
   (colour 6 is brown). BMP colours are mapped to the nearest entry.}
  egaR:array[0..15] of byte=(
    $00,$00,$00,$00,$AA,$AA,$AA,$AA,$55,$55,$55,$55,$FF,$FF,$FF,$FF);
  egaG:array[0..15] of byte=(
    $00,$00,$AA,$AA,$00,$00,$55,$AA,$55,$55,$FF,$FF,$55,$55,$FF,$FF);
  egaB:array[0..15] of byte=(
    $00,$AA,$00,$AA,$00,$AA,$00,$AA,$55,$FF,$55,$FF,$55,$FF,$55,$FF);

var
  deltas:PDeltas;
  frameAlloc:word; {bytes passed to MemAllocSeg for the two frame buffers}
  egaPreview:boolean; {true when mode 6 actually set the display}

  {encoding buffers and structures:}
  opcodebuf,databuf,picbuf,combinedBuf:pointer;
  opcodeBufSize,dataBufSize:word;
  muxf,wavf:file;
  tmpHeader:XDVHeader;
  abuf:pointer;
  eticks:longint;
  old1cint:pointer;

procedure etickint; interrupt;
begin
  inc(eticks);
end;

Procedure PrintHelp;
begin
  asm
    push ds
    jmp @start
@message:
    db 'Usage:  xdp_comp [input script]',0dh,0ah
    db '$'
@start:
    mov ax,0900h
    lea dx,@message
    mov bx,cs
    mov ds,bx
    int 21h
    pop ds
  end;
  halt(255);
end;

procedure initCompiler;
begin
  if paramcount=0 then PrintHelp;
  openLogging(basename(paramstr(1))+'.LOG');
  stdout(inttostr(memavail)+ ' bytes free');

  frameAlloc:=screenRAMsize;
  egaPreview:=false;
  nextframe:=memAllocSeg(frameAlloc);
  prevframe:=memAllocSeg(frameAlloc);
  fillchar(nextframe^,frameAlloc,0);
  fillchar(prevframe^,frameAlloc,0);
  {extremely important that both segments are normalized.  If not, our speed
  optimizations and assumptions will break the code.}
  if (word(nextframe)<>0) or (word(prevframe)<>0)
    then fatalerr('frame pointers not normalized');
{$IFDEF HP95LX}
  CGARAM:=ptr($b000,0);
{$ELSE}
  CGARAM:=ptr($b800,0);
{$ENDIF}

  {initialize our delta data structure and allow duplicates}
  deltas:=New(PDeltas,Init(1024,32));
  deltas^.Duplicates:=true;

  opcodeBuf:=memAllocSeg(maxEncBufSize);
  dataBuf:=memAllocSeg(maxEncBufSize);
  packetIndex:=memAllocSeg(maxBuf);
  fillchar(packetindex^,maxBuf,0);
  fillchar(tmpHeader,sizeof(tmpHeader),0);

  {set up execution time logging}
  eticks:=0;
  GetIntVec($1C,old1cInt);
  SetIntVec($1C,Addr(etickint));
end;

procedure doneCompiler;
var
  numwritten,avgvid,avgpkt,maxpkt,w,w2:word;
  l,maxl,avgl:longint;
  s:string;
begin
  {stop counting ticks}
  SetIntVec($01C,old1cint);

  maxpkt:=1*512;
  stdout('Processed '
    +inttostr(totalDumpedBytes)+' screen changes ('
    +inttostr(totalDumpedDeltas)+' deltas) over '
    +inttostr(numEncodedFrames)+' frames');
  if numEncodedFrames<>0 then stdout('('+inttostr(numUniqueFrames)+' unique frames; effective framerate: '
    +realtostr((numUniqueFrames/numEncodedFrames) * sourcefps)+' fps) (source was '+realtostr(sourcefps)+')');
  stdout('Distribution of screen changes:');
  l:=numEncodedRuns+numEncodedSlices;
  stdout('  '+realtostr((numEncodedSlices / l) * 100)+'% slices');
  stdout('  '+realtostr((numEncodedRuns / l) * 100)+'% runs');
  stdout('Total compiled size: '+inttostr(totalEncodedBytes));
  if totalDumpedBytes<>0 then begin
    avgvid:=totalEncodedBytes div numEncodedFrames;
    {determine average packet size in KB}
    l:=0;
    for w:=0 to numEncodedFrames-1 do inc(l,packetIndex^[w]);
    l:=(l div numEncodedFrames) div 2;
    avgpkt:=l;

    {detemine average bitrate in KB}
    avgl:=0;
    for w:=0 to numEncodedFrames-1 do inc(avgl,packetIndex^[w] * 512);
    avgl:=trunc((avgl / numEncodedFrames) * sourcefps);
    avgl:=avgl div 1024;

    {determine maximum packet size}
    maxpkt:=0;
    for w:=0 to numEncodedFrames-1 do
      if maxpkt<packetIndex^[w] then maxpkt:=packetIndex^[w];
    maxpkt:=maxpkt * 512;

    {detemine max bitrate in KB}
    maxl:=round(maxpkt * sourcefps) div 1024;

    stdout('Expansion factor of changed bytes: '+realtostr(totalEncodedBytes/totalDumpedBytes)+':1');
    stdout('Average compiled video frame: '+inttostr(avgvid));
    stdout('Maximum compiled video frame: '+inttostr(maxEncodedBytes));
    stdout('Least amount of remaining cycles per frame: '+inttostr(leastCyclesRemaining));
    if numEncodedFrames>round(sourcefps*4) then begin
      s:='Average disk I/O: '+inttostr(avgl)+' KB/s';
      stdout(s);

      s:='Maximum disk I/O: '+inttostr(maxl)+' KB/s';
      stdout(s);
    end;
  end;
  if muxing and (numEncodedFrames<>0) then begin
    {write packet index to end of muxed stream}
    blockwrite(muxf,packetIndex^,numEncodedFrames,numwritten);
    if numwritten<>numEncodedFrames then stderr('disk error writing index; stream unusable');
    seek(muxf,4); {location of numPackets}
    blockwrite(muxf,numEncodedFrames,2);
    {write largestPacket right after it}
    blockwrite(muxf,maxpkt,2);
    close(muxf);
    close(wavf);
    freemem(abuf,tmpHeader.achunksize);
  end;
  stdout('Closing down...');
  dispose(deltas,done);
  {Mode 6 replaces the buffers, so the freed size is the size MemAllocSeg
   was last given. Other modes keep the historical screenRAMsize free
   (mode 5 reports 16000 of a 16384-byte block).}
  if screenmode=6 then begin
    freemem(nextframe,frameAlloc);
    freemem(prevframe,frameAlloc);
  end else begin
    freemem(nextframe,screenRAMsize);
    freemem(prevframe,screenRAMsize);
  end;
  freemem(opcodeBuf,maxEncBufSize);
  freemem(dataBuf,maxEncBufSize);
  freemem(packetIndex,maxBuf);

  stdout(inttostr(memavail)+ ' bytes free');
  stdout(realtostr(eticks / (14.31818/12/65536*1000000))+' seconds elapsed');
  closeLogging;

  xdc_donevid;
end;

function nearestEga(r,g,b:byte):byte;
{Nearest of the 16 default EGA colours. A CGA RGBI palette is an identity map.}
var
  i,best:byte;
  dr,dg,db,dist,bestDist:longint;
begin
  best:=0;
  bestDist:=$7FFFFFFF;
  for i:=0 to 15 do begin
    dr:=longint(r)-longint(egaR[i]);
    dg:=longint(g)-longint(egaG[i]);
    db:=longint(b)-longint(egaB[i]);
    dist:=dr*dr+dg*dg+db*db;
    if dist<bestDist then begin
      bestDist:=dist;
      best:=i;
    end;
  end;
  nearestEga:=best;
end;

procedure useEgaFrameBuffers;
{Replace the 16 KB CGA buffers with 32 KB planar buffers. Called when
 the script selects screenmode 6, before any frame is loaded.}
var
  oldSize:word;
begin
  if frameAlloc=egaFrameBytes then begin
    screenRAMsize:=egaFrameBytes;
    fillchar(nextframe^,screenRAMsize,0);
    fillchar(prevframe^,screenRAMsize,0);
    exit;
  end;
  oldSize:=frameAlloc;
  freemem(nextframe,oldSize);
  freemem(prevframe,oldSize);
  frameAlloc:=egaFrameBytes;
  screenRAMsize:=egaFrameBytes;
  nextframe:=memAllocSeg(frameAlloc);
  prevframe:=memAllocSeg(frameAlloc);
  if (nextframe=nil) or (prevframe=nil) then
    fatalerr('Not enough memory for 320x200 EGA frame buffers');
  if (word(nextframe)<>0) or (word(prevframe)<>0) then
    fatalerr('EGA frame pointers not normalized');
  fillchar(nextframe^,screenRAMsize,0);
  fillchar(prevframe^,screenRAMsize,0);
end;

procedure loadbmp(s:string);
{VERY HACKY, might replace with proper library later}
type
  tbmhead1=record
    filetype:word;
    filesize:longint;
    reserved1:word;
    resevved2:word;
    BitmapOffset:longint;
  end;
  pbmhead1=^tbmhead1;

  tbmhead2=record
    headerSize:longint;
    widthInPixels:longint;
    heightInPixels:longint;
    planes:word;
    bitsPerPixel:word;
    compmethod:longint;
    rawsize:longint;
    horRes:longint;
    verRes:longint;
    numColors:longint;
    numImportantColors:longint;
  end;
  pbmhead2=^tbmhead2;

var
  f:file;
  header1:pbmhead1;
  header2:pbmhead2;
  sl,destbank0,destbank1:pointer;
  w:word;
  src_slwidth,dst_slwidth:word;
  x:byte;
  sa:array[0..160-1] of byte;
  da:array[0..80-1] of byte;
  cellp:^word;
  fs:word;
  lp:longint;
  map:array[0..255] of byte;
  row:array[0..319] of byte;
  ci,stride,rowBase:word;
  rr,gg,bb,color,b0,b1,b2,b3:byte;
  bitn:word;
  y:integer;
  d0,d1,d2,d3,palb:^byte;
begin
  fillchar(nextFrame^,screenRAMsize,0);
  assign(f,s);
  reset(f,1);
  fs:=filesize(f);
  picbuf:=memAllocSeg(fs);
  blockread(f,picbuf^,fs,w);
  close(f);
  {Is this a CGADUMP file produced by cgaart?  If so, process, otherwise
  try to load a windows .BMP bitmap file.}
  if (pos('.cga',s)<>0) or (pos('.CGA',s)<>0) then begin
    sl:=picbuf;
    inc(longint(sl),16252-16192-2);
    move(sl^,nextframe^,16192);
  end else begin

    {start trying to make sense of the .bmp}
    header1:=picbuf;
    {Valid bitmap file?}
    if header1^.filetype<>$4d42 {"BM" little-endian}
      then fatalerr(s+' not a Windows bitmap file?');
    if header1^.filesize > maxbuf
      then fatalerr('Bitmap file too large for us to process');
    {now start checking out secondary header}
    header2:=pbmhead2(header1);
    inc(word(header2),14);
    {look for more error conditions}
    if header2^.headersize<>40
      then fatalerr(s+' not a Windows bitmap file?');
    if header2^.compMethod<>0
      then fatalerr('Bitmap must be uncompressed; this bitmap uses method '+inttostr(header2^.compMethod));

    case header2^.widthInPixels of
      640:begin
        {make sure this is a 640x200 pic with 1-bit pixels}
        if header2^.bitsPerPixel<>1
          then fatalerr('640x200 bitmap uses '+inttostr(header2^.bitsPerPixel)+'-bit pixels; need 1-bit');
        if header2^.heightInPixels<>200
          then fatalerr('640x bitmap has '+inttostr(header2^.heightInPixels)+' lines; need 200');
        if header2^.rawsize<>16000
          then fatalerr('Bitmap is too large for CGA; size='+inttostr(header2^.rawsize));
        sl:=pointer(header2);
        inc(word(sl),40); {skip second header}
        move(sl^,lp,4);
        inc(word(sl),header2^.numColors*4); {skip palette N entries in RGBA format}
        destbank0:=nextFrame;
        destbank1:=nextFrame;
        destbank1:=addptr(destbank1,8192);
        src_slwidth:=header2^.widthInPixels div (8 div header2^.bitsPerPixel);
        dst_slwidth:=src_slwidth;
        destbank0:=addptr(destbank0,8000-dst_slwidth);
        destbank1:=addptr(destbank1,8000-dst_slwidth);
        for w:=0 to 100-1 do begin
          move(sl^,destbank1^,dst_slwidth);
          sl:=addptr(sl,src_slwidth);
          destbank1:=subptr(destbank1,dst_slwidth);

          move(sl^,destbank0^,dst_slwidth);
          sl:=addptr(sl,src_slwidth);
          destbank0:=subptr(destbank0,dst_slwidth);
        end;
        {different programs create B&W files differently -- we are assuming
        palette is 0,0,0 then 255,255,255.  If B&W palette is actually swapped,
        swap the bits in the buffer:}
        if lp<>0 then asm
          les     di,nextFrame
          mov     cx,screenRAMsize
          shr     cx,1
          push    ds
          push    es
          pop     ds
          mov     si,di

        @loopit:
          lodsw
          xor     ax,$FFFF
          stosw
          loop    @loopit

          pop     ds
        end;
      end;
      160:begin
        if screenmode=5 then begin
          {160x100x16 RGBI. Each cell is char 0xDE plus an attribute:
           background = left pixel, foreground = right pixel. Only those
           odd attribute bytes differ from the previous frame once the
           screen has been filled with 0xDE.}
          if header2^.bitsPerPixel<>8
            then fatalerr('160x100 bitmap uses '+inttostr(header2^.bitsPerPixel)+'-bit pixels; need 8-bit');
          if header2^.heightInPixels<>100
            then fatalerr('160x100 bitmap has '+inttostr(header2^.heightInPixels)+' lines; need 100');
          sl:=pointer(header2);
          inc(word(sl),40);
          inc(word(sl),header2^.numColors*4);
          src_slwidth:=header2^.widthInPixels div (8 div header2^.bitsPerPixel);
          destbank0:=nextFrame;
          destbank0:=addptr(destbank0,16000-160);
          for w:=0 to 99 do begin
            move(sl^,sa,160);
            for x:=0 to 79 do
              da[x]:=((sa[x*2] and $0F) shl 4) or (sa[(x*2)+1] and $0F);
            cellp:=destbank0;
            for x:=0 to 79 do begin
              cellp^:=$00DE or (word(da[x]) shl 8);
              inc(word(cellp),2);
            end;
            sl:=addptr(sl,src_slwidth);
            destbank0:=subptr(destbank0,160);
          end;
        end else begin
        {make sure this is a 160x200 pic with 8-bit pixels (because it is
        surprisingly difficult to save a 16-color picture as 4-bit with a
        custom palette using modern tools -- I guess they all removed that
        functionality}
        if header2^.bitsPerPixel<>8
          then fatalerr('Desired 160x200 bitmap uses '+inttostr(header2^.bitsPerPixel)+'-bit pixels; need 8-bit');
        sl:=pointer(header2);
        inc(word(sl),40); {skip second header}
        inc(word(sl),header2^.numColors*4); {skip palette N entries in RGBA format}
        destbank0:=nextFrame;
        destbank1:=nextFrame;
        destbank1:=addptr(destbank1,8192);
        src_slwidth:=header2^.widthInPixels div (8 div header2^.bitsPerPixel);
        dst_slwidth:=80;
        destbank0:=addptr(destbank0,8000-dst_slwidth);
        destbank1:=addptr(destbank1,8000-dst_slwidth);
        for w:=0 to 100-1 do begin
          {convert 8-bit values to 4-bit in-place}
          move(sl^,sa,sizeof(sa));
          for x:=0 to 80-1 do
            da[x]:=(sa[x*2] shl 4) OR sa[(x*2)+1];
          move(da,destbank1^,dst_slwidth);
          sl:=addptr(sl,src_slwidth);
          destbank1:=subptr(destbank1,dst_slwidth);

          if header2^.heightInPixels>100 then begin
            move(sl^,sa,sizeof(sa));
            for x:=0 to 80-1 do
              da[x]:=(sa[x*2] shl 4) OR sa[(x*2)+1];
            move(da,destbank0^,dst_slwidth);
            sl:=addptr(sl,src_slwidth);
            destbank0:=subptr(destbank0,dst_slwidth);
          end;
        end;
        end;
      end;
      320:begin
        {EGA mode 0Dh. 8-bit BMP, palette indices mapped onto the 16
         default EGA colours. Planes are stored back to back:
         plane 0 (blue) at 0, green at 8000, red at 16000, intensity
         at 24000. Each plane is 40 bytes per scanline, linear.
         The leftmost pixel of a byte is bit 7.}
        if screenmode<>6 then
          fatalerr('320x200 bitmap requires screenmode=6');
        if header2^.bitsPerPixel<>8 then
          fatalerr('320x200 bitmap uses '+inttostr(header2^.bitsPerPixel)+'-bit pixels; need 8-bit');
        if header2^.heightInPixels<>200 then
          fatalerr('320x200 bitmap has '+inttostr(header2^.heightInPixels)+' lines; need 200');
        sl:=pointer(header2);
        inc(word(sl),40);
        palb:=sl;
        if (header2^.numColors<=0) or (header2^.numColors>256) then w:=256
          else w:=word(header2^.numColors);
        for ci:=0 to 255 do map[ci]:=0;
        for ci:=0 to w-1 do begin
          bb:=palb^; inc(word(palb));
          gg:=palb^; inc(word(palb));
          rr:=palb^; inc(word(palb));
          inc(word(palb)); {reserved}
          map[ci]:=nearestEga(rr,gg,bb);
        end;
        sl:=palb;
        {8-bit rows are padded to a multiple of 4. 320 already is.}
        stride:=320;
        if longint(word(sl))+longint(stride)*200>fs then
          fatalerr('320x200 bitmap is truncated');
        {File is bottom-up. The first stored row is screen line 199.}
        for y:=199 downto 0 do begin
          move(sl^,row,320);
          sl:=addptr(sl,stride);
          rowBase:=word(y)*word(40);
          d0:=nextframe; inc(word(d0),rowBase);
          d1:=nextframe; inc(word(d1),8000); inc(word(d1),rowBase);
          d2:=nextframe; inc(word(d2),16000); inc(word(d2),rowBase);
          d3:=nextframe; inc(word(d3),24000); inc(word(d3),rowBase);
          ci:=0;
          while ci<320 do begin
            b0:=0; b1:=0; b2:=0; b3:=0;
            for bitn:=0 to 7 do begin
              color:=map[row[ci]];
              inc(ci);
              b0:=lo(word(b0) shl 1);
              b1:=lo(word(b1) shl 1);
              b2:=lo(word(b2) shl 1);
              b3:=lo(word(b3) shl 1);
              if (color and 1)<>0 then b0:=b0 or 1;
              if (color and 2)<>0 then b1:=b1 or 1;
              if (color and 4)<>0 then b2:=b2 or 1;
              if (color and 8)<>0 then b3:=b3 or 1;
            end;
            d0^:=b0; inc(word(d0));
            d1^:=b1; inc(word(d1));
            d2^:=b2; inc(word(d2));
            d3^:=b3; inc(word(d3));
          end;
        end;
      end;
      240:begin
        {make sure this is a 240x128 pic with 1-bit pixels}
        if header2^.bitsPerPixel<>1
          then fatalerr('240x128 bitmap uses '+inttostr(header2^.bitsPerPixel)+'-bit pixels; need 1-bit');
        if header2^.heightInPixels<>128
          then fatalerr('240x bitmap has '+inttostr(header2^.heightInPixels)+' lines; need 128');
        if header2^.rawsize<>4096
          then fatalerr('Bitmap is too large for 95LX; size='+inttostr(header2^.rawsize));
        sl:=pointer(header2);
        inc(word(sl),40); {skip second header}
        move(sl^,lp,4);
        inc(word(sl),header2^.numColors*4); {skip palette N entries in RGBA format}
        destbank0:=nextFrame;
        src_slwidth:=32;
        dst_slwidth:=screenbytewidth;
        destbank0:=addptr(destbank0,3840-dst_slwidth);
        for w:=0 to screenbyteheight-1 do begin
          move(sl^,destbank0^,dst_slwidth);
          sl:=addptr(sl,src_slwidth);
          destbank0:=subptr(destbank0,dst_slwidth);
        end;
        if lp=0 then asm { LCD is the inverse of CRT }
          les     di,nextFrame
          mov     cx,screenRAMsize
          shr     cx,1
          push    ds
          push    es
          pop     ds
          mov     si,di

        @loopit:
          lodsw
          xor     ax,$FFFF
          stosw
          loop    @loopit

          pop     ds
        end;
      end;
    else
      if screenmode=6 then
        fatalerr('Mode 6 needs a 320x200 8-bit bitmap')
      else
        fatalerr('Not a resolution we handle (yet)');
    end;

  end;
  {if debug>0 then move(nextframe^,cgaram^,screenRAMsize);}
  freemem(picbuf,fs);
end;

procedure findDeltas;
{
Compare nextframe to prevframe, determine where the delta slices are, and
insert that information into a memory structure that we can more easily
manipulate and optimize.

Implemented with a mixture of Turbo Pascal and assembler.  THIS CODE IS
INCOMPATIBLE with other compilers and architectures because I am taking
advantage of knowing my pointers are normalized.  If you port this to other
platforms, you'll have to rewrite this procedure!
}
var
  foundStart,foundEnd,endbuf,newstart,lastfound:word;
  foosrc,foodest:pointer;

  procedure insertSpan(a,b:word);
  {Mode 6 deltas have to stop on a plane boundary. A linear REP across
   that boundary would wrap to A000:0000 on the next plane.
   The end offset is computed in longint so 4*8000 does not overflow
   a signed 16-bit intermediate.}
  var
    nb:longint;
    planeEnd:word;
  begin
    if screenmode<>6 then begin
      deltas^.Insert(new(pDelta,init(a,b)));
      exit;
    end;
    if a>=screenRAMsize then exit;
    if b>=screenRAMsize then b:=screenRAMsize-1;
    while (longint(a) div egaPlaneBytes)<>(longint(b) div egaPlaneBytes) do begin
      nb:=(longint(a) div egaPlaneBytes)+1;
      nb:=nb*longint(egaPlaneBytes)-1;
      planeEnd:=word(nb);
      deltas^.Insert(new(pDelta,init(a,planeEnd)));
      a:=word(nb+1);
    end;
    if a<=b then deltas^.Insert(new(pDelta,init(a,b)));
  end;

begin
  endbuf:=screenRAMsize+1; {to ensure we compare the last byte in the buffer}
  foundstart:=0;
  lastfound:=$ffff;
  foundend:=0;
  newstart:=0;
  repeat
    asm
      push    ds
      cld
      les     di,nextframe            {set up comparison buffer}
      mov     di,newstart
      mov     cx,endbuf               {number of bytes to check}
      lds     si,prevframe            {set up comparison buffer}
      mov     si,di                   {point to byte past last range end}
      repe    cmpsb                   {repeat while equal}
      jcxz    @done                   {if entire buffer equal, abort}
      mov     foundStart,si
      dec     foundStart              {save where first nonmatch was found}
      repne   cmpsb                   {repeat while NOT equal}
      mov     newstart,si             {record where we should resume search}
      dec     si                      {-1 to adjust landing position}
      dec     si                      {-1 to reflect actual last diff pos}
      mov     foundEnd,si             {save where last nonmatch was found}
    @done:
      mov     endbuf,cx
      pop     ds
    end;
    {lastfound<>foundstart is to prevent a bug in the asm
    from creating a duplicate on the very last match -- need to
    fix this properly someday!}
    if (foundstart=0) and (foundend=0) and (endbuf=0)
      then stdout('frame is identical to previous')
      else if lastfound<>foundstart then begin
        insertSpan(foundStart,foundEnd);
        lastfound:=foundstart;
      end;
  until endbuf=0;
end;

procedure encodeDeltas;
{
Runs through the delta list and encodes it as x86 opcodes, counting cycles
as well as output bytes to ensure we don't exceed our maximum draw time
or maximum storage I/O time.
As each delta is committed to code, it is deleted from the list.

Workflow:
  prepare for encoding (ie. zero out buffers and counters)
  encode to multiple targets
  pick best target based on user preference
  do we have free cycles and bytes in our pools to commit this?
    if so, commit:
      save to buffer, dec. cycles and byte pools, remove delta from list,
      update cached registers, write to log
    if not, write to log that we skipped a delta
  repeat until entire list processed
}

var
  cyclePool:real;
  bytePool:integer;
  tmpe:TEncodeTarget;
  listPos:word;
  dtmp:pdelta;
  opcodeBufPos,dataBufPos:pointer;
  bp:^byte;

  procedure commitDelta(pd:pdelta;et:tEncodeTarget);
  {Copy opcodes/data to respective buffers; adjust bandwidth pools appropriately}
  var
    p,q:pointer;
  begin
    move(et.codes,opcodeBufPos^,et.numOpcodeBytes);
    inc(word(opcodeBufPos),et.numOpcodeBytes);
    inc(opcodeBufSize,et.numOpcodeBytes);
    {Only the encoding we actually emit may claim AL. A trial STOS used to
     set the flag before REP STOS ran, so the shorter form could omit
     MOV AL while lastAL still held the previous fill.}
    if et.modifiedAL then begin
      lastAL:=et.AL;
      ALcached:=true;
    end;
    if et.numDataBytes>0 then begin
      p:=nextframe;
      word(p):=pd^.startofs;
      move(p^,databufpos^,et.numDataBytes);
      inc(word(databufpos),et.numDataBytes);
      inc(dataBufSize,et.numDataBytes);
    end;
    {Mode 6 does not read the picture back from B800. The bytes just
     committed are exactly what the generated stores write into A000,
     so keep prevframe in step here.}
    if screenmode=6 then begin
      p:=nextframe;
      word(p):=pd^.startofs;
      q:=prevframe;
      word(q):=pd^.startofs;
      move(p^,q^,pd^.blength);
    end;
    cyclePool:=cyclePool-et.totalCycles;
    bytePool:=bytePool-et.totalBytes;
    if (cyclepool<0) or (bytepool<0)
      then fatalerr('Pools overcommitted; bug in calculations?');
    if debug>2
      then stdout('Committed '+deltainfo(pd)
      +', cycle pool now '+realtostr(cyclepool)
      +', byte pool now '+inttostr(bytepool));
    {maintain info variables}
    if leastCyclesRemaining>round(cyclePool)
      then leastCyclesRemaining:=round(cyclePool);
    if maxEncodedBytes < (maxVChunk-bytepool)
      then maxEncodedBytes:=maxVChunk-bytepool;
    inc(totalDumpedBytes,pd^.blength);
    inc(totalDumpedDeltas);
    if pd^.dtype=slice
      then inc(numEncodedSlices)
      else inc(numEncodedRuns);
    deltas^.free(pd);
  end;

  procedure emitMapMask(plane:byte);
  {MOV AX,(mask shl 8) or 2; OUT DX,AX. DX is 3C4 from the frame header.
   One write enables a single plane. AL is 2 afterwards. The caller
   records that before encoding the first delta of the plane.}
  const
    masks:array[0..3] of byte=($01,$02,$04,$08);
  var
    b:^byte;
  begin
    if plane>3 then fatalerr('EGA plane number out of range');
    b:=opcodeBufPos;
    b^:=$B8; inc(word(b));
    b^:=$02; inc(word(b));
    b^:=masks[plane]; inc(word(b));
    b^:=$EF; inc(word(b));
    opcodeBufPos:=b;
    inc(opcodeBufSize,mapMaskBytes);
    cyclePool:=cyclePool-mapMaskCycles;
    bytePool:=bytePool-mapMaskBytes;
  end;

  procedure encodeEgaPlanes;
  {Largest remaining delta picks the plane. Every delta of that plane
   that fits is emitted before the next map-mask write, so a frame
   switches planes at most four times.}
  var
    pass,plane,bestPlane:byte;
    bestLen:word;
    seen:array[0..3] of boolean;
    maskOn:boolean;
    scan:integer;
    dscan:pdelta;
    extraB:word;
    extraC:real;
  begin
    for plane:=0 to 3 do seen[plane]:=false;
    for pass:=0 to 3 do begin
      bestLen:=0;
      bestPlane:=0;
      if deltas^.count=0 then break;
      for plane:=0 to 3 do if not seen[plane] then begin
        for scan:=0 to deltas^.count-1 do begin
          dscan:=pdelta(deltas^.at(scan));
          if byte(longint(dscan^.startofs) div egaPlaneBytes)=plane then
            if dscan^.blength>bestLen then begin
              bestLen:=dscan^.blength;
              bestPlane:=plane;
            end;
        end;
      end;
      if bestLen=0 then break;
      seen[bestPlane]:=true;
      maskOn:=false;
      listPos:=0;
      while deltas^.count>0 do begin
        if integer(listPos)>=deltas^.count then break;
        dtmp:=pdelta(deltas^.at(listPos));
        if byte(longint(dtmp^.startofs) div egaPlaneBytes)<>bestPlane then begin
          inc(listPos);
          continue;
        end;
        {The mask is MOV AX,(mask shl 8) or 2, so AL is 2 at the first
         store of a plane. Later deltas keep whatever commitDelta recorded.}
        if not maskOn then lastAL:=2;
        ALcached:=true;
        encodeDelta(dtmp,tmpe);
        extraB:=0;
        extraC:=0;
        if not maskOn then begin
          extraB:=mapMaskBytes;
          extraC:=mapMaskCycles;
        end;
        if (longint(tmpe.totalBytes)+extraB<=bytePool)
        and (tmpe.totalCycles+extraC<cyclePool) then begin
          if not maskOn then begin
            emitMapMask(bestPlane);
            maskOn:=true;
          end;
          commitDelta(dtmp,tmpe);
        end else
          inc(listPos);
      end;
    end;
  end;

begin
  cyclePool:=cyclesPerFrame;
  if screenmode=6 then bytePool:=maxVChunk-egaFrameOverhead
    else bytePool:=maxVChunk-frameByteOverhead;
  opcodeBufSize:=0; dataBufSize:=0;
  opcodeBufPos:=opcodebuf; dataBufPos:=databuf;
  listPos:=0;
  lastAL:=0;
  tmpe.modifiedAL:=true;

  {prep opcode buffer and encoding structure(s)}
  fillchar(opcodebuf^,maxEncBufSize,0);

  {inject frame header}
  if screenmode=6 then begin
    move(egaFrameHeaderCode,opcodeBufPos^,egaFrameHeaderLen);
    inc(word(opcodeBufPos),egaFrameHeaderLen);
    inc(opcodeBufSize,egaFrameHeaderLen);
  end else begin
    move(frameHeaderCode,opcodeBufPos^,frameheaderLen);
    inc(word(opcodeBufPos),frameHeaderLen);
    inc(opcodeBufSize,frameHeaderLen);
  end;

  {Scan delta list top to bottom, so that we can encode the larger deltas first.  If we
  have an empty delta list (ie. nextframe=prevframe), this will do nothing.}
  ALcached:=false;
  if screenmode=6 then encodeEgaPlanes
  else while (deltas^.count>0) and (listPos<deltas^.Count) do begin
    dtmp:=pdelta(deltas^.at(listPos));
    encodeDelta(dtmp,tmpe);
    if (tmpe.totalBytes <= bytePool)
    and (tmpe.totalCycles < cyclePool)
      then commitDelta(dtmp,tmpe)
      else inc(listPos);
  end;

  {inject frame footer.  Requires normalized pointers.}
  if screenmode=6 then begin
    move(egaFrameFooterCode,opcodebufPos^,egaFrameFooterLen);
    inc(word(opcodeBufPos),egaFrameFooterLen);
    inc(opcodeBufSize,egaFrameFooterLen);
  end else begin
    move(frameFooterCode,opcodebufPos^,frameFooterLen);
    inc(word(opcodeBufPos),frameFooterLen);
    inc(opcodeBufSize,frameFooterLen);
  end;
  if (word(opcodeBufPos)<>opcodeBufSize) then fatalerr('opcode pointer/size mismatch');
  if (word(dataBufPos)<>dataBufSize) then fatalerr('data pointer/size mismatch');
  inc(numEncodedFrames);
  if (screenmode=5) or (screenmode=6) then
    stdout('Frame '+inttostr(numEncodedFrames)
      +': '+inttostr(opcodeBufSize+dataBufSize)+' bytes, '
      +realtostr(cyclesPerFrame-cyclePool)+' cycles, '
      +inttostr(deltas^.count)+' deltas left');
end;

function sliceEncodedSize(sofs,eofs:word):word;
{Function for estimating how large, in code+data, it will take to
encode a slice.  This is used during the optimization stage to make
intelligent decisions about when it makes sense to combine deltas.

Should this be REPLACED at a later date by the function that ACTUALLY encodes
deltas to code?  For accuracy, yes.  For speed, no.  In testing with actual
code generation to guage the size, the combine phase nearly ground to a halt.}

var
  singlestore,repstore,blen:word;
begin
  blen:=1+(eofs-sofs);
  case blen of
    1,2:singlestore:=3+1+blen;
    3,4:singlestore:=3+2+blen;
    5,6:singlestore:=3+3+blen;
  else
    singlestore:=$ffff; {we don't encode this form for >6}
  end;
  repstore:=REPMOVSbyteCost+blen;
  if singlestore < repstore
    then sliceEncodedSize:=singlestore
    else sliceEncodedSize:=repstore;
end;

procedure optimizeDeltas;
{
We optimize the delta list for size primarily and speed secondarily.
(Speedups are 99% a side-effect of optimizing for size.)  Run through the
delta list in multiple passes and phases to:

- Combine multiple slices if they are within X distance of each other, because
the setup for a rep movs is 4 code bytes and 4 data bytes.  4+4 means, if next
slice is 8 or less bytes away, just combine it with the current slice.  Frame
514 of the diff_preview_cga.avs shows why this is necessary.

- Extract runs out of long slices.  Runs are faster to "replay" then slices,
and are incredibly compact which saves us disk I/O.  (note to self: Make sure
to check thresholds to ensure run is actually a win.  Consider runs "immune"
from subsequent split/join operations.)

- Truncate any delta that exceeds our maximum slice or run replay time into
one that is just under the limit, and its remainder.

- If requested by the user, eliminate single-pixel changes and very small
deltas to reduce the amount of data we need to encode, at a small visual
quality penalty.  (We refer to this as "pixel shaving" and "delta shaving".)

}

var
  maxFrameCycles:real;
  maxFrameBytes:word;

  procedure FindHiddenRuns;
  {Identify runs inside deltas, and split runs out of them.
  This is a *massive* size win and should never be skipped.}

  var
    runVal:byte;
    runCount,runStartOfs,runEndOfs:word;
    didx:integer;
    w:word;
    bp:^byte;
    changed:boolean;
    dtmp,dtmp1,dtmp2,dtmp3:pdelta;

    procedure resetRunCounting;
    begin
      runVal:=bp^;
      runCount:=1;
      runstartofs:=word(bp);
      runendofs:=runstartofs;
    end;

  begin
    if debug>1 then stdout('Identifying runs');
    repeat
      changed:=false;
      for didx:=0 to deltas^.count-1 do begin
        dtmp:=pdelta(deltas^.at(didx));
        {if already a run, or length doesn't qualify for being one, skip it}
        if dtmp^.dtype=run then continue;
        if dtmp^.blength<minRunLength then continue;
        {examine slice to see if there is a viable run inside it}
        bp:=nextframe;
        word(bp):=dtmp^.startofs;
        resetRunCounting;
        {examine every byte of the slice, counting # of repeated bytes. Every
        time byte value changes, check the count of the previous run and split
        if a viable run is found.}
        for w:=dtmp^.startofs to dtmp^.endofs+1 {+1 handle sr cases} do begin
          word(bp):=w;
          if bp^=runVal then begin
            runendofs:=w;
            runcount:=runendofs-runstartofs+1;
          end else begin
            if runCount>=minRunLength then begin
              {create delta containing only the run, then create one or two
              deltas with the remaining slice information.  Need to handle
              three cases where run could be hiding: rs, srs, sr}
              if debug>3 then stdout('Creating a run:');
              if runstartofs=dtmp^.startofs {rs} then begin
                dtmp1:=new(pdelta,init(dtmp^.startofs,runendofs));
                if dtmp1^.dtype<>run then fatalerr('Run was not entered as run?');
                dtmp2:=new(pdelta,init(runendofs+1,dtmp^.endofs));
                deltas^.insert(dtmp1);
                deltas^.insert(dtmp2);
                deltas^.free(dtmp);
              end else if runendofs=dtmp^.endofs {sr} then begin
                dtmp1:=new(pdelta,init(dtmp^.startofs,runstartofs-1));
                dtmp2:=new(pdelta,init(runstartofs,dtmp^.endofs));
                if dtmp2^.dtype<>run then fatalerr('Run was not entered as run?');
                deltas^.insert(dtmp1);
                deltas^.insert(dtmp2);
                deltas^.free(dtmp);
              end else {srs} begin
                dtmp1:=new(pdelta,init(dtmp^.startofs,runstartofs-1));
                dtmp2:=new(pdelta,init(runstartofs,runendofs));
                if dtmp2^.dtype<>run then fatalerr('Run was not entered as run?');
                dtmp3:=new(pdelta,init(runendofs+1,dtmp^.endofs));
                deltas^.insert(dtmp1);
                deltas^.insert(dtmp2);
                deltas^.insert(dtmp3);
                deltas^.free(dtmp);
              end;
              changed:=true;
              break; {out of this delta}
            end;
            resetRunCounting;
            continue;
          end;
        end;
      end;
    until not changed;
  end;

  procedure SubdivideOversizeDeltas;
  {break apart deltas that are too large for our available cycles.
  Mark these "optimal size" deltas as "frozen".
  Pay attention to run cycles vs. slice cycles.}

  var
    didx:integer;
    changed:boolean;
    dtmp,dtmp1,dtmp2,dtmp3:pdelta;

  begin
    repeat
      changed:=false;
      for didx:=0 to deltas^.count-1 do begin
        dtmp:=pdelta(deltas^.at(didx));
        if dtmp^.REPcycleCost>maxFrameCycles then begin
          stdout('truncating oversize delta :'+deltaInfo(dtmp));
          {create new delta with max length}
          {determine max length in bytes; round down and make even}
          if dtmp^.dtype=slice
            then maxFrameBytes:=trunc(maxFrameCycles/REPMOVSWcycleCost)*2
            else maxFrameBytes:=trunc(maxFrameCycles/REPSTOSWcycleCost)*2;
          if maxFrameBytes>maxVChunk-frameByteOverhead-REPSTOSbyteCost-1
            then maxFrameBytes:=maxVChunk-frameByteOverhead-REPSTOSbyteCost-1;
          {round down to even number so that gigantic slices can REP MOVSW}
          {Actually, we're not using this, but will later if we ever decide
          to target 8086+}
          {maxFrameBytes:=maxFrameBytes AND $FFFE;}
          {Build two new deltas: one truncated to max, other with remainder.
          "freeze" the max one, since there's no reason to process it further.}
          dtmp1:=new(pdelta,init(dtmp^.startofs,dtmp^.startofs+maxFrameBytes-1));
          dtmp1^.frozen:=true;
          dtmp2:=new(pdelta,init(dtmp^.startofs+maxFrameBytes,dtmp^.endofs));
          stdout('replacing with '+deltaInfo(dtmp1)+' and '+deltaInfo(dtmp2));
          deltas^.insert(dtmp1);
          deltas^.insert(dtmp2);
          deltas^.free(dtmp);
          changed:=true;
        end;
      end;
    until not changed;
  end;

  procedure ShaveTinyDeltas;
  {shave deltas or pixels.  We do this before the combination step so that we
  have less "stragglers" to compare and combine.}

  {Because shaving will eventually leave "trails" behind, we opt not to do it
  once every second.  (Future enhancement: Allow user to specify keyframe
  interval.)}

  var
    didx:integer;
    dtmp:pdelta;

  begin
    if (numEncodedFrames mod round(sourcefps))<>0 then begin
      {delta shaving:
      We work from the end of the collection to the beginning, because
      removing a delta shrinks the total number of items in the collection,
      and the end has the sorted deltas we care about}
      if shaveDeltas then begin
        if debug>2 then stdout('Shaving deltas:');
        for didx:=deltas^.count-1 downto 0 do begin
          dtmp:=pdelta(deltas^.at(didx));
          {remove any deltas with pixels under the threshold}
          if (dtmp^.blength<shaveDeltaMinimum) then begin
            if debug>1 then stdout('Shaving delta '+inttostr(didx)+deltaInfo(dtmp));
            deltas^.AtFree(didx);
          end
            else break; {no point continuing if everything above us >1 byte}
        end;
      end;

      {pixel shaving:
      {check if shaving deltas first, since if we are, there is no point to
      shaving pixels because there won't be any 1-byte deltas in the list.
      # of changed pixels is calculated on insert into the list, not here.}
      if shavePixels and not shaveDeltas then begin
        if debug>2 then stdout('Shaving pixels:');
        for didx:=deltas^.count-1 downto 0 do begin
          dtmp:=pdelta(deltas^.at(didx));
          {remove any deltas with pixels under the threshold}
          if (dtmp^.blength=1) then begin
            if (dtmp^.numPixelsChanged<shavePixelMinimum) then begin
              if debug>2 then stdout('Shaving pixel delta '+inttostr(didx)+deltaInfo(dtmp));
              deltas^.AtFree(didx);
            end;
          end
            else break; {no point continuing if everything above us >1 byte}
        end;
      end;
    end;
  end;

  procedure ConcatenateDeltas;
  {concatenate geographically-close slices together:
  We combine slices to save space in the code generation step.  Meaning,
  if it takes 5 bytes to plot a single byte, and a single byte is 5
  or less bytes away from some other slice, we expand that slice to include
  the single pixel.  Same goes for slices: Since slice setup code is 7 bytes,
  if we have two slices 7 or less bytes away from each other, it makes
  sense to combine them.  The end result changes more pixels onscreen, but
  it takes less space and executes quicker.

  Ignore frozen deltas, which are frozen for a good reason (already optimal).
  Don't combine something if the result will exceed maximum frame time.

  To greatly cut down on the search space, we transfer deltas into a data
  structure that maps deltas near each other geographically so that they are
  easier to navigate.}

  var
    didx:integer;
    w:word;
    dstarts:PDeltaStarts;
    dcand1,dcand2,dcomb:pdelta;

  begin
    maxFrameBytes:=trunc(maxFrameCycles/REPMOVSWcycleCost)*2;
    if maxFrameBytes>maxVChunk-frameByteOverhead-REPMOVSbyteCost-1
      then maxFrameBytes:=maxVChunk-frameByteOverhead-REPMOVSbyteCost-1;
    if combineDeltas and (deltas^.count>4) then begin
      {copy deltas into a data structure that sorts by start offset so that
      we can traverse deltas in spatial order}
      dstarts:=new(PDeltaStarts,init(1024,32));
      for w:=0 to deltas^.count-1 do dStarts^.insert(deltas^.at(w));
      {we make assumptions based on everything being in the right
      order, so we had better sanity-check our structure:}
      for w:=0 to dstarts^.count-2 do begin
        if pDelta(dstarts^.at(w))^.endofs >= pDelta(dstarts^.at(w+1))^.startofs
          then fatalerr('Sorted structure not sorted?');
      end;

      didx:=0;
      while (didx < dstarts^.count-2) do begin
        dcand1:=dstarts^.at(didx);
        if (dcand1^.dtype=run) or (dcand1^.frozen) then begin
          inc(didx);
          continue;
        end;

        dcand2:=dstarts^.at(didx+1);
        if (dcand2^.dtype=run) or (dcand2^.frozen) then begin
          inc(didx);
          continue;
        end;

        {Early termination test thanks to spatial ordering. Slices must be
        within certain distance to be combined; if we aren't worth combining
        here, then we won't be for the rest of them either. Break and advance.}
        if (dcand2^.startofs-dcand1^.endofs > maxCombineDistance) then begin
          inc(didx);
          continue;
        end;

        {Joining across a plane boundary would build one REP that the
         A000 window cannot execute. Leave the two slices apart.}
        if (screenmode=6) and
           ((dcand1^.startofs div egaPlaneBytes)<>(dcand2^.endofs div egaPlaneBytes)) then begin
          inc(didx);
          continue;
        end;

        {sanity checks}
        if (dcand1^.startofs=dcand2^.startofs) or (dcand1=dcand2) then begin
          stderr('Attempted to compare duplicates: ');
          stderr(deltainfo(dcand1)+' and '+deltainfo(dcand2));
	        fatalerr('Faith in programmer and/or data structure lost');
        end;

        {combination acceptance conditions:}
        {there must be actual savings to combine them}
        if (sliceEncodedSize(dcand1^.startofs,dcand2^.endofs)
          < sliceEncodedSize(dcand1^.startofs,dcand1^.endofs)+sliceEncodedSize(dcand2^.startofs,dcand2^.endofs))
        {is combined slice within maximum limits?}
        and (dcand1^.blength+dcand2^.blength < maxFrameBytes)
        then begin
          if debug>1 then stdout('Combining '+deltaInfo(dcand1) +' and '+deltaInfo(dcand2));
	        {make a combined delta}
          dcomb:=new(pdelta,init(dcand1^.startofs,dcand2^.endofs));
	        {remove old deltas from temp structure}
	        dstarts^.delete(dcand1);
	        dstarts^.delete(dcand2);
	        {destroy old deltas permanently}
          deltas^.free(dcand1);
          deltas^.free(dcand2);
	        {insert new combined delta into world and temp structure}
          dstarts^.insert(dcomb);
          deltas^.insert(dcomb);
        end else begin
          {not a candidate -- keep going}
          inc(didx);
        end;
      end;
      {empty out temp structure without harming delta objects}
      dstarts^.deleteall;
      dispose(dstarts,done);
    end;
  end;

begin
  if debug>1 then stdout('Optimizing delta list');
  {Deterine maximum cycle count for a frame we must not exceed.  Include
  a 1% margin to account for the setup code.}
  maxFrameCycles:=cyclesPerFrame * 0.99;

  FindHiddenRuns;
  SubdivideOversizeDeltas;
  ShaveTinyDeltas;
  ConcatenateDeltas;
  FindHiddenRuns;
  ShaveTinyDeltas;
end;

procedure checkEgaReadback;
{The generated code just ran against a real EGA/VGA mode 0Dh. Read each
 plane back and compare it with prevframe, which commitDelta updated
 with the same bytes. A mismatch means the stores or the map mask are wrong.}
var
  plane:byte;
  i,off:word;
  v,p:^byte;
begin
  off:=0;
  for plane:=0 to 3 do begin
    PortW[$3CE]:=(word(plane) shl 8) or 4; {read map select}
    v:=Ptr($A000,0);
    p:=prevframe;
    inc(word(p),off);
    for i:=0 to egaPlaneBytes-1 do begin
      if v^<>p^ then
        fatalerr('Mode 6 readback mismatch, plane '+inttostr(plane)
          +' offset '+inttostr(i)
          +' screen='+inttostr(v^)+' encoded='+inttostr(p^));
      inc(word(v));
      inc(word(p));
    end;
    if plane<3 then inc(off,egaPlaneBytes);
  end;
end;

procedure saveDeltas(fname:string);
{translate our opcode and data buffers into a single code segment, then
combine with audio data and dump to disk.
Align to sector sizes. Update packetIndex.

This routine assumes normalized pointers!}
var
  outf:file;
  pw:^word;
  p:pointer;
  numread,numwritten:word;
  packetSize:word;
begin
  {determine the size of this packet, aligned to sector boundary}
  packetSize:=opcodebufsize+dataBufSize+tmpHeader.achunksize;
  packetSize:=(packetSize+(padAlign-1)) AND NOT (padAlign-1);
  (*if packetSize-tmpHeader.achunksize>maxVChunk
    then fatalerr('Packet size '+inttostr(packetSize)
      +' is larger than limit of '+inttostr(maxVChunk+tmpHeader.achunksize));*)

  {combine into single buffer}
  combinedBuf:=memAllocSeg(maxEncBufSize*2);
  fillchar(combinedBuf^,packetSize,0);
  p:=combinedBuf;
  move(opcodeBuf^,p^,opcodebufsize);
  inc(word(p),opcodeBufSize);
  move(dataBuf^,p^,dataBufSize);
  {perform fixup on where data segment is}
  pw:=combinedBuf;
  if screenmode=6 then inc(word(pw),egaSiFixup)
    else inc(word(pw),4);
  pw^:=opcodeBufSize;
  {perform fixup on where video memory is}
{$IFDEF HP95LX}
  if screenmode = 4 then begin
    inc(word(pw),3);
    pw^:=$b000;
  end;
{$ENDIF}
  {write packet to file (no audio) or output stream (if audio)}
  if not muxing then begin
    assign(outf,fname);
    rewrite(outf,1);
    blockwrite(outf,combinedBuf^,packetSize,numwritten);
    close(outf);
    if numwritten<>packetSize then fatalerr('disk error');
  end else begin
    fillchar(abuf^,tmpHeader.achunksize,127); {127=silence val for 8-bit PCM}
    blockread(wavf,abuf^,tmpHeader.achunksize,numread);
    if numread<tmpHeader.achunksize then stderr('Read past end of sound data');
    {copy audio data to end of packet}
    p:=combinedBuf;
    word(p):=packetSize-tmpHeader.achunksize;
    move(abuf^,p^,tmpHeader.achunksize);
    {write packet to output stream}
    blockwrite(muxf,combinedBuf^,packetSize,numwritten);
  end;
  {before we free up the buffer, we execute the code we just wrote
  to check for correctness and update the screen}
  asm
    call combinedBuf
  end;
  if (screenmode=6) and egaPreview then checkEgaReadback;
  freemem(combinedBuf,maxEncBufSize*2);
  {update packet index}
  packetIndex^[numEncodedFrames-1]:=packetSize div secSize; {/512}
  {update stats}
  inc(totalEncodedBytes,opcodebufsize+databufsize);
end;

procedure ParseInputScript;

var
  foundKeyPair:boolean;
  bp:^byte;
  w:word;
  b:byte;
  l:longint;
  inscript:text;
  temps,readname,key,value:string;
  outf:file;
  originalBytes:longint;
  percentRemaining:real;
  fname:string;
  oldDCount:word;
  frameCnt:word;
  inFrames:boolean;

begin
  originalbytes:=$FFFFFF;
  frameCnt:=0;
  stdout('Parsing input script '+paramstr(1));
  stdout('Assuming encoding fps of '+realtostr(encodeFPS)+' which grants '
    +realtostr(cyclesperframe)+' cycles per frame');
  assign(inscript,paramstr(1));
  reset(inscript);
  inFrames:=false;
  while not EOF(inscript) do begin
    if not inframes or (drift>=1)
      then readln(inscript,temps);
    {audio drift handling:  Don't read a new frame if we need to duplicate one}
    if inframes and (drift<1)
      then if (trunc(drift*frameCnt)=frameCnt-1)
        then
          readln(inscript,temps)
        else begin
          frameCnt:=0;
          stdout('Duplicating frame to maintain video/audio sync');
        end;
    {if starts with comment, or space, or is blank, skip it}
    if (temps[1]='#') or (temps[1]=#32) or (temps='') then continue;
    {is there a value in the string?}
    b:=pos('=',temps);
    if b<>0 then begin
      foundKeyPair:=false;
      {process key/value pairs}
      temps:=upstring(temps);
      Key:=Copy(temps,1,b-1);
      Value:=Copy(temps,b+1,length(temps));
      if key='SOURCEFPS' then begin
        foundKeyPair:=true;
        sourcefps:=strtoreal(value);
        {Until sourcefps is defined, we assump 59.94.  Now that it is defined,
        we adjust our cycle pool to match.}
        CyclesPerFrame:=(CyclesPerFrame * defaultFPS) / sourcefps;
        stdout('Setting encoding fps of '+realtostr(sourcefps)+' which grants '
          +realtostr(cyclesperframe)+' cycles per frame');
      end;
      if key='OVERRIDEBYTEPOOL' then begin
        foundKeyPair:=true;
        maxVChunk:=strtoint(value);
      end;
      if key='CHEATING' then begin
        cheating:=(value='ON');
        foundKeyPair:=true;
      end;
      if key='OVERRIDECYCLES' then begin
        if value='MAX' then begin
          foundKeyPair:=true;
          cyclesPerFrame:=totalCyclesPerFrame;
          stdout('cycles per frame overridden to '+realtostr(cyclesperframe));
        end;
        if value='COMPLETE' then begin
          foundKeyPair:=true;
          cyclesPerFrame:=8192*REPMOVSWcycleCost;
          stdout('cycles per frame overridden to '+realtostr(cyclesperframe));
        end;
      end;
      if key='WAVEINPUT' then begin
        foundKeyPair:=true;
        muxing:=true;
        if fileexists(value)
          then stdout('Using '+value+' for audio input; muxing full video+audio file')
          else fatalerr(value+' not found');
        fname:=basename(paramstr(1))+'.xdv';
        assign(muxf,fname); rewrite(muxf,1);
        assign(wavf,value); reset(wavf,1);
        {build a header}
        with tmpHeader do begin
          fillchar(filler,sizeof(filler),0);
          signature[0]:='X'; signature[1]:='D'; signature[2]:='C'; signature[3]:='V';
          vidmode:=screenmode;
          numbcols:=screenbytewidth; numprows:=screenbyteheight; features:=0;
        end;
        {this is SUPERLAME and we will replace with a real WAV reader someday}
        seek(wavf,24);
        blockread(wavf,tmpHeader.samplerate,2);
        if debug<>0 then stdout('Audio samplerate: '+inttostr(tmpHeader.samplerate)+' Hz');
        seek(wavf,44);
        {calc chunk size and readjust sample rate to ensure size is an integer}
        with tmpHeader do begin
          w:=samplerate;
          achunksize:=round(samplerate/sourcefps);
          samplerate:=round(achunksize*sourcefps);
          drift:=samplerate/w;
          if drift<>1 then begin
            stderr('Sample rate '+inttostr(w)+' doesn''t divide evenly into '+realtostr(sourcefps)+'fps');
            stderr('compensating with new rate of '+inttostr(samplerate)+' ('+realtostr(drift)+'x of original)');
          end;
          if drift>1 then stderr('Source frames will occasionally be dropped to maintain audio sync');
          if drift<1 then stderr('Source frames will occasionally be repeated to maintain audio sync');
        end;
        blockwrite(muxf,tmpHeader,sizeof(tmpHeader));
        getmem(abuf,tmpHeader.achunksize);
      end;
      if key='COMBINEDELTAS' then begin
        foundKeyPair:=true;
        if value='ON'
          then combineDeltas:=true
          else combineDeltas:=false;
      end;
      if key='MAXDISKRATE' then begin
        foundKeyPair:=true;
        {please excuse the shoddy logic here.  It's a combination of iterative
        coding and TP 7.0 bug worarounds.}
        if muxing then begin
          maxDiskRate:=strToInt(value);
          maxVChunk:=maxDiskRate;
          maxVChunk:=trunc(((maxVChunk * 1024) - tmpHeader.samplerate) / sourcefps);
          maxVChunk:=maxVChunk+tmpHeader.achunksize;
          if (maxVChunk and (padalign-1))<>0 then begin
            {truncate to nearest sector boundary}
            maxVChunk:=((maxVChunk-padAlign-1) OR (padAlign-1))+1;
          end;
          maxVChunk:=maxVChunk-tmpHeader.achunksize;
        end else begin
          fatalerr('MaxDiskRate given, but audio rate unknown.'#13#10'"waveinput" must exist in script before maxDiskRate.');
        end;
      end;
      if key='SHAVEPIXELS' then begin
        foundKeyPair:=true;
        if value='ON' then shavePixels:=true;
        if value='OFF' then shavePixels:=false;
        if length(value)=1 then begin
          shavePixelMinimum:=strtoint(value);
          shavePixels:=true;
        end;
      end;
      if key='SHAVEDELTAS' then begin
        foundKeyPair:=true;
        if value='ON' then shaveDeltas:=true;
        if value='OFF' then shaveDeltas:=false;
        if length(value)=1 then begin
          shaveDeltaMinimum:=strtoint(value);
          shaveDeltas:=true;
        end;
      end;
      if key='FRAMEINTEGRITY' then begin
        foundKeyPair:=true;
        frameIntegrity:=strtoint(value);
        if frameIntegrity>100 then frameIntegrity:=100;
      end;
      if key='PAUSE' then begin
        foundKeyPair:=true;
        readkeychar;
      end;
      if key='ENCODEFPS' then begin
        foundKeyPair:=true;
        encodefps:=strtoreal(value);
        CyclesPerFrame:=(CyclesPerFrame * defaultFPS) / encodefps;
        stdout('Assuming encoding fps of '+realtostr(encodeFPS)+' which grants '
          +realtostr(cyclesperframe)+' cycles per frame');
      end;
      if key='SCREENMODE' then begin
        {1=160x200x16  2=640x200x2  3=Tandy  5=160x100x16 RGBI
         6=EGA 320x200x16 planar}
        if (value='6') or (value='320X200') then begin
          foundKeyPair:=true;
          useEgaFrameBuffers;
          screenmode:=6;
          screenbytewidth:=40;
          screenbyteheight:=200;
          pixelBitDepth:=1;
          if resolvedAdapter>=2 then begin
            xdc_setvid(screenmode);
            egaPreview:=true;
          end else begin
            egaPreview:=false;
            stdout('No EGA/VGA detected; encoding mode 6 without switching the display.');
          end;
          with tmpHeader do begin
            vidmode:=screenmode;
            numbcols:=screenbytewidth;
            numprows:=screenbyteheight;
          end;
          if muxing then begin
            seek(muxf,0);
            blockwrite(muxf,tmpHeader,sizeof(tmpHeader),w);
            seek(muxf,filesize(muxf));
          end;
          stdout('Screen mode 6: EGA 320x200x16, four planes of 8000 bytes at A000');
        end else if (value='5') or (value='160X100') then begin
          foundKeyPair:=true;
          screenmode:=5;
          screenbytewidth:=160;
          screenbyteheight:=100;
          screenRAMsize:=16000;
          pixelBitDepth:=4;
          xdc_setvid(screenmode);
          {Video RAM is 0xDE/0x00. The previous frame must match so the
           first deltas touch only attribute bytes that are not zero.}
          asm
            push    ds
            les     di,prevframe
            cld
            mov     ax,$00DE
            mov     cx,8000
            rep     stosw
            pop     ds
          end;
          move(prevframe^,nextframe^,screenRAMsize);
          with tmpHeader do begin
            vidmode:=screenmode;
            numbcols:=screenbytewidth;
            numprows:=screenbyteheight;
          end;
          if muxing then begin
            seek(muxf,0);
            blockwrite(muxf,tmpHeader,sizeof(tmpHeader),w);
            seek(muxf,filesize(muxf));
          end;
        end else if value[1] in ['1'..'4'] then begin
          foundKeyPair:=true;
          screenmode:=strtoint(value[1]);
          xdc_setvid(screenmode);
          if screenmode in [1,3] then pixelBitDepth:=4;
        end;
      end;
      if key='DEBUG' then begin
        foundKeyPair:=true;
        if length(value)=1
          then debug:=strtoint(value)
          else foundKeyPair:=false;
      end;
      if not foundKeyPair then stderr('invalid line :'+temps);
      continue;
    end;

    {if we got here, then the line must contain an input frame}
    {but first, let's check for audio drift and handle it}
    if trunc(drift*frameCnt)<>frameCnt
      then if drift>1
        then begin
          frameCnt:=0;
          stdout('Dropping frame to maintain video/audio sync');
          continue; {drop the frame; load next frame from script}
        end;

    inc(frameCnt);
    readname:=upstring(temps);
    stdout('Processing '+readname+'; '+inttostr(memavail)+' bytes free');
    inframes:=true;
    {if we're out of deltas to encode, or we are forcing a particular
    type of optimization, load a new frame}
    if originalbytes=0
      then percentRemaining:=0
      else percentRemaining:=deltas^.GetSize/originalBytes*100;
    if (deltas^.Count=0)
    or (100-percentRemaining>=frameIntegrity)
    then begin
      {clear out the delta list if necessary}
      if deltas^.Count<>0 then deltas^.FreeAll;
      {load new frame}
      if (readname<>'RANDOM') or (readname<>'PAUSE')
        then loadbmp(readname)
        else begin
          bp:=nextframe;
          for w:=0 to screenRAMsize-1 do begin
            bp^:=(w AND $ff) OR 1;
            inc(word(bp));
          end;
        end;
      if cheating then fillchar(nextframe^,8000,0);
      {determine differences between new frame and previous frame}
      findDeltas;
      {if there were any differences, optimize them}
      if debug>3 then deltas^.dumpAll;
      if deltas^.count<>0 then optimizeDeltas;
      if debug>2 then deltas^.dumpAll;
      inc(numUniqueFrames);
    end;
    originalBytes:=deltas^.GetSize;
    oldDCount:=deltas^.count;
    encodeDeltas;
    saveDeltas(basename(readname)+'.xdc');
    {execute what we just encoded to CGA RAM}
    {executeDeltas; actually this is handled by saveDeltas}
    {save resulting frame for next comparison iteration}
    if screenmode<>6 then move(CGARAM^,prevFrame^,screenRAMSize);
    {logic error detection:  If we had N deltas before encoding+saving, and
    for some reason still have N deltas afterwards, then the delta list
    is invalid and we must do something about it.
    This should never occur, but some edge cases where the bitrate is set
    way too low can create "oversize" deltas during the optimization
    combination phase, where a delta is too large for the remaining cycle pool.
    The quickest way to deal with this is to subdivide our deltas.}
    if (oldDCount=deltas^.count) and (oldDCount<>0) then begin
      stderr('Delta list of size '+inttostr(oldDCount)+' contains only invalid deltas:');
      deltas^.dumpAll;
      stderr('Subdividing '+inttostr(deltas^.count)+' deltas to compensate...');
      deltas^.splitAll;
      stderr('Delta list now contains '+inttostr(deltas^.count)+' deltas:');
      deltas^.dumpAll;
    end;
    if keypressed then if readkeychar=#27 then break;
    if numEncodedFrames>=maxbuf-1 then begin
      stderr('File format only supports 65535 frames; finishing encoding');
      break;
    end;
  end;
  close(inscript);
end;

begin
  initCompiler;
  parseInputScript;
  doneCompiler;
end.
