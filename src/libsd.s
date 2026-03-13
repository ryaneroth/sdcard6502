; SD card interface module
;
; Requires zero-page variable storage:
;   zp_sd_address - 2 bytes
;   zp_sd_currentsector - 4 bytes

; Zero-page scratch accumulator used by SD read paths.
sd_read_bits = $AF
; Stream-read state for CMD18 multi-block reads.
sd_stream_active = $04F0
sd_stream_nextsector = $04F1 ; 4 bytes
sd_stream_enabled = $04F5

sd_init:
  lda #0
  sta sd_stream_active
  lda #1
  sta sd_stream_enabled
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
  ; capturing bits from MISO and returning them.
  ; Uses sd_read_bits as accumulator via ROL (8 ROLs shift out initial value).
  ; Result returned in A. Y preserved.
  tya
  pha
  ldx #SD_MOSI
  ldy #SD_MOSI | SD_SCK

  stx PORTA                   ; bit 7
  sty PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  rol sd_read_bits

  stx PORTA                   ; bit 6
  sty PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  rol sd_read_bits

  stx PORTA                   ; bit 5
  sty PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  rol sd_read_bits

  stx PORTA                   ; bit 4
  sty PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  rol sd_read_bits

  stx PORTA                   ; bit 3
  sty PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  rol sd_read_bits

  stx PORTA                   ; bit 2
  sty PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  rol sd_read_bits

  stx PORTA                   ; bit 1
  sty PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  rol sd_read_bits

  stx PORTA                   ; bit 0
  sty PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  rol sd_read_bits

  pla
  tay
  lda sd_read_bits
  rts


sd_writebyte:
  ; Tick the clock 8 times with descending bits on MOSI
  ; SD communication is mostly half-duplex so we ignore anything it sends back here

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

  rts


sd_waitresult:
  ; Wait for the SD card to return something other than $ff.
  ; Timeout prevents hard lock when card/serial bus gets wedged.
  txa
  pha
  tya
  pha
  ldx #$20
  ldy #$00
_waitloop:
  jsr sd_readbyte
  cmp #$ff
  bne _waitloop_done
  dey
  bne _waitloop
  dex
  bne _waitloop
  lda #$ff
_waitloop_done:
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
  lda sd_stream_active
  beq :+
  jsr sd_abortstream
:
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

sd_stream_readblock:
  ; Wait for next data token in an active multi-block read stream.
  jsr sd_waitresult
  cmp #$fe
  beq :+
  jmp _read_fail
:

  jsr _readpage
  inc zp_sd_address+1
  jsr _readpage
  dec zp_sd_address+1

  ; Consume trailing CRC from the card.
  jsr sd_readbyte
  jsr sd_readbyte

  ; Advance expected next sector.
  inc sd_stream_nextsector
  bne :+
  inc sd_stream_nextsector+1
  bne :+
  inc sd_stream_nextsector+2
  bne :+
  inc sd_stream_nextsector+3
:
  clc
  rts

sd_abortstream:
  lda sd_stream_active
  beq :+
  ; While CS is low, issue CMD12 (STOP_TRANSMISSION).
  lda #$4c
  jsr sd_writebyte
  lda #$00
  jsr sd_writebyte
  jsr sd_writebyte
  jsr sd_writebyte
  jsr sd_writebyte
  lda #$01
  jsr sd_writebyte
  ; CMD12 has one stuff byte before its R1 response.
  jsr sd_readbyte
  jsr sd_waitresult
  ; Wait until card releases DO high again.
_abort_wait_idle:
  jsr sd_readbyte
  cmp #$ff
  bne _abort_wait_idle
  lda #SD_CS | SD_MOSI
  sta PORTA
  jsr sd_clockbyte_cs_high
  lda #0
  sta sd_stream_active
: clc
  rts


sd_readsector:
  ; Read a sector from the SD card.  A sector is 512 bytes.
  ;
  ; Parameters:
  ;    zp_sd_currentsector   32-bit sector number
  ;    zp_sd_address     address of buffer to receive data

  lda sd_stream_enabled
  beq sd_readsector_single      ; streaming disabled: use single-block CMD17

  ; Continue active CMD18 stream if caller is reading the next physical sector.
  lda sd_stream_active
  beq _startstream
  lda zp_sd_currentsector
  cmp sd_stream_nextsector
  bne _restartstream
  lda zp_sd_currentsector+1
  cmp sd_stream_nextsector+1
  bne _restartstream
  lda zp_sd_currentsector+2
  cmp sd_stream_nextsector+2
  bne _restartstream
  lda zp_sd_currentsector+3
  cmp sd_stream_nextsector+3
  bne _restartstream
  jmp sd_stream_readblock

_restartstream:
  jsr sd_abortstream

_startstream:
  ; Ensure card sees idle clocks before selecting and issuing CMD18.
  jsr sd_clockbyte_cs_high
  lda #SD_MOSI
  sta PORTA

  ; Command 18, arg is sector number, crc not checked
  lda #$52                    ; CMD18 - READ_MULTIPLE_BLOCK
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

  lda zp_sd_currentsector
  sta sd_stream_nextsector
  lda zp_sd_currentsector+1
  sta sd_stream_nextsector+1
  lda zp_sd_currentsector+2
  sta sd_stream_nextsector+2
  lda zp_sd_currentsector+3
  sta sd_stream_nextsector+3
  lda #1
  sta sd_stream_active
  jmp sd_stream_readblock

sd_readsector_single:
  ; Legacy single-block sector read path (CMD17).
  jsr sd_clockbyte_cs_high
  lda #SD_MOSI
  sta PORTA

  lda #$51                    ; CMD17 - READ_SINGLE_BLOCK
  jsr sd_writebyte
  lda zp_sd_currentsector+3
  jsr sd_writebyte
  lda zp_sd_currentsector+2
  jsr sd_writebyte
  lda zp_sd_currentsector+1
  jsr sd_writebyte
  lda zp_sd_currentsector
  jsr sd_writebyte
  lda #$01
  jsr sd_writebyte

  jsr sd_waitresult
  cmp #$00
  bne _read_fail
  jsr sd_waitresult
  cmp #$fe
  bne _read_fail

  jsr _readpage
  inc zp_sd_address+1
  jsr _readpage
  dec zp_sd_address+1

  jsr sd_readbyte
  jsr sd_readbyte

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
  lda #0
  sta sd_stream_active
  jmp _libsdfail

_readpage:
  ; Read 256 bytes to the address at zp_sd_address.
  ; Fully unrolled bit read path keeps MOSI-low in X and avoids loop overhead.
  ; Bit 0 uses lda/rol-a to deliver the byte directly in A.
  ldx #SD_MOSI
  ldy #0
_readpageloop:
  stx PORTA                   ; bit 7
  lda #SD_MOSI | SD_SCK
  sta PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  rol sd_read_bits

  stx PORTA                   ; bit 6
  lda #SD_MOSI | SD_SCK
  sta PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  rol sd_read_bits

  stx PORTA                   ; bit 5
  lda #SD_MOSI | SD_SCK
  sta PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  rol sd_read_bits

  stx PORTA                   ; bit 4
  lda #SD_MOSI | SD_SCK
  sta PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  rol sd_read_bits

  stx PORTA                   ; bit 3
  lda #SD_MOSI | SD_SCK
  sta PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  rol sd_read_bits

  stx PORTA                   ; bit 2
  lda #SD_MOSI | SD_SCK
  sta PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  rol sd_read_bits

  stx PORTA                   ; bit 1
  lda #SD_MOSI | SD_SCK
  sta PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  rol sd_read_bits

  stx PORTA                   ; bit 0 (LSB) - merge accumulate+load via rol a
  lda #SD_MOSI | SD_SCK
  sta PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  lda sd_read_bits             ; load bits 7..1 in place; carry holds bit 0
  rol a                        ; shift carry into bit 0, completing the byte

  sta (zp_sd_address),y
  iny
  beq :+                       ; exit when Y wraps to 0 (256 bytes done)
  jmp _readpageloop            ; bne can't reach _readpageloop (loop body > 128 bytes)
:
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

  lda sd_stream_active
  beq :+
  jsr sd_abortstream
:

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
  ; Write 256 bytes fom zp_sd_address
  ldy #0
_writeloop:
  tya ; transfer counter to a register
  pha ; push counter to stack
  lda (zp_sd_address),y
  jsr sd_writebyte
  pla ; pull counter from stack
  tay ; transfer back
  iny
  bne _writeloop
  rts
