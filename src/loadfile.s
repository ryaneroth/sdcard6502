;----------------------------------------------
; Load a file from the SD card into memory.
;
;   L   load a file: type its path (for example GAME.BIN or GAMES/ADV.BIN)
;       and Return, then the address to load it at as four hex digits
;   D   list a directory: type its path ("" for the root) and Return
;   H   help
;   E   exit to the monitor
;----------------------------------------------

fat32_workspace = $0200         ; the sector cache: page aligned, 512 bytes

.segment "CODE"
reset:
  ldx #$ff
  txs
  lda #PORTA_OUTPUTPINS         ; the SD card is on port A
  sta DDRA
  jsr sd_init
  bcs initfail
  jsr fat32_init
  bcc help
initfail:
  jsr show_error
  jmp EXIT

help:
  lda #<help_menu
  ldx #>help_menu
  jsr print_string
prompt:
  jsr newline
  lda #'>'
  jsr print_char
  lda #' '
  jsr print_char
  jsr get_input
  and #$df                      ; upper case
  cmp #'L'
  beq load_file
  cmp #'D'
  bne :+
  jmp list_dir
: cmp #'H'
  beq help
  cmp #'E'
  bne prompt
  jmp EXIT

;----------------------------------------------
; L: load a file
;----------------------------------------------
load_file:
  jsr newline
  lda #<input_filename
  ldx #>input_filename
  jsr print_string
  jsr read_line
  lda #<line                    ; open it
  sta fat32_ptr1
  lda #>line
  sta fat32_ptr1+1
  lda #<file
  ldx #>file
  ldy #FAT32_READ
  jsr fat32_open
  bcc found
  jsr show_error
  jmp prompt
found:
  jsr newline
  lda #<memory_destination
  ldx #>memory_destination
  jsr print_string
  jsr read_address
  bcs prompt
  jsr newline
  lda #<reading
  ldx #>reading
  jsr print_string
  ; Read the whole file straight to the destination: as many bytes as
  ; it has, up to 64 KB.
  lda address
  sta fat32_ptr1
  lda address+1
  sta fat32_ptr1+1
  lda #$ff
  sta fat32_len
  sta fat32_len+1
  lda #<file
  ldx #>file
  jsr fat32_read
  bcc loaded
  jsr show_error
  jmp prompt
loaded:
  jsr newline
  lda fat32_len+1               ; how much
  jsr print_hex
  lda fat32_len
  jsr print_hex
  lda #<bytes_loaded
  ldx #>bytes_loaded
  jsr print_string
  jmp prompt

;----------------------------------------------
; D: list a directory
;----------------------------------------------
list_dir:
  jsr newline
  lda #<input_dirname
  ldx #>input_dirname
  jsr print_string
  jsr read_line
  lda #<line
  sta fat32_ptr1
  lda #>line
  sta fat32_ptr1+1
  lda #<file
  ldx #>file
  jsr fat32_opendir
  bcs listfail
listnext:
  lda #<entry
  sta fat32_ptr1
  lda #>entry
  sta fat32_ptr1+1
  lda #<file
  ldx #>file
  jsr fat32_readdir
  bcc listshow
  cmp #0                        ; C=1, A=0: the end
  beq listdone
listfail:
  jsr show_error
listdone:
  jmp prompt
listshow:
  jsr newline
  ldx #0                        ; the name
lname:
  lda entry,x
  cmp #' '
  beq lext
  jsr putc_x
  inx
  cpx #8
  bne lname
lext:
  lda entry+8
  cmp #' '
  beq lkind
  lda #'.'
  jsr putc_x
  ldx #8
lextloop:
  lda entry,x
  cmp #' '
  beq lkind
  jsr putc_x
  inx
  cpx #11
  bne lextloop
lkind:
  lda entry+11
  and #$10
  beq lsize
  lda #'/'
  jsr print_char
  jmp listnext
lsize:
  lda #' '
  jsr print_char
  lda entry+31
  jsr print_hex
  lda entry+30
  jsr print_hex
  lda entry+29
  jsr print_hex
  lda entry+28
  jsr print_hex
  jmp listnext

;----------------------------------------------
; Input
;----------------------------------------------
read_line:
  ; a line of up to 63 characters into "line", ended by Return
  ldx #0
rl:
  stx savex
  jsr get_input
  ldx savex
  cmp #$0d
  beq rldone
  cmp #$08                      ; backspace
  bne :+
  cpx #0
  beq rl
  dex
  jmp rl
: cpx #63
  bcs rl
  sta line,x
  inx
  jmp rl
rldone:
  lda #0
  sta line,x
  rts

read_address:
  ; four hex digits into "address"; C=1 if one was not a hex digit
  jsr read_hex_byte
  bcs radone
  sta address+1
  jsr read_hex_byte
  bcs radone
  sta address
radone:
  rts

read_hex_byte:
  jsr read_hex_digit
  bcs rhdone
  asl
  asl
  asl
  asl
  sta digit
  jsr read_hex_digit
  bcs rhdone
  ora digit
rhdone:
  rts

read_hex_digit:
  jsr get_input
  cmp #'0'
  bcc bad
  cmp #'9'+1
  bcc decdigit
  and #$df                      ; upper case
  cmp #'A'
  bcc bad
  cmp #'F'+1
  bcs bad
  sbc #'A'-10-1                 ; (C=0 here)
  clc
  rts
decdigit:
  sbc #'0'-1                    ; (C=0 here)
  clc
  rts
bad:
  sec
  rts

;----------------------------------------------
; Output
;----------------------------------------------
show_error:
  ; "Error NN" for driver error A (see libfat32.s)
  pha
  jsr newline
  lda #<error
  ldx #>error
  jsr print_string
  pla
  jmp print_hex

print_string:
  ; the 0-terminated string at A/X
  sta string
  stx string+1
  ldy #0
ps:
  lda (string),y
  beq psdone
  sty savey
  jsr OUTCH
  ldy savey
  iny
  bne ps
psdone:
  rts

putc_x:
  stx savex
  jsr print_char
  ldx savex
  rts

;----------------------------------------------
; Strings
;----------------------------------------------
help_menu:
  .byte $0d, $0a, "L    Load file"
  .byte $0d, $0a, "D    List directory"
  .byte $0d, $0a, "E    Exit"
  .byte $0d, $0a, "H    Print help", 0
input_filename:
  .asciiz "File > "
input_dirname:
  .asciiz "Directory > "
memory_destination:
  .asciiz "Address (hex) > "
reading:
  .asciiz "Reading"
bytes_loaded:
  .asciiz " bytes loaded"
error:
  .asciiz "Error "

;----------------------------------------------
; Includes
;----------------------------------------------
  .include "hwconfig.s"
  .include "libsd.s"
  .include "libfat32.s"
  .include "libio.s"

.segment "ZEROPAGE"
string:   .res 2
.segment "BSS"
file:     .res FAT32_FILESIZE
entry:    .res 32
line:     .res 64
address:  .res 2
digit:    .res 1
savex:    .res 1
savey:    .res 1
