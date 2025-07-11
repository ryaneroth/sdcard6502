zp_sd_address = $40         ; 2 bytes
zp_sd_currentsector = $42   ; 4 bytes
zp_fat32_variables = $46    ; 49 bytes
dirent_pointer = $100       ; 2 bytes
dirent_end_counter = $102       ; 2 bytes

fat32_workspace = $200      ; two pages


buffer = $400

  .org $A000
  jsr newline
reset:
  ldx #$ff
  txs
  ; Initialize
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
_readdirent:
  ; Iterate over directory entries
  lda dirent_end_counter
  cmp #2
  beq loop
  jsr fat32_readdirent
  bcs _endofdirent
  lda #0
  sta dirent_end_counter
  jsr newline
  ldy #0
_printloop:
  tya
  pha
  lda (zp_sd_address),y
  jsr print_char
  pla
  tay
  iny
  cpy #11
  bne _printloop
  ; jsr newline
  ; Check if directory entry is a folder
  ldy #0
  lda (zp_sd_address),y
  cmp #'.'
  beq _notafolder
  ldy #11
  lda (zp_sd_address),y
  and #$10
  cmp #$10
  bne _notafolder
  lda #'\'
  jsr print_char
  lda zp_sd_address
  sta dirent_pointer
  lda zp_sd_address+1
  sta dirent_pointer+1
  jsr fat32_opendirent
_notafolder:
  jsr _readdirent
_endofdirent:
  inc dirent_end_counter
  clc
  ; Open root directory
  jsr fat32_openroot
  jsr fat32_readdirent
  ; Restore previous sd address
  lda dirent_pointer
  sta zp_sd_address
  lda dirent_pointer+1
  sta zp_sd_address+1
  jsr _readdirent
  ; loop forever
loop:
  jsr EXIT
  jmp loop

  .include "hwconfig.s"
  .include "libsd.s"
  .include "libfat32.s"
  .include "libio.s"

;  .org $fffc
  .word reset
  .word $0000
