newline:
  lda #$0D                   ; CR
  jsr OUTCH                  ; Send a carriage retuen  
  lda #$0A                   ; LF
  jsr OUTCH                  ; Send the line feed
  rts

print_char:
; JSR OUTCH    1EA0     Print ASCII char  A     -       Xis preserved
;                       in A on TTY                     Y = FF
;                                                       A = FF
  jsr OUTCH
  rts

print_hex:
; JSR PRTBYT   1E3B     Prints A as       A     -       A preserved
;                       2 Hex Char.                     X preserved
;                                                       Y = FF
  jsr PRTBYT
  rts

get_input:
; JSR GETCH    1E5A     Put character     -     A       X preserved
;                       from TTY in A                   Y = FF
  jsr GETCH
  rts