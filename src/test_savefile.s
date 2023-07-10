  .org $e000

  .include "hwconfig.s"
  .include "libsd.s"
  .include "libfat32.s"
  .include "liblcd.s"


zp_sd_address = $40         ; 2 bytes
zp_sd_currentsector = $42   ; 4 bytes
zp_fat32_variables = $46    ; 49 bytes

fat32_workspace = $200      ; two pages

buffer = $400

subdirname:
  .asciiz "SUBFOLDR   "
filename:
  .asciiz "SAVETESTTXT"

reset:
  ldx #$ff
  txs

  ; Initialise
  jsr via_init
  jsr lcd_init
  jsr sd_init
  jsr fat32_init
  bcc .initsuccess
 
  ; Error during FAT32 initialization
  lda #'Z'
  jsr print_char
  lda fat32_errorstage
  jsr print_hex
  jmp loop
.initsuccess

  ; Make a dummy file.
  ; it should count from 0-255.
  ldy #0
.fileloop
  tya
  sta buffer,y
  iny
  bne .fileloop

  ; Allocating
  lda #'a'
  jsr print_char

  ; Set file size to one page, and push it as we will be clobbering it when we load the directory
  lda #0
  sta fat32_bytesremaining
  pha
  lda #$01
  sta fat32_bytesremaining+1
  pha

  ; Allocate space for the file
  jsr fat32_allocatefile

  ; Opening Directory
  lda #'o'
  jsr print_char

  ; Open root directory
  jsr fat32_openroot

  ; Find subdirectory by name
  ldx #<subdirname
  ldy #>subdirname
  jsr fat32_finddirent
  bcc .foundsubdir

  ; Subdirectory not found
  lda #'X'
  jsr print_char
  jmp loop

.foundsubdir

  ; Open subdirectory
  jsr fat32_opendirent

  ; Writing dirent
  lda #'w'
  jsr print_char

  ; Restore filesize
  pla 
  sta fat32_bytesremaining+1
  pla
  sta fat32_bytesremaining

  ; Store filename ponter
  lda #<filename
  sta fat32_filenamepointer
  lda #>filename
  sta fat32_filenamepointer+1

  ; Write the directory entry
  jsr fat32_writedirent

  ; Data
  lda #'d'
  jsr print_char

  ; Now write the file data
  lda #<buffer
  sta fat32_address
  lda #>buffer
  sta fat32_address+1
  jsr fat32_file_write

  ; Done!
  lda #'!'
  jsr print_char

  ; loop forever
loop:
  jmp loop


  .org $fffc
  .word reset
  .word $0000
