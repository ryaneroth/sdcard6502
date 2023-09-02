newline:
  lda #$0D                   ; CR
  jsr OUTCH                  ; Send a carriage retuen  
  lda #$0A                   ; LF
  jsr OUTCH                  ; Send the line feed
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