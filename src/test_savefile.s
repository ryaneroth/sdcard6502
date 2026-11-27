; Write a file to the SD card: SAVETEST.DAT, 256 bytes counting from 0
; to 255 (created, or replaced if it is there).

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

  ldy #0                        ; the data
fill:
  tya
  sta buffer,y
  iny
  bne fill

  lda #<filename                ; create the file
  sta fat32_ptr1
  lda #>filename
  sta fat32_ptr1+1
  lda #<file
  ldx #>file
  ldy #FAT32_WRITE | FAT32_CREATE | FAT32_TRUNC
  jsr fat32_open
  bcs fail
  lda #'O'
  jsr print_char

  lda #<buffer                  ; write it
  sta fat32_ptr1
  lda #>buffer
  sta fat32_ptr1+1
  lda #0
  sta fat32_len
  lda #1
  sta fat32_len+1
  lda #<file
  ldx #>file
  jsr fat32_write
  bcs fail
  lda #'W'
  jsr print_char

  lda #<file                    ; close it: sets its size on the card
  ldx #>file
  jsr fat32_close
  bcs fail
  lda #'!'
  jsr print_char
  jsr newline
  jmp EXIT

fail:
  ; A is the error code (see libfat32.s)
  pha
  lda #'E'
  jsr print_char
  pla
  jsr print_hex
  jsr newline
  jmp EXIT

filename:
  .asciiz "SAVETEST.DAT"

  .include "hwconfig.s"
  .include "libsd.s"
  .include "libfat32.s"
  .include "libio.s"

.segment "BSS"
file:   .res FAT32_FILESIZE
buffer: .res 256
