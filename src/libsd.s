; SD card interface module
;
; Requires zero-page variable storage:
;   zp_sd_address - 2 bytes
;   zp_sd_currentsector - 4 bytes

; Scratch RAM for tight polling paths.
sd_wait_hi = $06F5
sd_wait_lo = $06F6

sd_init:
  ; Let the SD card boot up, by pumping the clock with SD CS disabled

  ; We need to apply around 80 clock pulses with CS and MOSI high.
  ; Normally MOSI doesn't matter when CS is high, but the card is
  ; not yet is SPI mode, and in this non-SPI state it does care.
  ldy #0
_initretry:
  lda #SD_CS | SD_MOSI
  ldx #160               ; toggle the clock 160 times, so 80 low-high transitions
_preinitloop:
  eor #SD_SCK
  sta PORTA
  dex
  bne _preinitloop

_cmd0: ; GO_IDLE_STATE - resets card to idle state, and SPI mode
  lda #<sd_cmd0_bytes
  sta zp_sd_address
  lda #>sd_cmd0_bytes
  sta zp_sd_address+1

  jsr sd_sendcommand

  ; Expect status response $01 (not initialized)
  cmp #$01
  bne _initfailed

_cmd8: ; SEND_IF_COND - tell the card how we want it to operate (3.3V, etc)
  lda #<sd_cmd8_bytes
  sta zp_sd_address
  lda #>sd_cmd8_bytes
  sta zp_sd_address+1

  jsr sd_sendcommand

  ; Expect status response $01 (not initialized)
  cmp #$01
  bne _initfailed

  ; Read 32-bit return value, but ignore it
  jsr sd_readbyte
  jsr sd_readbyte
  jsr sd_readbyte
  jsr sd_readbyte

_cmd55: ; APP_CMD - required prefix for ACMD commands
  lda #<sd_cmd55_bytes
  sta zp_sd_address
  lda #>sd_cmd55_bytes
  sta zp_sd_address+1

  jsr sd_sendcommand

  ; Expect status response $01 (not initialized)
  cmp #$01
  bne _initfailed

_cmd41: ; APP_SEND_OP_COND - send operating conditions, initialize card
  lda #<sd_cmd41_bytes
  sta zp_sd_address
  lda #>sd_cmd41_bytes
  sta zp_sd_address+1

  jsr sd_sendcommand

  ; Status response $00 means initialised
  cmp #$00
  beq _initialized

  ; Otherwise expect status response $01 (not initialized)
  cmp #$01
  bne _initfailed

  ; Not initialized yet, so wait a while then try again.
  ; This retry is important, to give the card time to initialize.

  ldx #0
  ldy #0
_delayloop:
  dey
  bne _delayloop
  dex
  bne _delayloop

  jmp _cmd55


_initialized:
  clc
  rts

_initfailed:
  iny
  cpy #2
  beq :+
  jmp _initretry
:
  sec
  rts


sd_cmd0_bytes:
  .byte $40, $00, $00, $00, $00, $95
sd_cmd8_bytes:
  .byte $48, $00, $00, $01, $aa, $87
sd_cmd55_bytes:
  .byte $77, $00, $00, $00, $00, $01
sd_cmd41_bytes:
  .byte $69, $40, $00, $00, $00, $01



sd_readbyte:
  ; Enable the card and tick the clock 8 times with MOSI high,
  ; capturing bits from MISO and returning them
  tya
  pha
  ldy #8
  ldx #0

_rbloop:
  txa
  asl
  tax

  lda #SD_MOSI                ; enable card (CS low), set MOSI (resting state), SCK low
  sta PORTA

  lda #SD_MOSI | SD_SCK       ; toggle the clock high
  sta PORTA

  lda PORTA                   ; read next bit
  and #SD_MISO

  clc                         ; default to clearing the bottom bit
  beq _bitnotset              ; unless MISO was set
  sec                         ; in which case get ready to set the bottom bit
_bitnotset:
  bcc :+
  inx
:
  dey
  bne _rbloop

  txa
  tax                         ; preserve result while restoring caller Y
  pla
  tay
  txa
  rts


sd_writebyte:
  ; Tick the clock 8 times with descending bits on MOSI
  ; SD communication is mostly half-duplex so we ignore anything it sends back here
  ; Preserve Y so callers can stream bytes without per-call stack shuffling.
  tya
  pha

  ldx #8                      ; send 8 bits

_wbloop:
  asl                         ; shift next bit into carry
  tay                         ; save remaining bits for later

  lda #0
  bcc _sendbit                ; if carry clear, don't set MOSI for this bit
  ora #SD_MOSI

_sendbit:
  sta PORTA                   ; set MOSI (or not) first with SCK low
  eor #SD_SCK
  sta PORTA                   ; raise SCK keeping MOSI the same, to send the bit

  tya                         ; restore remaining bits to send

  dex
  bne _wbloop                   ; loop if there are more bits to send

  pla
  tay
  rts


sd_waitresult:
  ; Wait for the SD card to return something other than $ff.
  ; Timeout prevents hard lock when card/serial bus gets wedged.
  txa
  pha
  tya
  pha
  lda #$20
  sta sd_wait_hi
  lda #$00
  sta sd_wait_lo
_waitloop:
  ; Inline a byte read here to avoid JSR/RTS + save/restore overhead while polling.
  ldx #0
  ldy #8
_waitbitloop:
  txa
  asl
  tax

  lda #SD_MOSI
  sta PORTA
  lda #SD_MOSI | SD_SCK
  sta PORTA

  lda PORTA
  and #SD_MISO
  beq :+
  inx
:
  dey
  bne _waitbitloop

  txa
  cmp #$ff
  bne _done
  dec sd_wait_lo
  bne _waitloop
  dec sd_wait_hi
  bne _waitloop
  lda #$ff
_done:
  tax
  pla
  tay
  pla
  txa
  rts

sd_clockbyte_cs_high:
  ; Provide 8 idle clocks with CS high between command transactions.
  ldx #8
_clockloop:
  lda #SD_CS | SD_MOSI
  sta PORTA
  lda #SD_CS | SD_MOSI | SD_SCK
  sta PORTA
  dex
  bne _clockloop
  lda #SD_CS | SD_MOSI
  sta PORTA
  rts


sd_sendcommand:
  ; Ensure at least one full idle byte with CS high before selecting the card.
  jsr sd_clockbyte_cs_high

  lda #SD_MOSI           ; pull CS low to begin command
  sta PORTA

  ldy #0
  lda (zp_sd_address),y    ; command byte
  jsr sd_writebyte
  ldy #1
  lda (zp_sd_address),y    ; data 1
  jsr sd_writebyte
  ldy #2
  lda (zp_sd_address),y    ; data 2
  jsr sd_writebyte
  ldy #3
  lda (zp_sd_address),y    ; data 3
  jsr sd_writebyte
  ldy #4
  lda (zp_sd_address),y    ; data 4
  jsr sd_writebyte
  ldy #5
  lda (zp_sd_address),y    ; crc
  jsr sd_writebyte

  jsr sd_waitresult
  pha

  ; End command
  lda #SD_CS | SD_MOSI   ; set CS high again
  sta PORTA
  jsr sd_clockbyte_cs_high

  pla   ; restore result code
  rts


sd_readsector:
  ; Read a sector from the SD card.  A sector is 512 bytes.
  ;
  ; Parameters:
  ;    zp_sd_currentsector   32-bit sector number
  ;    zp_sd_address     address of buffer to receive data

  ; Ensure card sees idle clocks before selecting and issuing CMD17.
  jsr sd_clockbyte_cs_high
  lda #SD_MOSI
  sta PORTA

  ; Command 17, arg is sector number, crc not checked
  lda #$51                    ; CMD17 - READ_SINGLE_BLOCK
  jsr sd_writebyte
  lda zp_sd_currentsector+3   ; sector 24:31
  jsr sd_writebyte
  lda zp_sd_currentsector+2   ; sector 16:23
  jsr sd_writebyte
  lda zp_sd_currentsector+1   ; sector 8:15
  jsr sd_writebyte
  lda zp_sd_currentsector     ; sector 0:7
  jsr sd_writebyte
  lda #$01                    ; crc (not checked)
  jsr sd_writebyte

  jsr sd_waitresult           ; R1
  cmp #$00
  bne _read_fail

  ; wait for data token
  jsr sd_waitresult
  cmp #$fe
  bne _read_fail

  ; Need to read 512 bytes - two pages of 256 bytes each
  jsr _readpage
  inc zp_sd_address+1
  jsr _readpage
  dec zp_sd_address+1

  ; Consume trailing 16-bit CRC from the card to keep SPI stream aligned.
  jsr sd_readbyte
  jsr sd_readbyte

  ; End command
  lda #SD_CS | SD_MOSI
  sta PORTA
  jsr sd_clockbyte_cs_high

  clc
  rts

_read_fail:
  ; Abort transaction and return error.
  lda #SD_CS | SD_MOSI
  sta PORTA
  jsr sd_clockbyte_cs_high
  jmp _libsdfail

_readpage:
  ; Read 256 bytes to the address at zp_sd_address
  ldy #0
_readpageloop:
  ; Keep unrolled bit reads for speed, but define the repeated sequence
  ; as a macro so the hot path stays maintainable.
  .macro SD_READBIT
    txa
    asl
    tax

    lda #SD_MOSI                ; CS low, MOSI high, SCK low
    sta PORTA
    lda #SD_MOSI | SD_SCK       ; raise SCK
    sta PORTA

    lda PORTA
    and #SD_MISO
    beq :+
    inx
  :
  .endmacro

  ldx #0
  SD_READBIT
  SD_READBIT
  SD_READBIT
  SD_READBIT
  SD_READBIT
  SD_READBIT
  SD_READBIT
  SD_READBIT

  txa
  sta (zp_sd_address),y
  iny
  bne _readpageloop
  rts

_libsdfail:
  ; Return error instead of hard-locking, so callers can unwind cleanly.
  sec
  rts

sd_writesector:
  ; Write a sector to the SD card.  A sector is 512 bytes.
  ;
  ; Parameters:
  ;    zp_sd_currentsector   32-bit sector number
  ;    zp_sd_address     address of buffer to take data from

  ; Ensure card sees idle clocks before selecting and issuing CMD24.
  jsr sd_clockbyte_cs_high
  lda #SD_MOSI
  sta PORTA

  ; Command 24, arg is sector number, crc not checked
  lda #$58                    ; CMD24 - WRITE_BLOCK
  jsr sd_writebyte
  lda zp_sd_currentsector+3   ; sector 24:31
  jsr sd_writebyte
  lda zp_sd_currentsector+2   ; sector 16:23
  jsr sd_writebyte
  lda zp_sd_currentsector+1   ; sector 8:15
  jsr sd_writebyte
  lda zp_sd_currentsector     ; sector 0:7
  jsr sd_writebyte
  lda #$01                    ; crc (not checked)
  jsr sd_writebyte

  jsr sd_waitresult
  cmp #$00
  bne _libsdfail

  ; Send start token
  lda #$fe
  jsr sd_writebyte

  ; Need to write 512 bytes - two pages of 256 bytes each
  jsr _writepage
  inc zp_sd_address+1
  jsr _writepage
  dec zp_sd_address+1

  ; Send trailing CRC bytes (ignored by card when CRC is off, but still required).
  lda #$ff
  jsr sd_writebyte
  lda #$ff
  jsr sd_writebyte

  ; wait for data response
  jsr sd_waitresult
  and #$1f
  cmp #$05
  bne _libsdfail

_waitidle:
  jsr sd_readbyte
  cmp #$ff
  bne _waitidle

  ; End command
  lda #SD_CS | SD_MOSI ; set cs and mosi high (disconnected)
  sta PORTA
  jsr sd_clockbyte_cs_high

  clc
  rts

_writepage:
  ; Write 256 bytes from zp_sd_address
  ldy #0
_writeloop:
  lda (zp_sd_address),y
  jsr sd_writebyte
  iny
  bne _writeloop
  rts
