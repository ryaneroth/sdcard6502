;----------------------------------------------
; Copy data from SD card to memory location
;----------------------------------------------
copy_size = $27             ; 2 bytes
copy_destination = $29      ; 2 bytes
input_pointer = $2B         ; 11 bytes
print_pointer = $38         ; 2 bytes
zp_sd_address = $40         ; 2 bytes
zp_sd_currentsector = $42   ; 4 bytes
zp_fat32_variables = $46    ; 49 bytes
copy_swap = $78             ; 4 bytes
dirent_pointer = $100       ; 2 bytes
dirent_end_counter = $102   ; 2 bytes

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
  jsr EXIT

_initsuccess:
  ; Open root directory
  jsr fat32_openroot

print_help:
  jsr newline
  ldx #<help_menu
  ldy #>help_menu
  stx print_pointer
  sty print_pointer+1
  jsr print_string

print_prompt:
  jsr newline
  lda #'>'
  jsr print_char
  lda #' '
  jsr print_char
read_prompt_input:
  jsr get_input
  cmp #'L'
  beq load_file
  cmp #'H'
  beq print_help
  jsr print_prompt

load_file:
  jsr newline
  ldx #<input_filename
  ldy #>input_filename
  stx print_pointer
  sty print_pointer+1
  jsr print_string
  jsr read_input

  ; Find file by name
  ldx #<input_pointer
  ldy #>input_pointer
  jsr fat32_finddirent
  bcc foundfile

  ; File not found
  jsr newline
  ldx #<file_not_found
  ldy #>file_not_found
  stx print_pointer
  sty print_pointer+1
  jsr print_string
  ; Open root directory
  jsr fat32_openroot
  jmp print_prompt

foundfile:
  jsr newline
  ; get destination address
  ldx #<memory_destination
  ldy #>memory_destination
  stx print_pointer
  sty print_pointer+1
  jsr print_string
  jsr read_address
  jsr newline
  ; Open file
  jsr fat32_opendirent
  ; Store file size
  lda fat32_bytesremaining 
  sta copy_size
  lda fat32_bytesremaining+1
  sta copy_size+1
  ; Read file contents into buffer
  lda #<buffer
  sta fat32_address
  lda #>buffer
  sta fat32_address+1
  ldx #<reading
  ldy #>reading
  stx print_pointer
  sty print_pointer+1
  jsr print_string
  ; Can hang on the file read sometimes
  jsr fat32_file_read
  ldx #<copying
  ldy #>copying
  stx print_pointer
  sty print_pointer+1
  jsr print_string
; start copy
  jsr start_copy

  jsr EXIT
;----------------------------------------------
; Read in filename
;----------------------------------------------
read_input:
  ldx #0
read_prefix_next:
  jsr get_input
  cmp #'.'
  beq period
  cpx #8
  beq max_prefix_character
  sta input_pointer, x
  inx
  jmp read_prefix_next
period:
  lda #' '
  sta input_pointer, x
  inx
  cpx #8
  beq max_prefix_character
  jmp period
read_suffix_next:
  inx
max_prefix_character:
  jsr get_input
  cpx #11
  beq max_suffix_character
  cmp #$0D                    ; Enter key
  beq pad_suffix
  sta input_pointer, x
  jmp read_suffix_next
pad_suffix:
  lda #' '
  sta input_pointer, x
  cpx #11
  beq max_suffix_character
  inx
  jmp pad_suffix
max_suffix_character:
  rts
;----------------------------------------------
; Read in address to copy data to
;----------------------------------------------
read_address:
  ldx #0
read_address_next:
  jsr get_input
  cpx #2
  beq read_address_done
  and #$0F                ; '0'-'9' -> 0-9
  asl                     ; multiply by 2
  sta copy_destination, x ; temp store in temp
  asl                     ; again multiply by 2 (*4)
  asl                     ; again multiply by 2 (*8)
  clc
  adc copy_destination, x ; as result, a = x*8 + x*2
  sta copy_destination, x
  jsr get_input
  and #$0F                ; '0'-'9' -> 0-9
  adc copy_destination, x
  jsr hex_to_dec
  sta copy_destination, x
  inx
  jmp read_address_next
read_address_done:
  rts
;----------------------------------------------
; Print string whos address is in print_pointer
;----------------------------------------------
print_string:
  ldx #0
print_string_loop:
  txa
  tay
  lda (print_pointer), y       ; get from string
  beq print_string_exit        ; end of string
  jsr OUTCH                    ; write to output
  inx
  bne print_string_loop        ; do next char
print_string_exit:
  rts
;----------------------------------------------
; Hex to decimal converter
;----------------------------------------------
hex_to_dec:
  sed           ; switch to decimal mode
  tay           ; transfer accumulator to y register
  lda #00       ; reset accumulator

hex_loop:
  dey           ; decrement x by 1
  cpy #00       ; if y < 0,
  bmi hex_break ; then break;
  clc           ; else clear carry
  adc #01       ; to increment accumulator by 1
  jmp hex_loop  ; branch always

hex_break:
  cld
  rts ; return from subroutine
;----------------------------------------------
; Relocate code
;----------------------------------------------
start_copy:
  lda #<buffer                   ; set our source memory address to copy from
  sta copy_swap
  lda #>buffer
  sta copy_swap+1
  lda copy_destination+1         ; set our destination memory to copy to
  sta copy_swap+2
  lda copy_destination
  sta copy_swap+3
  ldx #$00                       ; reset x for our loop
  ldy #$00                       ; reset y for our loop

copy_loop:
  lda (copy_swap),y              ; indirect index source memory address
  sta (copy_swap+2),y            ; indirect index dest memory address
  iny
  bne copy_loop                  ; loop until our dest goes over 255
  inc copy_swap+1                ; increment high order source memory address
  inc copy_swap+3                ; increment high order dest memory address
  cpx copy_size+1                ; compare with the last address we want to write
  beq stop_copy
  inx
  jmp copy_loop                  ; if we're not there yet, loop

stop_copy:
  rts
;----------------------------------------------
; Strings
;----------------------------------------------
help_menu:
  .byte "L    Load file"
  .byte $0D, $0A
  .asciiz "H    Print help"
input_filename:
  .asciiz "Input filename > "
file_not_found:
  .asciiz "File not found"
memory_destination:
  .asciiz "Memory destination > "
reading:
  .asciiz "Reading data from SD card"
copying:
  .asciiz "Copying data to destination"
;----------------------------------------------
; Includes
;----------------------------------------------
  .include "hwconfig.s"
  .include "libsd.s"
  .include "libfat32.s"
  .include "libio.s"
