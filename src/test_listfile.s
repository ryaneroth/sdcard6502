; List a directory of the SD card: each entry's name, then "/" for a
; directory or its size in hex for a file.  Change "dirname" below to
; list another directory ("" is the root).

fat32_workspace = $0200         ; the sector cache: page aligned, 512 bytes

.segment "CODE"
reset:
  ldx #$ff
  txs
  jsr newline
  lda #PORTA_OUTPUTPINS         ; the SD card is on port A
  sta DDRA
  jsr sd_init
  bcs fail
  jsr fat32_init
  bcs fail

  lda #<dirname
  sta fat32_ptr1
  lda #>dirname
  sta fat32_ptr1+1
  lda #<dir
  ldx #>dir
  jsr fat32_opendir
  bcs fail

next:
  lda #<entry                   ; the next entry, in FAT layout
  sta fat32_ptr1
  lda #>entry
  sta fat32_ptr1+1
  lda #<dir
  ldx #>dir
  jsr fat32_readdir
  bcc show
  cmp #0                        ; C=1 and A=0: the end
  bne fail
  jmp EXIT

show:
  jsr newline
  jsr print_entry
  jmp next

fail:
  ; A is the error code (see libfat32.s)
  pha
  jsr newline
  lda #'E'
  jsr print_char
  pla
  jsr print_hex
  jsr newline
  jmp EXIT

print_entry:
  ldx #0                        ; the name, to the first space
name:
  lda entry,x
  cmp #' '
  beq ext
  jsr putc_x
  inx
  cpx #8
  bne name
ext:
  lda entry+8
  cmp #' '
  beq kind
  lda #'.'
  jsr putc_x
  ldx #8
extloop:
  lda entry,x
  cmp #' '
  beq kind
  jsr putc_x
  inx
  cpx #11
  bne extloop
kind:
  lda entry+11                  ; attributes
  and #$10
  beq size
  lda #'/'
  jmp print_char
size:
  lda #' '
  jsr print_char
  lda entry+31                  ; size, high byte first
  jsr print_hex
  lda entry+30
  jsr print_hex
  lda entry+29
  jsr print_hex
  lda entry+28
  jmp print_hex

putc_x:
  ; print A, keeping X
  stx savex
  jsr print_char
  ldx savex
  rts

dirname:
  .asciiz ""

  .include "hwconfig.s"
  .include "libsd.s"
  .include "libfat32.s"
  .include "libio.s"

.segment "BSS"
dir:    .res FAT32_FILESIZE
entry:  .res 32
savex:  .res 1
