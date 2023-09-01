PORTA = $1700
DDRA = $1701
PORTB = $1702
DDRB = $1703
OUTCH = $1EA0
EXIT  = $1C4F

E  = %10000000
RW = %01000000
RS = %00100000

SD_CS   = %00010000
SD_SCK  = %00001000
SD_MOSI = %00000100
SD_MISO = %00000010

PORTA_OUTPUTPINS = E | RW | RS | SD_CS | SD_SCK | SD_MOSI

zp_sd_cmd_address = $40


  .org $a000

reset:
  ldx #$ff
  txs

  lda #%11111111          ; Set all pins on port B to output
  sta DDRB
  lda #PORTA_OUTPUTPINS   ; Set various pins on port A to output
  sta DDRA
  jsr sd_init


  ; Read a sector
  lda #'r'
  jsr print_char
  lda #'s'
  jsr print_char
  lda #':'
  jsr print_char

  lda #SD_MOSI
  sta PORTA

  ; Command 17, arg is sector number, crc not checked
  lda #$51           ; CMD17 - READ_SINGLE_BLOCK
  jsr sd_writebyte
  lda #$00           ; sector 24:31
  jsr sd_writebyte
  lda #$00           ; sector 16:23
  jsr sd_writebyte
  lda #$00           ; sector 8:15
  jsr sd_writebyte
  lda #$00           ; sector 0:7
  jsr sd_writebyte
  lda #$01           ; crc (not checked)
  jsr sd_writebyte

  jsr sd_waitresult
  cmp #$00
  beq readsuccess

  lda #'f'
  jsr print_char
  jmp loop

readsuccess:
  lda #'s'
  jsr print_char
  lda #':'
  jsr print_char

  ; wait for data
  jsr sd_waitresult
  cmp #$fe
  beq readgotdata

  lda #'f'
  jsr print_char
  jmp loop

readgotdata:
  ; Need to read 512 bytes.  Read two at a time, 256 times.
  lda #0
  sta $00 ; counter
readloop:
  jsr sd_readbyte
  sta $01 ; byte1
  jsr sd_readbyte
  sta $02 ; byte2
  dec $00 ; counter
  bne readloop

  ; End command
  lda #SD_CS | SD_MOSI
  sta PORTA

  ; Print the last two bytes read, in hex
  lda $01 ; byte1
  jsr print_hex
  lda $02 ; byte2
  jsr print_hex


  ; loop forever
loop:
  jsr EXIT
  jmp loop



sd_init:
  ; Let the SD card boot up, by pumping the clock with SD CS disabled

  ; We need to apply around 80 clock pulses with CS and MOSI high.
  ; Normally MOSI doesn't matter when CS is high, but the card is
  ; not yet is SPI mode, and in this non-SPI state it does care.

  lda #SD_CS | SD_MOSI
  ldx #160               ; toggle the clock 160 times, so 80 low-high transitions
preinitloop:
  eor #SD_SCK
  sta PORTA
  dex
  bne preinitloop
  

cmd0: ; GO_IDLE_STATE - resets card to idle state, and SPI mode
  lda #<cmd0_bytes
  sta zp_sd_cmd_address
  lda #>cmd0_bytes
  sta zp_sd_cmd_address+1

  jsr sd_sendcommand

  ; Expect status response $01 (not initialized)
  cmp #$01
  bne initfailed

cmd8: ; SEND_IF_COND - tell the card how we want it to operate (3.3V, etc)
  lda #<cmd8_bytes
  sta zp_sd_cmd_address
  lda #>cmd8_bytes
  sta zp_sd_cmd_address+1

  jsr sd_sendcommand

  ; Expect status response $01 (not initialized)
  cmp #$01
  bne initfailed

  ; Read 32-bit return value, but ignore it
  jsr sd_readbyte
  jsr sd_readbyte
  jsr sd_readbyte
  jsr sd_readbyte

cmd55: ; APP_CMD - required prefix for ACMD commands
  lda #<cmd55_bytes
  sta zp_sd_cmd_address
  lda #>cmd55_bytes
  sta zp_sd_cmd_address+1

  jsr sd_sendcommand

  ; Expect status response $01 (not initialized)
  cmp #$01
  bne initfailed

cmd41: ; APP_SEND_OP_COND - send operating conditions, initialize card
  lda #<cmd41_bytes
  sta zp_sd_cmd_address
  lda #>cmd41_bytes
  sta zp_sd_cmd_address+1

  jsr sd_sendcommand

  ; Status response $00 means initialised
  cmp #$00
  beq initialized

  ; Otherwise expect status response $01 (not initialized)
  cmp #$01
  bne initfailed

  ; Not initialized yet, so wait a while then try again.
  ; This retry is important, to give the card time to initialize.
  jsr delay
  jmp cmd55


initialized:
  lda #'Y'
  jsr print_char
  rts

initfailed:
  lda #'X'
  jsr print_char
  jmp loop


cmd0_bytes:
  .byte $40, $00, $00, $00, $00, $95
cmd8_bytes:
  .byte $48, $00, $00, $01, $aa, $87
cmd55_bytes:
  .byte $77, $00, $00, $00, $00, $01
cmd41_bytes:
  .byte $69, $40, $00, $00, $00, $01



sd_readbyte:
  ; Enable the card and tick the clock 8 times with MOSI high, 
  ; capturing bits from MISO and returning them

  ldx #8                      ; we'll read 8 bits
sdreadloop:

  lda #SD_MOSI                ; enable card (CS low), set MOSI (resting state), SCK low
  sta PORTA

  lda #SD_MOSI | SD_SCK       ; toggle the clock high
  sta PORTA

  lda PORTA                   ; read next bit
  and #SD_MISO

  clc                         ; default to clearing the bottom bit
  beq bitnotset              ; unless MISO was set
  sec                         ; in which case get ready to set the bottom bit
bitnotset:

  tya                         ; transfer partial result from Y
  rol                         ; rotate carry bit into read result
  tay                         ; save partial result back to Y

  dex                         ; decrement counter
  bne sdreadloop                   ; loop if we need to read more bits

  rts


sd_writebyte:
  ; Tick the clock 8 times with descending bits on MOSI
  ; SD communication is mostly half-duplex so we ignore anything it sends back here

  ldx #8                      ; send 8 bits

sdwriteloop:
  asl                         ; shift next bit into carry
  tay                         ; save remaining bits for later

  lda #0
  bcc sendbit                ; if carry clear, don't set MOSI for this bit
  ora #SD_MOSI

sendbit:
  sta PORTA                   ; set MOSI (or not) first with SCK low
  eor #SD_SCK
  sta PORTA                   ; raise SCK keeping MOSI the same, to send the bit

  tya                         ; restore remaining bits to send

  dex
  bne sdwriteloop                   ; loop if there are more bits to send

  rts


sd_waitresult:
  ; Wait for the SD card to return something other than $ff
  jsr sd_readbyte
  cmp #$ff
  beq sd_waitresult
  rts


sd_sendcommand:
  ; Debug print which command is being executed
  lda #'c'
  jsr print_char
  ldx #0
  lda (zp_sd_cmd_address,x)
  jsr print_hex

  lda #SD_MOSI           ; pull CS low to begin command
  sta PORTA

  ldy #0
  lda (zp_sd_cmd_address),y    ; command byte
  jsr sd_writebyte
  ldy #1
  lda (zp_sd_cmd_address),y    ; data 1
  jsr sd_writebyte
  ldy #2
  lda (zp_sd_cmd_address),y    ; data 2
  jsr sd_writebyte
  ldy #3
  lda (zp_sd_cmd_address),y    ; data 3
  jsr sd_writebyte
  ldy #4
  lda (zp_sd_cmd_address),y    ; data 4
  jsr sd_writebyte
  ldy #5
  lda (zp_sd_cmd_address),y    ; crc
  jsr sd_writebyte

  jsr sd_waitresult
  pha

  ; Debug print the result code
  jsr print_hex

  ; End command
  lda #SD_CS | SD_MOSI   ; set CS high again
  sta PORTA

  pla   ; restore result code
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
print_nybble:
  and #15
  cmp #10
  bmi skipletter
  adc #6
skipletter:
  adc #48
  jsr print_char
  rts


delay:
  ldx #0
  ldy #0
delayloop:
  dey
  bne delayloop
  dex
  bne delayloop
  rts

longdelay:
  jsr mediumdelay
  jsr mediumdelay
  jsr mediumdelay
mediumdelay:
  jsr delay
  jsr delay
  jsr delay
  jmp delay


  .org $fffc
  .word reset
  .word $0000
