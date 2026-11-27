; Print a text file from the SD card: 1/LOCATION.TXT (change "filename"
; below to the path of a file on your card).

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

  lda #<filename                ; open the file to read
  sta fat32_ptr1
  lda #>filename
  sta fat32_ptr1+1
  lda #<file
  ldx #>file
  ldy #FAT32_READ
  jsr fat32_open
  bcs fail

readloop:
  lda #<buffer                  ; read up to 64 bytes at a time
  sta fat32_ptr1
  lda #>buffer
  sta fat32_ptr1+1
  lda #64
  sta fat32_len
  lda #0
  sta fat32_len+1
  lda #<file
  ldx #>file
  jsr fat32_read
  bcs fail
  lda fat32_len                 ; 0: the end of the file
  beq done
  ldx #0
print:
  lda buffer,x
  stx count
  jsr OUTCH
  ldx count
  inx
  cpx fat32_len
  bne print
  jmp readloop

fail:
  ; A is the error code (see libfat32.s)
  pha
  jsr newline
  lda #'E'
  jsr print_char
  pla
  jsr print_hex
done:
  jsr newline
  jmp EXIT

filename:
  .asciiz "1/LOCATION.TXT"

  .include "hwconfig.s"
  .include "libsd.s"
  .include "libfat32.s"
  .include "libio.s"

.segment "BSS"
file:   .res FAT32_FILESIZE
buffer: .res 64
count:  .res 1
