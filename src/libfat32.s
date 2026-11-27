; FAT32 file system for the sdcard6502 SD card driver (libsd.s).
;
; Files and directories by path, several open at once, on a FAT32 volume
; (an MBR partition of type $0B or $0C, or a whole card without a
; partition table).  Names are 8.3, matched without regard to case; long
; file names written by other systems are skipped (a file is reached by
; its short name), and removed along with their entry.
;
; The caller provides fat32_workspace, a page-aligned 512-byte buffer (the
; sector cache), and links the ZEROPAGE and BSS segments.
;
; Calling convention
; ------------------
; Every routine returns C=0 on success, or C=1 with an error code in A
; (and fat32_error).  Arguments are in these variables:
;   fat32_ptr1, fat32_ptr2  (zero page) path, buffer or second path
;   fat32_len               (2 bytes) byte count for read and write
;   fat32_pos               (4 bytes) position for seek; result of free
; A file or directory handle is a FAT32_FILESIZE-byte block of the
; caller's memory, passed with its address in A (low) and X (high).  The
; position (FAT32_F_POS) and size (FAT32_F_SIZE) in it may be read.
;
;   fat32_init      mount the volume (after sd_init)
;   fat32_open      A/X handle, ptr1 path, Y mode (FAT32_READ etc.)
;   fat32_read      A/X handle, ptr1 buffer, len max -> len bytes read
;                   (0 at the end of the file)
;   fat32_write     A/X handle, ptr1 buffer, len -> len bytes written
;   fat32_seek      A/X handle, pos (no further than the end)
;   fat32_close     A/X handle: update the directory entry, sync
;   fat32_delete    ptr1 path (a file)
;   fat32_rename    ptr1 old path, ptr2 new path (may be in another
;                   directory; directories may be moved too)
;   fat32_mkdir     ptr1 path
;   fat32_rmdir     ptr1 path (must be empty)
;   fat32_opendir   A/X handle, ptr1 path ("" or "/" for the root)
;   fat32_readdir   A/X handle, ptr1 32-byte buffer: the next entry, in
;                   FAT layout; C=1 with A=0 at the end.  Skips deleted,
;                   long-name, volume-label, "." and ".." entries.
;   fat32_stat      ptr1 path, ptr2 32-byte buffer: the entry
;   fat32_free      -> pos: the number of free clusters
;   fat32_sync      write out cached data and the free-space information
;
; fat32_date and fat32_time (FAT format) stamp new and modified entries;
; fat32_init sets 1 January 1980.  fat32_sectorspercluster gives the
; cluster size.
;
; Data written to a file is in the cache until another sector is needed,
; the file is closed, or fat32_sync is called.

.macpack longbranch

FAT32_READ      = $01           ; open modes
FAT32_WRITE     = $02
FAT32_CREATE    = $04           ; create the file if it is missing
FAT32_TRUNC     = $08           ; empty an existing file
FAT32_APPEND    = $10           ; start at the end
FAT32_EXCL      = $20           ; fail if the file exists

FAT32_ERR_IO       = 1          ; the card failed
FAT32_ERR_NOTFOUND = 2
FAT32_ERR_EXISTS   = 3
FAT32_ERR_FULL     = 4
FAT32_ERR_NOTEMPTY = 5
FAT32_ERR_BADNAME  = 6
FAT32_ERR_ISDIR    = 7
FAT32_ERR_NOTDIR   = 8
FAT32_ERR_ACCESS   = 9          ; not open for that, read-only, root, ...
FAT32_ERR_RANGE    = 10         ; seek past the end
FAT32_ERR_BADFS    = 11         ; no FAT32 volume

; Handle layout
FAT32_F_FLAGS   = 0             ; FAT32_FL_* below
FAT32_F_FIRST   = 1             ; first cluster (0: none yet)
FAT32_F_SIZE    = 5             ; size in bytes
FAT32_F_POS     = 9             ; position
FAT32_F_CUR     = 13            ; the cluster of chain index CIDX
FAT32_F_CIDX    = 17            ; chain index of CUR
FAT32_F_DSEC    = 21            ; sector of the directory entry
FAT32_F_DIDX    = 25            ; entry index (0-15) in that sector
FAT32_F_RUN     = 26            ; the chain goes CUR, CUR+1, ... RUN
FAT32_FILESIZE  = 30

FAT32_FL_READ   = $01
FAT32_FL_WRITE  = $02
FAT32_FL_DIR    = $08
FAT32_FL_DIRTY  = $40           ; directory entry needs updating
FAT32_FL_OPEN   = $80

; Cache flags
CF_VALID = $80
CF_DIRTY = $40
CF_FAT   = $20                  ; a FAT sector: mirror it when written

.pushseg
.segment "ZEROPAGE"
fat32_ptr1:     .res 2
fat32_ptr2:     .res 2
fat32_cp:       .res 2          ; pointer into the cache
fat32_fp:       .res 2          ; the caller's handle
.segment "BSS"
; Volume
fat32_fatstart:         .res 4
fat32_datastart:        .res 4
fat32_rootcluster:      .res 4
fat32_sectorsperfat:    .res 4
fat32_maxcluster:       .res 4  ; one past the last cluster
fat32_nextfree:         .res 4  ; the search for free clusters starts after this
fat32_freecount:        .res 4
fat32_fsinfo:           .res 4  ; FSInfo sector, 0 if none
fat32_sectorspercluster: .res 1
fat32_spcshift:         .res 1  ; log2 of that
fat32_spcmask:          .res 1  ; that - 1
fat32_numfats:          .res 1
fat32_fsflags:          .res 1  ; $80 freecount known, $40 FSInfo needs writing
; Cache
fat32_csec:             .res 4
fat32_cflags:           .res 1
; Arguments and results
fat32_len:              .res 2
fat32_pos:              .res 4
fat32_error:            .res 1
fat32_date:             .res 2
fat32_time:             .res 2
; Working storage
fat32_sec:              .res 4
fat32_cl:               .res 4
fat32_val:              .res 4
fat32_tmp:              .res 4
fat32_need:             .res 4
fat32_prev:             .res 4
fat32_count:            .res 2
fat32_mode:             .res 1
fat32_x:                .res 1
fat32_wr:               .res 1
fat32_chunk:            .res 1
fat32_py:               .res 1
fat32_name:             .res 11
fat32_name2:            .res 11
fat32_ent:              .res 32
fat32_ent2:             .res 32
fat32_dcl:              .res 4  ; the directory being searched
fat32_esec:             .res 4  ; where the last entry read is
fat32_eidx:             .res 1
fat32_epos:             .res 4  ; position of the entry found
fat32_lfnpos:           .res 4  ; start of the long-name run before it
fat32_lfnok:            .res 1
fat32_slotpos:          .res 4  ; first free entry seen
fat32_slotok:           .res 1
fat32_endpos:           .res 4  ; end of the directory's chain
fat32_rootself:         .res 1  ; the path names the root
fat32_mcl:              .res 4
fat32_odcl:             .res 4
fat32_oepos:            .res 4
fat32_olfnpos:          .res 4
fat32_olfnok:           .res 1
fat32_f:                .res FAT32_FILESIZE     ; the handle being worked on
fat32_d:                .res FAT32_FILESIZE     ; directory iterator
.popseg

DX = fat32_d - fat32_f          ; X offset of the directory iterator

; ---------------------------------------------------------------------------
; Helpers

.macro MOV4 src, dst            ; uses A, X
  .local loop
  ldx #3
loop:
  lda src,x
  sta dst,x
  dex
  bpl loop
.endmacro

.macro ZERO4 dst                ; uses A, X
  .local loop
  lda #0
  ldx #3
loop:
  sta dst,x
  dex
  bpl loop
.endmacro

.macro INC4 v
  .local done
  inc v
  bne done
  inc v+1
  bne done
  inc v+2
  bne done
  inc v+3
done:
.endmacro

.macro INC3 v
  .local done
  inc v
  bne done
  inc v+1
  bne done
  inc v+2
done:
.endmacro

; Handle fields, with X selecting fat32_f (0) or fat32_d (DX)
.macro LDF4 off, dst
  lda fat32_f+off,x
  sta dst
  lda fat32_f+off+1,x
  sta dst+1
  lda fat32_f+off+2,x
  sta dst+2
  lda fat32_f+off+3,x
  sta dst+3
.endmacro

.macro STF4 src, off
  lda src
  sta fat32_f+off,x
  lda src+1
  sta fat32_f+off+1,x
  lda src+2
  sta fat32_f+off+2,x
  lda src+3
  sta fat32_f+off+3,x
.endmacro

.macro FAIL code
  lda #code
  jmp fat32_fail
.endmacro

fat32_ok:
  lda #0
  sta fat32_error
  clc
  rts

fat32_fail:
  ; A = error code
  sta fat32_error
  sec
  rts

fat32_failed:
  ; fail with the error already in fat32_error
  lda fat32_error
  sec
  rts

.proc fat32_setbuf
  lda #<fat32_workspace
  sta zp_sd_address
  lda #>fat32_workspace
  sta zp_sd_address+1
  rts
.endproc

.proc fat32_eq4
  ; Z=1 if the 4 bytes at fat32_tmp equal those at fat32_val
  ldx #3
loop:
  lda fat32_tmp,x
  cmp fat32_val,x
  bne done
  dex
  bpl loop
  lda #0                      ; Z=1
done:
  rts
.endproc

; ---------------------------------------------------------------------------
; Sector cache

.proc fat32_cacheflush
  ; Write the cached sector if it has changed (and its FAT mirror).
  bit fat32_cflags
  bvc ok
  MOV4 fat32_csec, zp_sd_currentsector
  jsr fat32_setbuf
  jsr sd_writesector
  bcs ioerr
  lda fat32_cflags
  and #CF_FAT
  beq clean
  lda fat32_numfats
  cmp #2
  bcc clean
  clc
  ldx #0
  ldy #4
add:
  lda zp_sd_currentsector,x
  adc fat32_sectorsperfat,x
  sta zp_sd_currentsector,x
  inx
  dey
  bne add
  jsr sd_writesector
  bcs ioerr
clean:
  lda fat32_cflags
  and #<~CF_DIRTY
  sta fat32_cflags
ok:
  clc
  rts
ioerr:
  lda #0
  sta fat32_cflags
  FAIL FAT32_ERR_IO
.endproc

.proc fat32_cacheload
  ; Get sector fat32_sec into the cache.
  bit fat32_cflags
  bpl miss
  ldx #3
cmploop:
  lda fat32_sec,x
  cmp fat32_csec,x
  bne miss
  dex
  bpl cmploop
  clc
  rts
miss:
  jsr fat32_cacheflush
  bcs fail
  MOV4 fat32_sec, fat32_csec
  MOV4 fat32_sec, zp_sd_currentsector
  jsr fat32_setbuf
  jsr sd_readsector
  bcs ioerr
  lda #CF_VALID
  sta fat32_cflags
  clc
fail:
  rts
ioerr:
  lda #0
  sta fat32_cflags
  FAIL FAT32_ERR_IO
.endproc

.proc fat32_cacheclaim
  ; Take sector fat32_sec into the cache, zero-filled and not read from
  ; the card, to be overwritten.
  bit fat32_cflags
  bpl other
  ldx #3
cmploop:
  lda fat32_sec,x
  cmp fat32_csec,x
  bne other
  dex
  bpl cmploop
  bmi take
other:
  jsr fat32_cacheflush
  bcs fail
take:
  MOV4 fat32_sec, fat32_csec
  lda #0
  tay
zero:
  sta fat32_workspace,y
  sta fat32_workspace+256,y
  iny
  bne zero
  lda #CF_VALID | CF_DIRTY
  sta fat32_cflags
  clc
fail:
  rts
.endproc

.proc fat32_dirty
  lda fat32_cflags
  ora #CF_DIRTY
  sta fat32_cflags
  rts
.endproc

; ---------------------------------------------------------------------------
; FAT

.proc fat32_fatentry
  ; Load the FAT sector for cluster fat32_cl and point fat32_cp at its
  ; entry.
  lda fat32_cl                ; FAT sector = fatstart + cluster / 128
  asl
  lda fat32_cl+1
  rol
  sta fat32_sec
  lda fat32_cl+2
  rol
  sta fat32_sec+1
  lda fat32_cl+3
  rol
  sta fat32_sec+2
  lda #0
  rol
  sta fat32_sec+3
  clc
  ldx #0
  ldy #4
add:
  lda fat32_sec,x
  adc fat32_fatstart,x
  sta fat32_sec,x
  inx
  dey
  bne add
  jsr fat32_cacheload
  bcs fail
  lda fat32_cflags
  ora #CF_FAT
  sta fat32_cflags
  lda fat32_cl                ; offset = (cluster & 127) * 4
  asl
  asl                         ; C = bit 6: the second half
  sta fat32_cp
  lda #>fat32_workspace
  adc #0
  sta fat32_cp+1
  clc
fail:
  rts
.endproc

.proc fat32_fatget
  ; fat32_val = the FAT entry of cluster fat32_cl
  jsr fat32_fatentry
  bcs fail
  ldy #3
  lda (fat32_cp),y
  and #$0f
  sta fat32_val+3
  dey
loop:
  lda (fat32_cp),y
  sta fat32_val,y
  dey
  bpl loop
  clc
fail:
  rts
.endproc

.proc fat32_fatset
  ; Set the FAT entry of cluster fat32_cl to fat32_val (keeping the top
  ; four reserved bits).
  jsr fat32_fatentry
  bcs fail
  ldy #0
  lda fat32_val
  sta (fat32_cp),y
  iny
  lda fat32_val+1
  sta (fat32_cp),y
  iny
  lda fat32_val+2
  sta (fat32_cp),y
  iny
  lda (fat32_cp),y
  and #$f0
  ora fat32_val+3
  sta (fat32_cp),y
  jsr fat32_dirty
  clc
fail:
  rts
.endproc

.proc fat32_isvalid
  ; C=0 if fat32_val is a cluster number on the volume (2 to max-1):
  ; not free, end of chain or bad.
  lda fat32_val+3
  ora fat32_val+2
  ora fat32_val+1
  bne high
  lda fat32_val
  cmp #2
  bcc bad
high:
  lda fat32_val
  cmp fat32_maxcluster
  lda fat32_val+1
  sbc fat32_maxcluster+1
  lda fat32_val+2
  sbc fat32_maxcluster+2
  lda fat32_val+3
  sbc fat32_maxcluster+3
  bcs bad
  clc
  rts
bad:
  sec
  rts
.endproc

.proc fat32_alloc
  ; Find a free cluster after fat32_nextfree (going round the volume once)
  ; and mark it as the end of a chain: fat32_cl.
  MOV4 fat32_nextfree, fat32_tmp
  MOV4 fat32_nextfree, fat32_cl
loop:
  INC4 fat32_cl
  ldx #3
wrap:
  lda fat32_cl,x
  cmp fat32_maxcluster,x
  bne nowrap
  dex
  bpl wrap
  lda #2
  sta fat32_cl
  lda #0
  sta fat32_cl+1
  sta fat32_cl+2
  sta fat32_cl+3
nowrap:
  ldx #3
start:
  lda fat32_cl,x
  cmp fat32_tmp,x
  bne check
  dex
  bpl start
  FAIL FAT32_ERR_FULL         ; all the way round
check:
  jsr fat32_fatget
  bcs fail
  lda fat32_val
  ora fat32_val+1
  ora fat32_val+2
  ora fat32_val+3
  bne loop
  lda #$ff                    ; end of chain
  sta fat32_val
  sta fat32_val+1
  sta fat32_val+2
  lda #$0f
  sta fat32_val+3
  jsr fat32_fatset
  bcs fail
  MOV4 fat32_cl, fat32_nextfree
  bit fat32_fsflags
  bpl :+
  lda fat32_freecount         ; one less free
  bne dec0
  lda fat32_freecount+1
  bne dec1
  lda fat32_freecount+2
  bne dec2
  dec fat32_freecount+3
dec2:
  dec fat32_freecount+2
dec1:
  dec fat32_freecount+1
dec0:
  dec fat32_freecount
:
  lda fat32_fsflags
  ora #$40
  sta fat32_fsflags
  clc
fail:
  rts
.endproc

.proc fat32_freechain
  ; Free the cluster chain starting at fat32_cl (which may be 0).
loop:
  MOV4 fat32_cl, fat32_val
  jsr fat32_isvalid
  bcs done
  jsr fat32_fatget
  bcs fail
  MOV4 fat32_val, fat32_tmp   ; the next one
  ZERO4 fat32_val
  jsr fat32_fatset
  bcs fail
  bit fat32_fsflags
  bpl :+
  INC4 fat32_freecount
:
  lda fat32_fsflags
  ora #$40
  sta fat32_fsflags
  MOV4 fat32_tmp, fat32_cl
  jmp loop
done:
  clc
fail:
  rts
.endproc

.proc fat32_clsector
  ; fat32_sec = the first sector of cluster fat32_cl
  sec
  lda fat32_cl
  sbc #2
  sta fat32_sec
  lda fat32_cl+1
  sbc #0
  sta fat32_sec+1
  lda fat32_cl+2
  sbc #0
  sta fat32_sec+2
  lda fat32_cl+3
  sbc #0
  sta fat32_sec+3
  ldx fat32_spcshift
  beq add
shift:
  asl fat32_sec
  rol fat32_sec+1
  rol fat32_sec+2
  rol fat32_sec+3
  dex
  bne shift
add:
  clc
  ldx #0
  ldy #4
addloop:
  lda fat32_sec,x
  adc fat32_datastart,x
  sta fat32_sec,x
  inx
  dey
  bne addloop
  rts
.endproc

.proc fat32_zerocluster
  ; Fill cluster fat32_cl with zeros (for a new directory).
  jsr fat32_clsector
  lda fat32_sectorspercluster
  sta fat32_count
loop:
  jsr fat32_cacheclaim
  bcs fail
  jsr fat32_cacheflush
  bcs fail
  INC4 fat32_sec
  dec fat32_count
  bne loop
  clc
fail:
  rts
.endproc

; ---------------------------------------------------------------------------
; Positions in a cluster chain.  X selects the handle: 0 for fat32_f, DX
; for fat32_d.  fat32_wr=1 lets the chain grow.

.proc fat32_prepare
  ; Set fat32_sec to the sector holding position FAT32_F_POS, following
  ; the chain (and growing it if fat32_wr is set).  C=1 with error 0 at
  ; the end of the chain, or another error.  X is preserved.
  stx fat32_x
  lda fat32_f+FAT32_F_FIRST,x
  ora fat32_f+FAT32_F_FIRST+1,x
  ora fat32_f+FAT32_F_FIRST+2,x
  ora fat32_f+FAT32_F_FIRST+3,x
  bne have
  lda fat32_wr
  jeq eof
  jsr fat32_alloc             ; a file's first cluster
  jcs fail
  ldx fat32_x
  STF4 fat32_cl, FAT32_F_FIRST
  STF4 fat32_cl, FAT32_F_CUR
  STF4 fat32_cl, FAT32_F_RUN
  lda #0
  sta fat32_f+FAT32_F_CIDX,x
  sta fat32_f+FAT32_F_CIDX+1,x
  sta fat32_f+FAT32_F_CIDX+2,x
  sta fat32_f+FAT32_F_CIDX+3,x
  lda fat32_f+FAT32_F_FLAGS,x
  ora #FAT32_FL_DIRTY
  sta fat32_f+FAT32_F_FLAGS,x
have:
  ; The chain index needed: position >> (9 + log2 sectors per cluster)
  lda fat32_f+FAT32_F_POS+1,x
  sta fat32_need
  lda fat32_f+FAT32_F_POS+2,x
  sta fat32_need+1
  lda fat32_f+FAT32_F_POS+3,x
  sta fat32_need+2
  lda #0
  sta fat32_need+3
  ldy fat32_spcshift
  iny
shift:
  lsr fat32_need+2
  ror fat32_need+1
  ror fat32_need
  dey
  bne shift
  ; Behind CUR?  Then start again from the first cluster.
  lda fat32_need
  cmp fat32_f+FAT32_F_CIDX,x
  lda fat32_need+1
  sbc fat32_f+FAT32_F_CIDX+1,x
  lda fat32_need+2
  sbc fat32_f+FAT32_F_CIDX+2,x
  lda fat32_need+3
  sbc fat32_f+FAT32_F_CIDX+3,x
  bcs forward
  LDF4 FAT32_F_FIRST, fat32_cl
  STF4 fat32_cl, FAT32_F_CUR
  STF4 fat32_cl, FAT32_F_RUN
  lda #0
  sta fat32_f+FAT32_F_CIDX,x
  sta fat32_f+FAT32_F_CIDX+1,x
  sta fat32_f+FAT32_F_CIDX+2,x
  sta fat32_f+FAT32_F_CIDX+3,x
forward:
  lda fat32_need
  cmp fat32_f+FAT32_F_CIDX,x
  bne step
  lda fat32_need+1
  cmp fat32_f+FAT32_F_CIDX+1,x
  bne step
  lda fat32_need+2
  cmp fat32_f+FAT32_F_CIDX+2,x
  bne step
  lda fat32_need+3
  cmp fat32_f+FAT32_F_CIDX+3,x
  beq ready
step:
  jsr fat32_step
  bcs fail
  ldx fat32_x
  jmp forward
ready:
  LDF4 FAT32_F_CUR, fat32_cl
  jsr fat32_clsector
  ldx fat32_x
  ; plus the sector in the cluster: (position >> 9) & (spc - 1)
  lda fat32_f+FAT32_F_POS+2,x
  lsr
  lda fat32_f+FAT32_F_POS+1,x
  ror
  and fat32_spcmask
  clc
  adc fat32_sec
  sta fat32_sec
  bcc done
  INC3 fat32_sec+1
done:
  clc
  rts
eof:
  lda #0
  sta fat32_error
  sec
fail:
  ldx fat32_x
  rts
.endproc

.proc fat32_step
  ; Move CUR on to the next cluster in the chain (adding one if the chain
  ; ends and fat32_wr is set; zeroed for a directory).  Clusters known to
  ; follow on consecutively (up to RUN) need no look at the FAT.
  ldx fat32_x
  LDF4 FAT32_F_CUR, fat32_cl
  lda fat32_cl                ; CUR < RUN: the next is CUR + 1
  cmp fat32_f+FAT32_F_RUN,x
  lda fat32_cl+1
  sbc fat32_f+FAT32_F_RUN+1,x
  lda fat32_cl+2
  sbc fat32_f+FAT32_F_RUN+2,x
  lda fat32_cl+3
  sbc fat32_f+FAT32_F_RUN+3,x
  bcs lookup
  INC4 fat32_cl
  MOV4 fat32_cl, fat32_val
  jmp advance
lookup:
  jsr fat32_fatget
  jcs fail
  jsr fat32_isvalid
  bcc found
  lda fat32_wr
  jeq eof
  MOV4 fat32_cl, fat32_prev
  jsr fat32_alloc
  jcs fail
  MOV4 fat32_cl, fat32_val    ; link the old end to it
  MOV4 fat32_prev, fat32_cl
  jsr fat32_fatset
  jcs fail
  MOV4 fat32_val, fat32_cl
  ldx fat32_x
  lda fat32_f+FAT32_F_FLAGS,x
  and #FAT32_FL_DIR
  beq :+
  jsr fat32_zerocluster
  jcs fail
: MOV4 fat32_cl, fat32_val
  MOV4 fat32_cl, fat32_tmp
  jmp rundone
found:
  ; How far does the chain go on in consecutive clusters?  Look along
  ; this FAT sector: fat32_cp is at CUR's entry.  fat32_tmp = k.
  MOV4 fat32_val, fat32_tmp
  INC4 fat32_cl               ; next = CUR + 1?
  ldx #3
same:
  lda fat32_cl,x
  cmp fat32_val,x
  bne rundone
  dex
  bpl same
scan:
  lda fat32_tmp               ; k's entry is in the next FAT sector
  and #$7f
  beq rundone
  clc
  lda fat32_cp
  adc #4
  sta fat32_cp
  bcc :+
  inc fat32_cp+1
: MOV4 fat32_tmp, fat32_cl    ; is k's entry k + 1?
  INC4 fat32_cl
  ldy #0
  lda (fat32_cp),y
  cmp fat32_cl
  bne rundone
  iny
  lda (fat32_cp),y
  cmp fat32_cl+1
  bne rundone
  iny
  lda (fat32_cp),y
  cmp fat32_cl+2
  bne rundone
  iny
  lda (fat32_cp),y
  and #$0f
  cmp fat32_cl+3
  bne rundone
  MOV4 fat32_cl, fat32_tmp
  jmp scan
rundone:
  ldx fat32_x
  STF4 fat32_tmp, FAT32_F_RUN
advance:
  ldx fat32_x
  STF4 fat32_val, FAT32_F_CUR
  inc fat32_f+FAT32_F_CIDX,x
  bne done
  inc fat32_f+FAT32_F_CIDX+1,x
  bne done
  inc fat32_f+FAT32_F_CIDX+2,x
  bne done
  inc fat32_f+FAT32_F_CIDX+3,x
done:
  clc
  rts
eof:
  lda #0
  sta fat32_error
  sec
fail:
  rts
.endproc

.proc fat32_xfer
  ; Move fat32_len bytes between the buffer at fat32_ptr1 and handle
  ; fat32_f at its position: written if fat32_wr is set, else read (up to
  ; the end of the file).  fat32_len = the number of bytes moved.
  lda #0
  sta fat32_count
  sta fat32_count+1
loop:
  lda fat32_len
  ora fat32_len+1
  bne more
  jmp done
more:
  ldx #0
  lda fat32_wr
  bne prep
  ; reading: anything left?  fat32_tmp = size - position
  sec
  lda fat32_f+FAT32_F_SIZE
  sbc fat32_f+FAT32_F_POS
  sta fat32_tmp
  lda fat32_f+FAT32_F_SIZE+1
  sbc fat32_f+FAT32_F_POS+1
  sta fat32_tmp+1
  lda fat32_f+FAT32_F_SIZE+2
  sbc fat32_f+FAT32_F_POS+2
  sta fat32_tmp+2
  lda fat32_f+FAT32_F_SIZE+3
  sbc fat32_f+FAT32_F_POS+3
  sta fat32_tmp+3
  ora fat32_tmp+2
  ora fat32_tmp+1
  ora fat32_tmp
  bne prep
  jmp done
prep:
  jsr fat32_prepare
  bcc :+
  lda fat32_error
  jne fail
  jmp done                    ; end of the chain
:
  ; chunk = min(512 - offset, 256, len, [reading] left)
  lda fat32_f+FAT32_F_POS+1
  and #1
  sta fat32_val+1             ; offset in the sector, high bit
  sec
  lda #0
  sbc fat32_f+FAT32_F_POS
  sta fat32_val               ; 512 - offset ...
  lda #2
  sbc fat32_val+1
  sta fat32_val+1
  cmp #1                      ; ... at most 256
  bcc :++
  bne :+
  lda fat32_val
  beq :++
: lda #0
  sta fat32_val
  lda #1
  sta fat32_val+1
:
  lda fat32_len               ; at most len
  cmp fat32_val
  lda fat32_len+1
  sbc fat32_val+1
  bcs :+
  lda fat32_len
  sta fat32_val
  lda fat32_len+1
  sta fat32_val+1
:
  lda fat32_wr
  bne cache
  lda fat32_tmp+3             ; reading: at most what is left
  ora fat32_tmp+2
  bne cache
  lda fat32_tmp
  cmp fat32_val
  lda fat32_tmp+1
  sbc fat32_val+1
  bcs cache
  lda fat32_tmp
  sta fat32_val
  lda fat32_tmp+1
  sta fat32_val+1
cache:
  lda fat32_val
  sta fat32_chunk             ; 0 means 256
  lda fat32_wr
  beq load
  ; Writing a new sector from its start, past the end of the data?  Then
  ; there is nothing to read.
  lda fat32_f+FAT32_F_POS
  bne load
  lda fat32_f+FAT32_F_POS+1
  and #1
  bne load
  lda fat32_f+FAT32_F_POS
  cmp fat32_f+FAT32_F_SIZE
  lda fat32_f+FAT32_F_POS+1
  sbc fat32_f+FAT32_F_SIZE+1
  lda fat32_f+FAT32_F_POS+2
  sbc fat32_f+FAT32_F_SIZE+2
  lda fat32_f+FAT32_F_POS+3
  sbc fat32_f+FAT32_F_SIZE+3
  bcc load
  jsr fat32_cacheclaim
  jmp loaded
load:
  jsr fat32_cacheload
loaded:
  jcs fail
  lda fat32_f+FAT32_F_POS
  sta fat32_cp
  lda fat32_f+FAT32_F_POS+1
  and #1
  clc
  adc #>fat32_workspace
  sta fat32_cp+1
  ldy #0
  lda fat32_wr
  bne put
get:
  lda (fat32_cp),y
  sta (fat32_ptr1),y
  iny
  cpy fat32_chunk
  bne get
  beq moved
put:
  lda (fat32_ptr1),y
  sta (fat32_cp),y
  iny
  cpy fat32_chunk
  bne put
  jsr fat32_dirty
moved:
  ; position, buffer, len and count on by the chunk (fat32_val)
  clc
  lda fat32_f+FAT32_F_POS
  adc fat32_val
  sta fat32_f+FAT32_F_POS
  lda fat32_f+FAT32_F_POS+1
  adc fat32_val+1
  sta fat32_f+FAT32_F_POS+1
  bcc :+
  inc fat32_f+FAT32_F_POS+2
  bne :+
  inc fat32_f+FAT32_F_POS+3
:
  clc
  lda fat32_ptr1
  adc fat32_val
  sta fat32_ptr1
  lda fat32_ptr1+1
  adc fat32_val+1
  sta fat32_ptr1+1
  sec
  lda fat32_len
  sbc fat32_val
  sta fat32_len
  lda fat32_len+1
  sbc fat32_val+1
  sta fat32_len+1
  clc
  lda fat32_count
  adc fat32_val
  sta fat32_count
  lda fat32_count+1
  adc fat32_val+1
  sta fat32_count+1
  lda fat32_wr
  beq next
  ; written past the end: the file is longer
  lda fat32_f+FAT32_F_SIZE
  cmp fat32_f+FAT32_F_POS
  lda fat32_f+FAT32_F_SIZE+1
  sbc fat32_f+FAT32_F_POS+1
  lda fat32_f+FAT32_F_SIZE+2
  sbc fat32_f+FAT32_F_POS+2
  lda fat32_f+FAT32_F_SIZE+3
  sbc fat32_f+FAT32_F_POS+3
  bcs next
  ldx #3
grow:
  lda fat32_f+FAT32_F_POS,x
  sta fat32_f+FAT32_F_SIZE,x
  dex
  bpl grow
  lda fat32_f+FAT32_F_FLAGS
  ora #FAT32_FL_DIRTY
  sta fat32_f+FAT32_F_FLAGS
next:
  jmp loop
done:
  lda fat32_count
  sta fat32_len
  lda fat32_count+1
  sta fat32_len+1
  clc
  rts
fail:
  lda fat32_count
  sta fat32_len
  lda fat32_count+1
  sta fat32_len+1
  jmp fat32_failed
.endproc

; ---------------------------------------------------------------------------
; Directories

.proc fat32_dopen
  ; Start the iterator fat32_d at the beginning of directory fat32_dcl.
  ldx #DX
  STF4 fat32_dcl, FAT32_F_FIRST
  STF4 fat32_dcl, FAT32_F_CUR
  STF4 fat32_dcl, FAT32_F_RUN
  lda #0
  ldy #3
zloop:
  sta fat32_d+FAT32_F_CIDX,y
  sta fat32_d+FAT32_F_POS,y
  dey
  bpl zloop
  lda #FAT32_FL_OPEN | FAT32_FL_DIR | FAT32_FL_READ
  sta fat32_d+FAT32_F_FLAGS
  rts
.endproc

.proc fat32_dentry
  ; Point fat32_cp at the entry at the position of handle X (after
  ; fat32_prepare and fat32_cacheload), note where it is (fat32_esec,
  ; fat32_eidx) and move the position on by 32.
  lda fat32_f+FAT32_F_POS,x
  sta fat32_cp
  lsr
  lsr
  lsr
  lsr
  lsr
  sta fat32_eidx
  lda fat32_f+FAT32_F_POS+1,x
  and #1
  pha
  asl
  asl
  asl
  ora fat32_eidx
  sta fat32_eidx
  pla
  clc
  adc #>fat32_workspace
  sta fat32_cp+1
  ldy #3
sec4:
  lda fat32_sec,y
  sta fat32_esec,y
  dey
  bpl sec4
  clc
  lda fat32_f+FAT32_F_POS,x
  adc #32
  sta fat32_f+FAT32_F_POS,x
  bcc done
  inc fat32_f+FAT32_F_POS+1,x
  bne done
  inc fat32_f+FAT32_F_POS+2,x
  bne done
  inc fat32_f+FAT32_F_POS+3,x
done:
  rts
.endproc

.proc fat32_dnext
  ; The next entry of directory handle X: fat32_cp points at it.  C=1 at
  ; the end of the chain (error 0) or on an error.  X is preserved.
  lda #0
  sta fat32_wr
  jsr fat32_prepare
  bcs fail
  jsr fat32_cacheload
  ldx fat32_x
  bcs fail
  jsr fat32_dentry
  clc
fail:
  rts
.endproc

.proc fat32_back32
  ; fat32_tmp = position of handle X - 32 (the entry just read)
  sec
  lda fat32_f+FAT32_F_POS,x
  sbc #32
  sta fat32_tmp
  lda fat32_f+FAT32_F_POS+1,x
  sbc #0
  sta fat32_tmp+1
  lda fat32_f+FAT32_F_POS+2,x
  sbc #0
  sta fat32_tmp+2
  lda fat32_f+FAT32_F_POS+3,x
  sbc #0
  sta fat32_tmp+3
  rts
.endproc

.proc fat32_dfind
  ; Look for fat32_name in directory fat32_dcl.  Found (C=0): the entry is
  ; copied to fat32_ent, and fat32_epos, fat32_esec/eidx and the long-name
  ; run before it (fat32_lfnpos/lfnok) say where it is.  Not found (C=1,
  ; FAT32_ERR_NOTFOUND): fat32_slotpos/slotok give the first free entry,
  ; else fat32_endpos is the end of the directory.
  jsr fat32_dopen
  lda #0
  sta fat32_slotok
  sta fat32_lfnok
loop:
  ldx #DX
  jsr fat32_dnext
  bcs chainend
  ldy #0
  lda (fat32_cp),y
  beq atend
  cmp #$e5
  beq free
  ldy #11
  lda (fat32_cp),y
  cmp #$0f
  beq lfn
  and #$08                    ; a volume label
  bne other
  ldy #10
compare:
  lda (fat32_cp),y
  cmp fat32_name,y
  bne other
  dey
  bpl compare
  ldy #31                     ; found
copy:
  lda (fat32_cp),y
  sta fat32_ent,y
  dey
  bpl copy
  ldx #DX
  jsr fat32_back32
  MOV4 fat32_tmp, fat32_epos
  clc
  rts
other:
  lda #0
  sta fat32_lfnok
  jmp loop
lfn:
  lda fat32_lfnok
  bne loop
  ldx #DX
  jsr fat32_back32
  MOV4 fat32_tmp, fat32_lfnpos
  lda #1
  sta fat32_lfnok
  jmp loop
free:
  lda #0
  sta fat32_lfnok
  jsr slot
  jmp loop
atend:
  jsr slot
  jmp notfound
chainend:
  lda fat32_error
  beq :+
  jmp fat32_failed
: MOV4 fat32_d+FAT32_F_POS, fat32_endpos
notfound:
  FAIL FAT32_ERR_NOTFOUND
slot:
  lda fat32_slotok
  bne :+
  ldx #DX
  jsr fat32_back32
  MOV4 fat32_tmp, fat32_slotpos
  lda #1
  sta fat32_slotok
: rts
.endproc

.proc fat32_dseek
  ; Set the iterator's position to fat32_tmp.
  ldx #3
loop:
  lda fat32_tmp,x
  sta fat32_d+FAT32_F_POS,x
  dex
  bpl loop
  rts
.endproc

.proc fat32_dcreate
  ; After fat32_dfind failed in fat32_dcl: write fat32_ent into the free
  ; entry it found, or a new one at the end (growing the directory).
  ; fat32_esec/eidx say where it went.
  MOV4 fat32_endpos, fat32_tmp
  lda fat32_slotok
  beq :+
  MOV4 fat32_slotpos, fat32_tmp
: jsr fat32_dseek
  lda #1
  sta fat32_wr
  ldx #DX
  jsr fat32_prepare
  bcs fail
  jsr fat32_cacheload
  bcs fail
  ldx #DX
  jsr fat32_dentry
  ldy #31
copy:
  lda fat32_ent,y
  sta (fat32_cp),y
  dey
  bpl copy
  jsr fat32_dirty
  clc
fail:
  rts
.endproc

.proc fat32_dremove
  ; Mark the entry at fat32_epos in fat32_dcl deleted, with the long-name
  ; run before it.
  jsr fat32_dopen
  MOV4 fat32_epos, fat32_tmp
  lda fat32_lfnok
  beq :+
  MOV4 fat32_lfnpos, fat32_tmp
: jsr fat32_dseek
loop:
  ldx #DX
  jsr fat32_dnext
  bcs fail
  ldy #0
  lda #$e5
  sta (fat32_cp),y
  jsr fat32_dirty
  ldx #DX
  jsr fat32_back32
  MOV4 fat32_epos, fat32_val
  jsr fat32_eq4
  bne loop
  clc
  rts
fail:
  lda fat32_error
  bne :+
  lda #FAT32_ERR_IO           ; the entry has gone
: jmp fat32_fail
.endproc

.proc fat32_entcluster
  ; fat32_cl = the first cluster in entry fat32_ent, the root for 0 (as
  ; ".." uses).
  lda fat32_ent+26
  sta fat32_cl
  lda fat32_ent+27
  sta fat32_cl+1
  lda fat32_ent+20
  sta fat32_cl+2
  lda fat32_ent+21
  and #$0f
  sta fat32_cl+3
  ora fat32_cl+2
  ora fat32_cl+1
  ora fat32_cl
  bne done
  MOV4 fat32_rootcluster, fat32_cl
done:
  rts
.endproc

.proc fat32_setentcluster
  ; Store fat32_cl in fat32_ent, as 0 for the root (as ".." does).
  ldx #3
cmploop:
  lda fat32_cl,x
  cmp fat32_rootcluster,x
  bne store
  dex
  bpl cmploop
  lda #0
  sta fat32_ent+26
  sta fat32_ent+27
  sta fat32_ent+20
  sta fat32_ent+21
  rts
store:
  lda fat32_cl
  sta fat32_ent+26
  lda fat32_cl+1
  sta fat32_ent+27
  lda fat32_cl+2
  sta fat32_ent+20
  lda fat32_cl+3
  sta fat32_ent+21
  rts
.endproc

.proc fat32_mkent
  ; Fill fat32_ent: name fat32_name, attributes A, first cluster fat32_cl,
  ; size 0, stamped with fat32_date/time.
  pha
  ldy #31
  lda #0
zloop:
  sta fat32_ent,y
  dey
  bpl zloop
  ldy #10
name:
  lda fat32_name,y
  sta fat32_ent,y
  dey
  bpl name
  pla
  sta fat32_ent+11
  jsr fat32_setentcluster
  ; fall through
.endproc
.proc fat32_stamp
  ; Creation, access and modification times in fat32_ent.
  lda fat32_time
  sta fat32_ent+14
  sta fat32_ent+22
  lda fat32_time+1
  sta fat32_ent+15
  sta fat32_ent+23
  lda fat32_date
  sta fat32_ent+16
  sta fat32_ent+18
  sta fat32_ent+24
  lda fat32_date+1
  sta fat32_ent+17
  sta fat32_ent+19
  sta fat32_ent+25
  rts
.endproc

; ---------------------------------------------------------------------------
; Paths

.proc fat32_isend
  ; Z=1 if A ends a path component ('/' or 0)
  cmp #0
  beq done
  cmp #'/'
done:
  rts
.endproc

.proc fat32_validch
  ; A as a short-name character (lower case made upper); C=1 if it is not
  ; allowed.
  cmp #'a'
  bcc notlower
  cmp #'z'+1
  bcs notlower
  and #$df
notlower:
  cmp #$21
  bcc bad
  cmp #$7f
  beq bad
  ldx #badchars_end - badchars - 1
loop:
  cmp badchars,x
  beq bad
  dex
  bpl loop
  clc
  rts
bad:
  sec
  rts
badchars:
  .byte $22, "*+,./:;<=>?[", $5c, "]|"
badchars_end:
.endproc

.proc fat32_name83
  ; Convert the path component at (fat32_ptr1),y to fat32_name (11
  ; characters, space padded).  Y is left at the '/' or 0 after it.
  lda #' '
  ldx #10
fill:
  sta fat32_name,x
  dex
  bpl fill
  lda (fat32_ptr1),y
  cmp #'.'
  bne base
  sta fat32_name              ; "." or ".."
  iny
  lda (fat32_ptr1),y
  jsr fat32_isend
  beq ok
  cmp #'.'
  bne bad
  sta fat32_name+1
  iny
  lda (fat32_ptr1),y
  jsr fat32_isend
  beq ok
  bne bad
base:
  ldx #0
baseloop:
  lda (fat32_ptr1),y
  jsr fat32_isend
  beq endbase
  cmp #'.'
  beq ext
  stx fat32_x
  jsr fat32_validch
  ldx fat32_x
  bcs bad
  cpx #8
  bcs bad
  sta fat32_name,x
  inx
  iny
  bne baseloop
ext:
  cpx #0
  beq bad
  iny
  ldx #8
extloop:
  lda (fat32_ptr1),y
  jsr fat32_isend
  beq ok
  stx fat32_x
  jsr fat32_validch
  ldx fat32_x
  bcs bad
  cpx #11
  bcs bad
  sta fat32_name,x
  inx
  iny
  bne extloop
endbase:
  cpx #0
  beq bad
ok:
  lda fat32_name              ; a first byte of $E5 is stored as $05
  cmp #$e5
  bne :+
  lda #$05
  sta fat32_name
: clc
  rts
bad:
  FAIL FAT32_ERR_BADNAME
.endproc

.proc fat32_skipslash
  lda (fat32_ptr1),y
  cmp #'/'
  bne done
  iny
  bne fat32_skipslash
done:
  rts
.endproc

.proc fat32_dclroot
  ; Z=1 if fat32_dcl is the root directory
  ldx #3
loop:
  lda fat32_dcl,x
  cmp fat32_rootcluster,x
  bne done
  dex
  bpl loop
  lda #0                      ; Z=1
done:
  rts
.endproc

.proc fat32_walk
  ; Follow the path at fat32_ptr1: fat32_dcl is the directory holding its
  ; last component, fat32_name.  fat32_rootself=1 if the path names the
  ; root itself ("", "/", ".", "..").
  MOV4 fat32_rootcluster, fat32_dcl
  lda #0
  sta fat32_rootself
  ldy #0
  jsr fat32_skipslash
  lda (fat32_ptr1),y
  bne component
  inc fat32_rootself
  clc
  rts
component:
  jsr fat32_name83
  bcs fail
  jsr fat32_skipslash
  lda (fat32_ptr1),y
  beq last
  sty fat32_py
  jsr descend
  bcs fail
  ldy fat32_py
  jmp component
last:
  lda fat32_name
  cmp #'.'
  bne ok
  jsr fat32_dclroot
  bne ok
  inc fat32_rootself          ; "." or ".." in the root
ok:
  clc
fail:
  rts
descend:
  ; Into the directory fat32_name in fat32_dcl.
  lda fat32_name
  cmp #'.'
  bne find
  jsr fat32_dclroot
  bne find
  clc                         ; "." and ".." in the root: the root
  rts
find:
  jsr fat32_dfind
  bcs dfail
  lda fat32_ent+11
  and #$10
  bne isdir
  FAIL FAT32_ERR_NOTDIR
isdir:
  jsr fat32_entcluster
  MOV4 fat32_cl, fat32_dcl
  clc
dfail:
  rts
.endproc

.proc fat32_lookup
  ; Walk fat32_ptr1 and find it: C=0 with the entry in fat32_ent.  The
  ; root itself is FAT32_ERR_ACCESS.
  jsr fat32_walk
  bcs fail
  lda fat32_rootself
  beq :+
  FAIL FAT32_ERR_ACCESS
: jmp fat32_dfind
fail:
  rts
.endproc

; ---------------------------------------------------------------------------
; Handles

.proc fat32_load
  ; Copy the caller's handle at A/X to fat32_f.
  sta fat32_fp
  stx fat32_fp+1
  ldy #FAT32_FILESIZE-1
loop:
  lda (fat32_fp),y
  sta fat32_f,y
  dey
  bpl loop
  rts
.endproc

.proc fat32_save
  ; Copy fat32_f back to the caller's handle.
  ldy #FAT32_FILESIZE-1
loop:
  lda fat32_f,y
  sta (fat32_fp),y
  dey
  bpl loop
  rts
.endproc

.proc fat32_setloc
  ; The handle's directory entry is at fat32_esec/eidx.
  ldx #3
loop:
  lda fat32_esec,x
  sta fat32_f+FAT32_F_DSEC,x
  dex
  bpl loop
  lda fat32_eidx
  sta fat32_f+FAT32_F_DIDX
  rts
.endproc

.proc fat32_setstart
  ; CUR = FIRST, chain index 0
  ldx #3
loop:
  lda fat32_f+FAT32_F_FIRST,x
  sta fat32_f+FAT32_F_CUR,x
  sta fat32_f+FAT32_F_RUN,x
  lda #0
  sta fat32_f+FAT32_F_CIDX,x
  dex
  bpl loop
  rts
.endproc

; ---------------------------------------------------------------------------
; Mounting

.proc fat32_init
  ; Mount the FAT32 volume on the card.
  lda #0
  sta fat32_cflags
  sta fat32_fsflags
  sta fat32_time
  sta fat32_time+1
  lda #$21                    ; 1 January 1980
  sta fat32_date
  lda #0
  sta fat32_date+1
  ZERO4 fat32_sec             ; the MBR
  jsr fat32_cacheload
  bcc :+
  rts
:
  lda fat32_workspace+510
  cmp #$55
  bne badfs
  lda fat32_workspace+511
  cmp #$aa
  bne badfs
  ; A FAT32 partition, type $0C (LBA) or $0B (CHS; the start is an LBA
  ; either way)?
  ldx #0
part:
  lda fat32_workspace+$1c2,x
  cmp #$0c
  beq found
  cmp #$0b
  beq found
  txa
  clc
  adc #16
  tax
  cmp #64
  bne part
  ; No: is the whole card a FAT32 volume (no partition table)?
  ldx #4
sig:
  lda fat32_workspace+82,x
  cmp fat32sig,x
  bne badfs
  dex
  bpl sig
  ZERO4 fat32_tmp
  jmp bpb
badfs:
  FAIL FAT32_ERR_BADFS
found:
  lda fat32_workspace+$1c6,x
  sta fat32_tmp
  lda fat32_workspace+$1c7,x
  sta fat32_tmp+1
  lda fat32_workspace+$1c8,x
  sta fat32_tmp+2
  lda fat32_workspace+$1c9,x
  sta fat32_tmp+3
  MOV4 fat32_tmp, fat32_sec
  jsr fat32_cacheload
  bcc bpb
  rts
bpb:
  ; fat32_tmp = the volume's first sector; the boot sector is cached.
  lda fat32_workspace+510
  cmp #$55
  bne badfs
  lda fat32_workspace+511
  cmp #$aa
  bne badfs
  lda fat32_workspace+11      ; 512 bytes per sector
  bne badfs
  lda fat32_workspace+12
  cmp #2
  bne badfs
  lda fat32_workspace+17      ; no fixed root directory (FAT32)
  ora fat32_workspace+18
  ora fat32_workspace+19      ; no 16-bit sector count
  ora fat32_workspace+20
  ora fat32_workspace+22      ; no 16-bit FAT size
  ora fat32_workspace+23
  bne badfs
  lda fat32_workspace+16      ; one or two FATs
  sta fat32_numfats
  beq badfs
  cmp #3
  bcs badfs
  ; sectors per cluster: a power of two
  lda fat32_workspace+13
  sta fat32_sectorspercluster
  beq badfs
  ldx #0
log:
  lsr
  bcs logdone
  inx
  bne log
logdone:
  bne badfs                   ; another bit was set
  stx fat32_spcshift
  ldx fat32_sectorspercluster
  dex
  stx fat32_spcmask
  ; FAT start = volume start + reserved sectors
  clc
  lda fat32_tmp
  adc fat32_workspace+14
  sta fat32_fatstart
  lda fat32_tmp+1
  adc fat32_workspace+15
  sta fat32_fatstart+1
  lda fat32_tmp+2
  adc #0
  sta fat32_fatstart+2
  lda fat32_tmp+3
  adc #0
  sta fat32_fatstart+3
  ldx #3
spf:
  lda fat32_workspace+36,x
  sta fat32_sectorsperfat,x
  lda fat32_workspace+44,x
  sta fat32_rootcluster,x
  dex
  bpl spf
  ; data start = FAT start + FATs * sectors per FAT
  MOV4 fat32_fatstart, fat32_datastart
  ldy fat32_numfats
fats:
  clc
  ldx #0
  .repeat 4, i
  lda fat32_datastart+i
  adc fat32_sectorsperfat+i
  sta fat32_datastart+i
  .endrepeat
  dey
  bne fats
  ; clusters: (total sectors - (data start - volume start)) >> shift, + 2
  clc
  lda fat32_workspace+32
  adc fat32_tmp
  sta fat32_maxcluster
  lda fat32_workspace+33
  adc fat32_tmp+1
  sta fat32_maxcluster+1
  lda fat32_workspace+34
  adc fat32_tmp+2
  sta fat32_maxcluster+2
  lda fat32_workspace+35
  adc fat32_tmp+3
  sta fat32_maxcluster+3
  sec
  .repeat 4, i
  lda fat32_maxcluster+i
  sbc fat32_datastart+i
  sta fat32_maxcluster+i
  .endrepeat
  ldx fat32_spcshift
  beq shifted
shift:
  lsr fat32_maxcluster+3
  ror fat32_maxcluster+2
  ror fat32_maxcluster+1
  ror fat32_maxcluster
  dex
  bne shift
shifted:
  clc
  lda fat32_maxcluster
  adc #2
  sta fat32_maxcluster
  bcc :+
  INC3 fat32_maxcluster+1
:
  ; ... but no more than the FAT has entries for (128 per sector)
  lda #0
  sta fat32_val
  lda fat32_sectorsperfat
  sta fat32_val+1
  lda fat32_sectorsperfat+1
  sta fat32_val+2
  lda fat32_sectorsperfat+2
  lsr
  sta fat32_val+3
  ror fat32_val+2
  ror fat32_val+1
  ror fat32_val
  lda fat32_val
  cmp fat32_maxcluster
  lda fat32_val+1
  sbc fat32_maxcluster+1
  lda fat32_val+2
  sbc fat32_maxcluster+2
  lda fat32_val+3
  sbc fat32_maxcluster+3
  bcs :+
  MOV4 fat32_val, fat32_maxcluster
:
  ; The free-cluster search starts after fat32_nextfree: from max - 1 it
  ; goes round to cluster 2.
  sec
  .repeat 4, i
  lda fat32_maxcluster+i
  sbc #(i = 0) & 1
  sta fat32_nextfree+i
  .endrepeat
  ; FSInfo sector (BPB offset 48, from the volume start; 0 or $FFFF: none)
  ZERO4 fat32_fsinfo
  lda fat32_workspace+48
  ora fat32_workspace+49
  jeq mounted
  lda fat32_workspace+48
  and fat32_workspace+49
  cmp #$ff
  jeq mounted
  clc
  lda fat32_tmp
  adc fat32_workspace+48
  sta fat32_fsinfo
  lda fat32_tmp+1
  adc fat32_workspace+49
  sta fat32_fsinfo+1
  lda fat32_tmp+2
  adc #0
  sta fat32_fsinfo+2
  lda fat32_tmp+3
  adc #0
  sta fat32_fsinfo+3
  MOV4 fat32_fsinfo, fat32_sec
  jsr fat32_cacheload
  jcs nofsinfo
  ldx #3
fsisig:
  lda fat32_workspace,x       ; "RRaA" ...
  cmp fsisig1,x
  jne nofsinfo
  lda fat32_workspace+484,x   ; ... and "rrAa"
  cmp fsisig2,x
  jne nofsinfo
  dex
  bpl fsisig
  ; The free count, if it is believable (at most max - 2)
  sec
  lda fat32_maxcluster
  sbc #2
  sta fat32_val
  .repeat 3, i
  lda fat32_maxcluster+1+i
  sbc #0
  sta fat32_val+1+i
  .endrepeat
  lda fat32_val
  cmp fat32_workspace+488
  lda fat32_val+1
  sbc fat32_workspace+489
  lda fat32_val+2
  sbc fat32_workspace+490
  lda fat32_val+3
  sbc fat32_workspace+491
  bcc nocount
  ldx #3
count:
  lda fat32_workspace+488,x
  sta fat32_freecount,x
  dex
  bpl count
  lda #$80
  sta fat32_fsflags
nocount:
  ; The next-free hint, if 3 <= hint < max
  ldx #3
hint:
  lda fat32_workspace+492,x
  sta fat32_val,x
  dex
  bpl hint
  jsr fat32_isvalid
  bcs mounted
  lda fat32_val+3
  ora fat32_val+2
  ora fat32_val+1
  bne usehint
  lda fat32_val
  cmp #3
  bcc mounted
usehint:
  sec
  .repeat 4, i
  lda fat32_val+i
  sbc #(i = 0) & 1
  sta fat32_nextfree+i
  .endrepeat
  jmp mounted
nofsinfo:
  ZERO4 fat32_fsinfo
mounted:
  jmp fat32_ok
fat32sig:
  .byte "FAT32"
fsisig1:
  .byte "RRaA"
fsisig2:
  .byte "rrAa"
.endproc

.proc fat32_sync
  ; Write out the cache, and the free-space information if it changed.
  jsr fat32_cacheflush
  jcs fail
  bit fat32_fsflags
  jvc ok
  lda fat32_fsinfo
  ora fat32_fsinfo+1
  ora fat32_fsinfo+2
  ora fat32_fsinfo+3
  beq clean
  MOV4 fat32_fsinfo, fat32_sec
  jsr fat32_cacheload
  bcs fail
  ldx #3
  lda #$ff
unknown:
  sta fat32_workspace+488,x
  dex
  bpl unknown
  bit fat32_fsflags
  bpl :+
  MOV4 fat32_freecount, fat32_workspace+488
: MOV4 fat32_nextfree, fat32_val
  INC4 fat32_val              ; the hint is the next one to try
  jsr fat32_isvalid
  bcc :+
  lda #2
  sta fat32_val
  lda #0
  sta fat32_val+1
  sta fat32_val+2
  sta fat32_val+3
: MOV4 fat32_val, fat32_workspace+492
  jsr fat32_dirty
  jsr fat32_cacheflush
  bcs fail
clean:
  lda fat32_fsflags
  and #<~$40
  sta fat32_fsflags
ok:
  jmp fat32_ok
fail:
  rts
.endproc

.proc fat32_free
  ; fat32_pos = the number of free clusters (counted, the first time,
  ; if the FSInfo sector did not say).
  bit fat32_fsflags
  bmi known
  ZERO4 fat32_freecount
  lda #2
  sta fat32_cl
  lda #0
  sta fat32_cl+1
  sta fat32_cl+2
  sta fat32_cl+3
loop:
  ldx #3
end:
  lda fat32_cl,x
  cmp fat32_maxcluster,x
  bne more
  dex
  bpl end
  lda fat32_fsflags
  ora #$c0                    ; known, and worth writing
  sta fat32_fsflags
  bne known
more:
  jsr fat32_fatget
  bcs fail
  lda fat32_val
  ora fat32_val+1
  ora fat32_val+2
  ora fat32_val+3
  bne used
  INC4 fat32_freecount
used:
  INC4 fat32_cl
  jmp loop
known:
  MOV4 fat32_freecount, fat32_pos
  jmp fat32_ok
fail:
  rts
.endproc

; ---------------------------------------------------------------------------
; Files

.proc fat32_open
  sty fat32_mode
  jsr fat32_load
  jsr fat32_walk
  jcs fail
  lda fat32_rootself
  jne isdir
  jsr fat32_dfind
  bcc found
  lda fat32_error
  cmp #FAT32_ERR_NOTFOUND
  jne fail
  lda fat32_mode
  and #FAT32_CREATE
  jeq fail
  lda fat32_mode
  and #FAT32_WRITE
  jeq access
  ; a new, empty file
  ZERO4 fat32_cl
  lda #$20                    ; archive
  jsr fat32_mkent
  jsr fat32_dcreate
  jcs fail
  ZERO4 fat32_f+FAT32_F_FIRST
  ZERO4 fat32_f+FAT32_F_SIZE
  lda #0
  beq setup
found:
  lda fat32_mode
  and #FAT32_EXCL
  jne exists
  lda fat32_ent+11
  and #$10
  jne isdir
  lda fat32_mode
  and #FAT32_WRITE
  beq :+
  lda fat32_ent+11
  and #$01                    ; read-only
  jne access
: lda fat32_ent+26
  sta fat32_f+FAT32_F_FIRST
  lda fat32_ent+27
  sta fat32_f+FAT32_F_FIRST+1
  lda fat32_ent+20
  sta fat32_f+FAT32_F_FIRST+2
  lda fat32_ent+21
  and #$0f
  sta fat32_f+FAT32_F_FIRST+3
  MOV4 fat32_ent+28, fat32_f+FAT32_F_SIZE
  lda fat32_mode
  and #FAT32_TRUNC
  beq setup
  lda fat32_mode
  and #FAT32_WRITE
  beq setup
  MOV4 fat32_f+FAT32_F_FIRST, fat32_cl
  jsr fat32_freechain
  bcs fail
  ZERO4 fat32_f+FAT32_F_FIRST
  ZERO4 fat32_f+FAT32_F_SIZE
  lda #FAT32_FL_DIRTY
setup:
  ; A = extra flags
  sta fat32_tmp
  lda fat32_mode
  and #FAT32_READ | FAT32_WRITE
  ora fat32_tmp
  ora #FAT32_FL_OPEN
  sta fat32_f+FAT32_F_FLAGS
  jsr fat32_setloc
  jsr fat32_setstart
  ZERO4 fat32_f+FAT32_F_POS
  lda fat32_mode
  and #FAT32_APPEND
  beq :+
  MOV4 fat32_f+FAT32_F_SIZE, fat32_f+FAT32_F_POS
: jsr fat32_save
  jmp fat32_ok
isdir:
  FAIL FAT32_ERR_ISDIR
exists:
  FAIL FAT32_ERR_EXISTS
access:
  FAIL FAT32_ERR_ACCESS
fail:
  jmp fat32_failed
.endproc

.proc fat32_checkopen
  ; The handle in fat32_f is an open file (not a directory) with flag A.
  and fat32_f+FAT32_F_FLAGS
  beq bad
  lda fat32_f+FAT32_F_FLAGS
  and #FAT32_FL_OPEN | FAT32_FL_DIR
  cmp #FAT32_FL_OPEN
  bne bad
  clc
  rts
bad:
  FAIL FAT32_ERR_ACCESS
.endproc

.proc fat32_read
  jsr fat32_load
  lda #FAT32_FL_READ
  jsr fat32_checkopen
  bcs refused
  lda #0
  sta fat32_wr
xfer:
  jsr fat32_xfer
  php
  jsr fat32_save
  plp
  bcc :+
  jmp fat32_failed
: jmp fat32_ok
refused:
  lda #0                      ; nothing moved
  sta fat32_len
  sta fat32_len+1
  jmp fat32_failed
.endproc

.proc fat32_write
  jsr fat32_load
  lda #FAT32_FL_WRITE
  jsr fat32_checkopen
  bcs fat32_read::refused
  lda #1
  sta fat32_wr
  jmp fat32_read::xfer
.endproc

.proc fat32_seek
  jsr fat32_load
  lda #FAT32_FL_READ | FAT32_FL_WRITE
  jsr fat32_checkopen
  bcs fail
  lda fat32_f+FAT32_F_SIZE    ; no further than the end
  cmp fat32_pos
  lda fat32_f+FAT32_F_SIZE+1
  sbc fat32_pos+1
  lda fat32_f+FAT32_F_SIZE+2
  sbc fat32_pos+2
  lda fat32_f+FAT32_F_SIZE+3
  sbc fat32_pos+3
  bcs :+
  FAIL FAT32_ERR_RANGE
: MOV4 fat32_pos, fat32_f+FAT32_F_POS
  jsr fat32_save
  jmp fat32_ok
fail:
  rts
.endproc

.proc fat32_close
  jsr fat32_load
  bit fat32_f+FAT32_F_FLAGS
  bmi :+
  FAIL FAT32_ERR_ACCESS
: jvc clean
  ; Update the directory entry: first cluster, size and time.
  MOV4 fat32_f+FAT32_F_DSEC, fat32_sec
  jsr fat32_cacheload
  jcs fail
  lda fat32_f+FAT32_F_DIDX    ; entry = index * 32
  lsr
  lsr
  lsr
  clc
  adc #>fat32_workspace
  sta fat32_cp+1
  lda fat32_f+FAT32_F_DIDX
  asl
  asl
  asl
  asl
  asl
  sta fat32_cp
  ldy #31
get:
  lda (fat32_cp),y
  sta fat32_ent,y
  dey
  bpl get
  lda fat32_f+FAT32_F_FIRST
  sta fat32_ent+26
  lda fat32_f+FAT32_F_FIRST+1
  sta fat32_ent+27
  lda fat32_f+FAT32_F_FIRST+2
  sta fat32_ent+20
  lda fat32_f+FAT32_F_FIRST+3
  sta fat32_ent+21
  MOV4 fat32_f+FAT32_F_SIZE, fat32_ent+28
  lda fat32_ent+11
  ora #$20                    ; archive
  sta fat32_ent+11
  lda fat32_time
  sta fat32_ent+22
  lda fat32_time+1
  sta fat32_ent+23
  lda fat32_date
  sta fat32_ent+18
  sta fat32_ent+24
  lda fat32_date+1
  sta fat32_ent+19
  sta fat32_ent+25
  ldy #31
put:
  lda fat32_ent,y
  sta (fat32_cp),y
  dey
  bpl put
  jsr fat32_dirty
clean:
  lda #0
  sta fat32_f+FAT32_F_FLAGS
  jsr fat32_save
  jmp fat32_sync
fail:
  rts
.endproc

.proc fat32_delete
  jsr fat32_lookup
  bcs fail
  lda fat32_ent+11
  and #$10
  beq :+
  FAIL FAT32_ERR_ISDIR
: lda fat32_ent+11
  and #$01
  beq :+
  FAIL FAT32_ERR_ACCESS
: jsr fat32_entcluster
  jsr freeit
  bcs fail
  jsr fat32_dremove
  bcs fail
  jmp fat32_sync
fail:
  rts
freeit:
  ; (fat32_entcluster gives the root for 0: free nothing then)
  lda fat32_ent+26
  ora fat32_ent+27
  ora fat32_ent+20
  ora fat32_ent+21
  bne :+
  clc
  rts
: jmp fat32_freechain
.endproc

; ---------------------------------------------------------------------------
; Directories

.proc fat32_mkdir
  jsr fat32_walk
  jcs fail
  lda fat32_rootself
  jne exists
  jsr fat32_dfind
  jcc exists
  lda fat32_error
  cmp #FAT32_ERR_NOTFOUND
  jne fail
  ; Its cluster, zeroed, with "." and ".." in it
  jsr fat32_alloc
  jcs fail
  MOV4 fat32_cl, fat32_mcl
  jsr fat32_zerocluster
  jcs fail
  MOV4 fat32_mcl, fat32_cl
  lda #$10
  jsr fat32_mkent             ; the parent's entry for it, in fat32_ent
  MOV4 fat32_mcl, fat32_cl
  jsr fat32_clsector
  jsr fat32_cacheload
  bcs fail
  ldy #31
dots:
  lda fat32_ent,y
  sta fat32_workspace,y
  sta fat32_workspace+32,y
  dey
  bpl dots
  lda #' '
  ldy #10
blank:
  sta fat32_workspace,y
  sta fat32_workspace+32,y
  dey
  bpl blank
  lda #'.'
  sta fat32_workspace
  sta fat32_workspace+32
  sta fat32_workspace+33
  ; ".." points at the parent, 0 for the root
  lda #0
  sta fat32_workspace+32+20
  sta fat32_workspace+32+21
  sta fat32_workspace+32+26
  sta fat32_workspace+32+27
  jsr fat32_dclroot
  beq :+
  lda fat32_dcl
  sta fat32_workspace+32+26
  lda fat32_dcl+1
  sta fat32_workspace+32+27
  lda fat32_dcl+2
  sta fat32_workspace+32+20
  lda fat32_dcl+3
  sta fat32_workspace+32+21
: jsr fat32_dirty
  ; Then the entry in the parent (whose free slot fat32_dfind found)
  jsr fat32_dcreate
  bcs fail
  jmp fat32_sync
exists:
  FAIL FAT32_ERR_EXISTS
fail:
  jmp fat32_failed
.endproc

.proc fat32_rmdir
  jsr fat32_lookup
  jcs fail
  lda fat32_ent+11
  and #$10
  bne :+
  FAIL FAT32_ERR_NOTDIR
: lda fat32_ent
  cmp #'.'
  bne :+
  FAIL FAT32_ERR_ACCESS
: jsr fat32_entcluster
  MOV4 fat32_cl, fat32_mcl
  ; Empty?  Anything but ".", ".." and deleted or long-name entries.
  MOV4 fat32_dcl, fat32_odcl
  MOV4 fat32_mcl, fat32_dcl
  jsr fat32_dopen
  MOV4 fat32_odcl, fat32_dcl
loop:
  ldx #DX
  jsr fat32_dnext
  bcs chainend
  ldy #0
  lda (fat32_cp),y
  beq empty
  cmp #$e5
  beq loop
  cmp #'.'
  beq loop
  ldy #11
  lda (fat32_cp),y
  cmp #$0f
  beq loop
  FAIL FAT32_ERR_NOTEMPTY
chainend:
  lda fat32_error
  bne fail
empty:
  MOV4 fat32_mcl, fat32_cl
  jsr fat32_freechain
  bcs fail
  jsr fat32_dremove
  bcs fail
  jmp fat32_sync
fail:
  jmp fat32_failed
.endproc

.proc fat32_rename
  ; The old entry
  jsr fat32_lookup
  jcs fail
  lda fat32_ent
  cmp #'.'
  bne :+
  FAIL FAT32_ERR_ACCESS
: ldy #31
save:
  lda fat32_ent,y
  sta fat32_ent2,y
  dey
  bpl save
  MOV4 fat32_dcl, fat32_odcl
  MOV4 fat32_epos, fat32_oepos
  MOV4 fat32_lfnpos, fat32_olfnpos
  lda fat32_lfnok
  sta fat32_olfnok
  ; The new name
  lda fat32_ptr2
  sta fat32_ptr1
  lda fat32_ptr2+1
  sta fat32_ptr1+1
  jsr fat32_walk
  jcs fail
  lda fat32_rootself
  jne exists
  ; A directory may not go inside itself: no directory on the way up
  ; from the new parent may be the one being moved.
  lda fat32_ent2+11
  and #$10
  beq place
  jsr movecheck
  jcs fail
place:
  jsr fat32_dfind
  jcc exists
  lda fat32_error
  cmp #FAT32_ERR_NOTFOUND
  jne fail
  ldy #31
restore:
  lda fat32_ent2,y
  sta fat32_ent,y
  dey
  bpl restore
  ldy #10
name:
  lda fat32_name,y
  sta fat32_ent,y
  dey
  bpl name
  jsr fat32_dcreate
  jcs fail
  ; Remove the old entry
  MOV4 fat32_dcl, fat32_mcl   ; (the new parent)
  MOV4 fat32_odcl, fat32_dcl
  MOV4 fat32_oepos, fat32_epos
  MOV4 fat32_olfnpos, fat32_lfnpos
  lda fat32_olfnok
  sta fat32_lfnok
  jsr fat32_dremove
  bcs fail
  ; A directory that moved: its ".." points at the new parent.
  lda fat32_ent2+11
  and #$10
  beq done
  ldx #3
same:
  lda fat32_mcl,x
  cmp fat32_odcl,x
  bne moved
  dex
  bpl same
  bmi done
moved:
  jsr fat32_entcluster        ; the directory itself (from fat32_ent)
  MOV4 fat32_cl, fat32_dcl
  jsr fat32_dopen
  ldx #DX
  jsr fat32_dnext             ; "."
  bcs fail
  ldx #DX
  jsr fat32_dnext             ; ".."
  bcs fail
  MOV4 fat32_mcl, fat32_cl
  jsr fat32_setentcluster     ; (0 for the root) into fat32_ent ...
  ldy #20
  lda fat32_ent+20
  sta (fat32_cp),y
  iny
  lda fat32_ent+21
  sta (fat32_cp),y
  ldy #26
  lda fat32_ent+26
  sta (fat32_cp),y
  iny
  lda fat32_ent+27
  sta (fat32_cp),y
  jsr fat32_dirty
done:
  jmp fat32_sync
exists:
  FAIL FAT32_ERR_EXISTS
fail:
  jmp fat32_failed

movecheck:
  ; Walk up from fat32_dcl by ".." entries to the root; fail if we meet
  ; the directory being moved.  Keeps fat32_dcl and fat32_name.
  MOV4 fat32_dcl, fat32_mcl
  ldy #10
keep:
  lda fat32_name,y
  sta fat32_name2,y
  dey
  bpl keep
  lda fat32_ent2+26           ; the moved directory's cluster
  sta fat32_prev
  lda fat32_ent2+27
  sta fat32_prev+1
  lda fat32_ent2+20
  sta fat32_prev+2
  lda fat32_ent2+21
  and #$0f
  sta fat32_prev+3
up:
  jsr fat32_dclroot
  beq upok
  ldx #3
cmpmoved:
  lda fat32_dcl,x
  cmp fat32_prev,x
  bne parent
  dex
  bpl cmpmoved
  MOV4 fat32_mcl, fat32_dcl
  FAIL FAT32_ERR_ACCESS
parent:
  lda #'.'
  sta fat32_name
  sta fat32_name+1
  lda #' '
  ldy #8
blank:
  sta fat32_name+2,y
  dey
  bpl blank
  jsr fat32_dfind             ; (no growing: fat32_prev is safe)
  bcc :+
  MOV4 fat32_mcl, fat32_dcl
  jmp fat32_failed
: jsr fat32_entcluster
  MOV4 fat32_cl, fat32_dcl
  jmp up
upok:
  MOV4 fat32_mcl, fat32_dcl
  ldy #10
back:
  lda fat32_name2,y
  sta fat32_name,y
  dey
  bpl back
  clc
  rts
.endproc

.proc fat32_opendir
  jsr fat32_load
  jsr fat32_walk
  bcs fail
  MOV4 fat32_dcl, fat32_cl
  lda fat32_rootself
  bne isroot
  jsr fat32_dfind
  bcs fail
  lda fat32_ent+11
  and #$10
  bne :+
  FAIL FAT32_ERR_NOTDIR
: jsr fat32_entcluster
  jmp setup
isroot:
  MOV4 fat32_rootcluster, fat32_cl
setup:
  MOV4 fat32_cl, fat32_f+FAT32_F_FIRST
  jsr fat32_setstart
  ZERO4 fat32_f+FAT32_F_POS
  ZERO4 fat32_f+FAT32_F_SIZE
  lda #FAT32_FL_OPEN | FAT32_FL_DIR | FAT32_FL_READ
  sta fat32_f+FAT32_F_FLAGS
  jsr fat32_save
  jmp fat32_ok
fail:
  jmp fat32_failed
.endproc

.proc fat32_readdir
  jsr fat32_load
  lda fat32_f+FAT32_F_FLAGS
  and #FAT32_FL_OPEN | FAT32_FL_DIR
  cmp #FAT32_FL_OPEN | FAT32_FL_DIR
  beq loop
  FAIL FAT32_ERR_ACCESS
loop:
  ldx #0
  jsr fat32_dnext
  bcs chainend
  ldy #0
  lda (fat32_cp),y
  beq atend
  cmp #$e5
  beq loop
  cmp #'.'
  beq loop
  ldy #11
  lda (fat32_cp),y
  cmp #$0f
  beq loop
  and #$08
  bne loop
  ldy #31
copy:
  lda (fat32_cp),y
  sta (fat32_ptr1),y
  dey
  bpl copy
  jsr fat32_save
  jmp fat32_ok
atend:
  ; stay at the end marker
  ldx #0
  jsr fat32_back32
  MOV4 fat32_tmp, fat32_f+FAT32_F_POS
chainend:
  jsr fat32_save
  lda fat32_error
  beq :+
  jmp fat32_failed
: sec                         ; the end: C=1, A=0
  rts
.endproc

.proc fat32_stat
  jsr fat32_walk
  bcs fail
  lda fat32_rootself
  beq find
  ldy #31                     ; the root: a made-up directory entry
  lda #0
zloop:
  sta fat32_ent,y
  dey
  bpl zloop
  lda #' '
  ldy #10
b:
  sta fat32_ent,y
  dey
  bpl b
  lda #'/'
  sta fat32_ent
  lda #$10
  sta fat32_ent+11
  bne copy
find:
  jsr fat32_dfind
  bcs fail
copy:
  ldy #31
loop:
  lda fat32_ent,y
  sta (fat32_ptr2),y
  dey
  bpl loop
  jmp fat32_ok
fail:
  jmp fat32_failed
.endproc
