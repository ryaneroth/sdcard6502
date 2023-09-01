zp_sd_address = $40         ; 2 bytes
zp_sd_currentsector = $42   ; 4 bytes
zp_fat32_variables = $46    ; 24 bytes

fat32_workspace = $200      ; two pages

buffer = $400

  .org $a000

reset:
  ldx #$ff
  txs
  ; Initialise
  jsr via_init
  jsr sd_init
  jsr fat32_init
  bcc _initsuccess
 
  ; Error during FAT32 initialization
  lda #'Z'
  jsr print_char
  lda fat32_errorstage
  jsr print_hex
  jmp loop

_initsuccess:

  ; Open root directory
  jsr fat32_openroot

  ; Find subdirectory by name
  ldx #<subdirname
  ldy #>subdirname
  jsr fat32_finddirent
  bcc _foundsubdir

  ; Subdirectory not found
  lda #'X'
  jsr print_char
  jmp loop

_foundsubdir:

  ; Open subdirectory
  jsr fat32_opendirent

  ; Find file by name
  ldx #<filename
  ldy #>filename
  jsr fat32_finddirent
  bcc _foundfile

  ; File not found
  lda #'Y'
  jsr print_char
  jmp loop

_foundfile:
 
  ; Open file
  jsr fat32_opendirent

  ; Read file contents into buffer
  lda #<buffer
  sta fat32_address
  lda #>buffer
  sta fat32_address+1

  jsr fat32_file_read


  ; Dump data to termianl

  ldy #0
_printloop:
  lda buffer,y
  jsr OUTCH

  iny

  cpy #16
  bne _not16
_not16:

  cpy #32
  bne _printloop


  ; loop forever
loop:
  jsr EXIT
  jmp loop

  .include "hwconfig.s"
  .include "libsd.s"
  .include "libfat32.s"
  .include "liboutput.s"

  .org $fffc
  .word reset
  .word $0000

subdirname:
  .asciiz "SUBFOLDR   "
filename:
  .asciiz "DEEPFILETXT"