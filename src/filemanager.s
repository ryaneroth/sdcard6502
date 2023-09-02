zp_sd_address = $40         ; 2 bytes
zp_sd_currentsector = $42   ; 4 bytes
zp_fat32_variables = $46    ; 24 bytes
inputbuffer = $80           ; 8 bytes
strcmp0 = $8A               ; 2 bytes
strcmp1 = $8E               ; 2 bytes
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
; TODO main process starts here
getinput:
  jsr newline
  jsr newline
  lda #'>'
  jsr OUTCH
  lda #' '
  jsr OUTCH
  ldx #0
getcharacter:
  jsr GETCH
  sta inputbuffer, x
  inx
  cmp #$0D                   ; Enter key
  bne getcharacter           ; Keep getting characters until we see enter
  dex
  lda #$0
  sta inputbuffer, x
  jsr newline
; TODO compare against commands that are just jmps to sub routines
; cd
; dir
  ldx #<inputbuffer
  ldy #>inputbuffer
  stx strcmp0
  sty strcmp0+1

  ldx #<cd
  ldy #>cd
  stx strcmp1
  sty strcmp1+1
  jsr strcmp
  beq cd_cmd

  ldx #<dir
  ldy #>dir
  stx strcmp1
  sty strcmp1+1
  jsr strcmp
  beq dir_cmd
exit:
  jsr EXIT

strcmp:
  ; T0 = input string 1 (255 chars or less)
  ; T1 = input string 2 (255 chars or less)
  ;
  ; on exit, flags should be set as expected for CMP.
  ;  C flag clear if string 1 < string 2
  ;  Z flag set if string 1 = string 2
  ;  A is trashed outright.
  ;  X is untouched, but should never depend on that anyway.
  ;  Y contains length of shortest string, less the NULL.
  ;    (same semantics as strlen()).
  ldy #$00
strcmp_loop:
  lda (strcmp1),y
  beq strcmp_different   ; Terminating NULLs always break the loop
  lda (strcmp0),y
  beq strcmp_different   ; Terminating NULLs always break the loop
  cmp (strcmp1),y
  bne strcmp_different   ; Mismatches also break the loop
  iny
  jmp strcmp_loop
strcmp_different:
  lda (strcmp0),y        ; reset the flags accordingly
  cmp (strcmp1),y
  rts

; Commands
cd_cmd:
  jmp getinput
dir_cmd:
  ; Open root directory TODO shoul dbe current directory
  jsr fat32_openroot
  jsr fat32_listdirent
  jmp getinput



; TODO below
  ; Find subdirectory by name
  ldx #<subdirname
  ldy #>subdirname
  jsr fat32_finddirent
  bcc _foundsubdir

  ; Subdirectory not found
  jsr newline
  lda #'S'
  jsr print_char
  lda #'D'
  jsr print_char
  lda #'N'
  jsr print_char
  lda #'F'
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
  jsr newline
  lda #'F'
  jsr print_char
  lda #'N'
  jsr print_char
  lda #'F'
  jsr print_char
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


  ; Dump data to terminal

  ldx #0
_printloop:
  lda buffer,x
  jsr OUTCH

  inx

  cpx #16
  bne _not16
_not16:

  cpx #32
  bne _printloop


  ; loop forever
loop:
  jsr EXIT
  jmp loop

  .include "hwconfig.s"
  .include "libsd.s"
  .include "libfat32.s"
  .include "liboutput.s"

;  .org $fffc
  .word reset
  .word $0000

; TODO remove
; Change these to the name of the file and folder you added to the card
; The strings must be 11 charaters long. Format is 8.3, filename.ext
subdirname:
  .asciiz "FOLDER     "
filename:
  .asciiz "HELLO   TXT"
; Commands
cd:
  .asciiz "CD"
dir:
  .asciiz "DIR"
