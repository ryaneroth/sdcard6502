; C bindings for the file system, for the test program (fstest.c).
; Each call returns the driver's error code (0 = success); readdir
; returns $FF at the end of the directory.

.setcpu "6502"

.include "../src/hwconfig.s"

fat32_workspace = $0400         ; page aligned, 512 bytes

.export _t_init, _t_open, _t_read, _t_write, _t_seek, _t_close
.export _t_delete, _t_rename, _t_mkdir, _t_rmdir, _t_opendir, _t_readdir
.export _t_stat, _t_free, _t_sync
.export _t_mode, _t_ptr1, _t_ptr2, _t_len, _t_pos, _t_cardtype
.export _t_done

.segment "CODE"

_t_init:
  lda #PORTA_OUTPUTPINS
  sta DDRA
  jsr sd_init
  lda #FAT32_ERR_IO
  bcc :+
  jmp ret
:
  jsr fat32_init
  jmp ret

_t_open:                        ; (handle)
  jsr setargs
  ldy _t_mode
  jsr fat32_open
  jmp ret
_t_read:
  jsr setargs
  jsr fat32_read
  jmp retlen
_t_write:
  jsr setargs
  jsr fat32_write
retlen:
  pha
  lda fat32_len
  sta _t_len
  lda fat32_len+1
  sta _t_len+1
  pla
  jmp ret
_t_seek:
  jsr setargs
  jsr fat32_seek
  jmp ret
_t_close:
  jsr setargs
  jsr fat32_close
  jmp ret
_t_delete:
  jsr setargs
  jsr fat32_delete
  jmp ret
_t_rename:
  jsr setargs
  jsr fat32_rename
  jmp ret
_t_mkdir:
  jsr setargs
  jsr fat32_mkdir
  jmp ret
_t_rmdir:
  jsr setargs
  jsr fat32_rmdir
  jmp ret
_t_opendir:
  jsr setargs
  jsr fat32_opendir
  jmp ret
_t_readdir:
  jsr setargs
  jsr fat32_readdir
  bcc ret
  cmp #0
  bne ret
  lda #$ff
  jmp ret
_t_stat:
  jsr setargs
  jsr fat32_stat
  jmp ret
_t_free:
  jsr fat32_free
  pha
  ldx #3
: lda fat32_pos,x
  sta _t_pos,x
  dex
  bpl :-
  pla
  jmp ret
_t_sync:
  jsr fat32_sync
ret:
  ldx #0
  rts

setargs:
  ; copy the C-side arguments in; keeps A/X (the handle)
  pha
  lda _t_ptr1
  sta fat32_ptr1
  lda _t_ptr1+1
  sta fat32_ptr1+1
  lda _t_ptr2
  sta fat32_ptr2
  lda _t_ptr2+1
  sta fat32_ptr2+1
  lda _t_len
  sta fat32_len
  lda _t_len+1
  sta fat32_len+1
  lda _t_pos
  sta fat32_pos
  lda _t_pos+1
  sta fat32_pos+1
  lda _t_pos+2
  sta fat32_pos+2
  lda _t_pos+3
  sta fat32_pos+3
  lda sd_cardtype
  sta _t_cardtype
  pla
  rts

_t_done:                        ; the test runner stops here
  jmp _t_done

.segment "BSS"
_t_mode:  .res 1
_t_ptr1:  .res 2
_t_ptr2:  .res 2
_t_len:   .res 2
_t_pos:   .res 4
_t_cardtype: .res 1

.segment "CODE"
.include "../src/libsd.s"
.include "../src/libfat32.s"
