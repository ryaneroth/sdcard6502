OUTCH = $1EA0
PRTBYT = $1E3B 
PRINT_BUFFER = $00

newline:
  lda #$0D                   ; CR
  jsr OUTCH                  ; Send a carriage retuen  
  lda #$0A                   ; LF
  jsr OUTCH                  ; Send the line feed
  rts

print_string:
  ldx #0
print_string_loop:
  txa
  tay
  lda (PRINT_BUFFER), y        ; get from string
  beq print_string_exit        ; end of string
  jsr OUTCH                    ; write to output
  inx
  bne print_string_loop        ; do next char
print_string_exit:
  jsr newline
  rts

print_char:
  jsr OUTCH
  rts

print_hex:
  pha
  ror
  ror
  ror
  ror
  jsr print_nybble
  pla
  pha
  jsr print_nybble
  pla
  rts
print_nybble:
  and #15
  cmp #10
  bmi skipletter
  adc #6
skipletter:
  adc #48
  jsr print_char
  rts