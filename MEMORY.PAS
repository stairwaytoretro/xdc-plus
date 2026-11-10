unit memory;
{Real-mode MemAllocSeg, the one routine XDC_COMP takes from Turbo Vision.

The returned block is paragraph aligned (offset 0) and exactly `size`
bytes, rounded up to a multiple of 8, so the compiler's FreeMem calls
match. Turbo Pascal's heap hands out 8-byte-aligned blocks, so the
offset within a paragraph is 0 or 8.
}

interface

function memAllocSeg(size: word): pointer;

implementation

function memAllocSeg(size: word): pointer;
var
  p, t: pointer;
  slack: word;
begin
  memAllocSeg := nil;
  if longint(size) + 8 > 65535 then exit;
  if longint(size) + 8 > maxavail then exit;
  getmem(p, size + 8);
  if p = nil then exit;
  if ofs(p^) = 0 then begin
    {Drop the 8 unused bytes at the end of the block.}
    slack := size and 15;
    t := ptr(seg(p^) + (size shr 4), slack);
    freemem(t, 8);
  end else begin
    {Drop the 8 bytes before the next paragraph.}
    t := p;
    p := ptr(seg(p^) + 1, 0);
    freemem(t, 8);
  end;
  memAllocSeg := p;
end;

end.
