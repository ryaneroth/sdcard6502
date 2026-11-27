; SD card interface module: an SD card in SPI mode, bit-banged on a 6522 or
; 6530 port (see hwconfig.s for the port and pin assignments).
;
; Handles SDHC/SDXC cards (block addressed) and standard-capacity cards,
; version 1 or 2 (byte addressed; sd_init sets 512-byte blocks).
;
; Arguments, in zero page:
;   zp_sd_address        buffer pointer for a sector read or write
;   zp_sd_currentsector  the sector number (4 bytes)
;
; Routines (C=1 on failure):
;   sd_init         wake the card and put it in SPI mode
;   sd_readsector   read sector zp_sd_currentsector to (zp_sd_address)
;   sd_writesector  write sector zp_sd_currentsector from (zp_sd_address)
;
; Variables are in the ZEROPAGE and BSS segments.

.pushseg
.segment "ZEROPAGE"
zp_sd_address:          .res 2
zp_sd_currentsector:    .res 4
sd_read_bits:   .res 1          ; bit accumulator for reads
.segment "BSS"
sd_tries:       .res 1          ; sd_init attempts left
sd_count:       .res 1          ; retry / timeout counter
; What kind of card: bit 0 set for an SDHC/SDXC card (block addressed),
; clear for a standard-capacity card (byte addressed).  During sd_init,
; bit 7 is set for a version 2 card.
sd_cardtype:    .res 1
.popseg


.proc sd_init
  ; Let the SD card boot up, by pumping the clock with SD CS disabled.
  ; We need to apply around 80 clock pulses with CS and MOSI high.
  ; Normally MOSI doesn't matter when CS is high, but the card is
  ; not yet in SPI mode, and in this non-SPI state it does care.
  lda #2                      ; two attempts
  sta sd_tries
retry:
  lda #SD_CS | SD_MOSI
  ldx #160                    ; toggle the clock 160 times, so 80 low-high transitions
preinit:
  eor #SD_SCK
  sta PORTA
  dex
  bne preinit

  ; CMD0, GO_IDLE_STATE: reset the card to idle state, in SPI mode
  lda #<sd_cmd0_bytes
  ldx #>sd_cmd0_bytes
  jsr sd_sendcommand_ax
  cmp #$01                    ; idle
  bne failnear

  ; CMD8, SEND_IF_COND: tell the card how we want it to operate (3.3V).
  ; A version 2 card answers $01 (idle) and echoes the check pattern; a
  ; version 1 card (standard capacity only) says $05, illegal command.
  lda #<sd_cmd8_bytes
  ldx #>sd_cmd8_bytes
  jsr sd_command_ax
  ldx #$00
  cmp #$05
  beq cmd8done
  cmp #$01
  bne cmd8failnear
  jsr sd_readbyte
  jsr sd_readbyte
  jsr sd_readbyte             ; voltage accepted
  and #$0f
  cmp #$01
  bne cmd8failnear
  jsr sd_readbyte             ; check pattern
  cmp #$aa
  bne cmd8failnear
  ldx #$80
cmd8done:
  stx sd_cardtype             ; bit 7: version 2 card
  jsr sd_endcommand

  ; Give the card up to 16 tries (about 5 seconds) to initialise.
  lda #16
  sta sd_count
  jmp cmd55

  ; (The failure paths are out of branch range from here.)
failnear:
  jmp failed
cmd8failnear:
  jmp cmd8failed

cmd55:
  ; CMD55, APP_CMD: prefix for ACMD41
  lda #<sd_cmd55_bytes
  ldx #>sd_cmd55_bytes
  jsr sd_sendcommand_ax
  cmp #$01
  bne failed

  ; ACMD41, APP_SEND_OP_COND: start initialisation.  A version 2 card is
  ; told we handle high capacity (HCS); a version 1 card must not be.
  lda #<sd_cmd41_bytes
  ldx #>sd_cmd41_bytes
  bit sd_cardtype
  bmi :+
  lda #<sd_cmd41v1_bytes
  ldx #>sd_cmd41v1_bytes
:
  jsr sd_sendcommand_ax
  cmp #$00                    ; ready
  beq initialized
  cmp #$01                    ; still initialising
  bne failed

  ; Not initialized yet, so wait a while then try again.
  dec sd_count
  beq failed
  ldx #0
  ldy #0
delay:
  dey
  bne delay
  dex
  bne delay
  jmp cmd55

initialized:
  ; Block or byte addressing?  A version 2 card says in its OCR (CMD58,
  ; the CCS bit); a version 1 card is always byte addressed.
  bit sd_cardtype
  bpl byteaddressed
  lda #<sd_cmd58_bytes
  ldx #>sd_cmd58_bytes
  jsr sd_command_ax
  cmp #$00
  bne cmd8failed
  jsr sd_readbyte             ; OCR bits 31-24: bit 30 is CCS
  pha
  jsr sd_readbyte
  jsr sd_readbyte
  jsr sd_readbyte
  jsr sd_endcommand
  pla
  and #$40
  beq byteaddressed
  lda #1
  sta sd_cardtype
  clc
  rts

byteaddressed:
  ; Standard capacity: make sure blocks are 512 bytes (CMD16).
  lda #0
  sta sd_cardtype
  lda #<sd_cmd16_bytes
  ldx #>sd_cmd16_bytes
  jsr sd_sendcommand_ax
  cmp #$00
  bne failed
  clc
  rts

cmd8failed:
  jsr sd_endcommand
failed:
  dec sd_tries
  beq :+
  jmp retry
:
  sec
  rts
.endproc

sd_cmd0_bytes:
  .byte $40, $00, $00, $00, $00, $95
sd_cmd8_bytes:
  .byte $48, $00, $00, $01, $aa, $87
sd_cmd16_bytes:
  .byte $50, $00, $00, $02, $00, $01
sd_cmd55_bytes:
  .byte $77, $00, $00, $00, $00, $01
sd_cmd41_bytes:
  .byte $69, $40, $00, $00, $00, $01
sd_cmd41v1_bytes:
  .byte $69, $00, $00, $00, $00, $01
sd_cmd58_bytes:
  .byte $7a, $00, $00, $00, $00, $01


.proc sd_readbyte
  ; Tick the clock 8 times with MOSI high, capturing bits from MISO.
  ; Returns the byte in A.  Uses X; Y preserved.
  tya
  pha
  ldx #SD_MOSI
  ldy #SD_MOSI | SD_SCK
  .repeat 8
  stx PORTA
  sty PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  rol sd_read_bits
  .endrepeat
  pla
  tay
  lda sd_read_bits
  rts
.endproc


.proc sd_writebyte
  ; Tick the clock 8 times with the bits of A, high bit first, on MOSI.
  ; SD communication is mostly half-duplex so we ignore anything it sends
  ; back here.  Uses A, X and Y.
  ldx #8
loop:
  asl                         ; next bit into carry
  tay                         ; save remaining bits for later
  lda #0
  bcc sendbit                 ; if carry clear, don't set MOSI for this bit
  ora #SD_MOSI
sendbit:
  sta PORTA                   ; set MOSI (or not) first with SCK low
  eor #SD_SCK
  sta PORTA                   ; raise SCK keeping MOSI the same, to send the bit
  tya
  dex
  bne loop
  rts
.endproc


.proc sd_waitresult
  ; Wait for the SD card to return something other than $ff, and return
  ; it in A ($ff after a timeout).  X and Y preserved.
  txa
  pha
  tya
  pha
  ldx #$20
  ldy #$00
loop:
  jsr sd_readbyte
  cmp #$ff
  bne done
  dey
  bne loop
  dex
  bne loop
  lda #$ff
done:
  tax
  pla
  tay
  pla
  txa
  rts
.endproc


.proc sd_clockbyte_cs_high
  ; Provide 8 idle clocks with CS high between command transactions.
  ldx #8
loop:
  lda #SD_CS | SD_MOSI
  sta PORTA
  lda #SD_CS | SD_MOSI | SD_SCK
  sta PORTA
  dex
  bne loop
  lda #SD_CS | SD_MOSI
  sta PORTA
  rts
.endproc


sd_sendcommand_ax:
  ; Send the 6-byte command at A (low) / X (high) and return its R1
  ; response in A, with the card deselected again.
  jsr sd_command_ax
  ; fall through

.proc sd_endcommand
  ; Deselect the card after a command, keeping A.
  pha
  lda #SD_CS | SD_MOSI
  sta PORTA
  jsr sd_clockbyte_cs_high
  pla
  rts
.endproc

.proc sd_command_ax
  ; Send the 6-byte command at A (low) / X (high) and return its R1
  ; response in A, leaving the card selected to read the rest of a longer
  ; response.  Uses zp_sd_address.
  sta zp_sd_address
  stx zp_sd_address+1
  ; At least one full idle byte with CS high before selecting the card.
  jsr sd_clockbyte_cs_high
  lda #SD_MOSI                ; pull CS low to begin command
  sta PORTA
  ldy #0
loop:
  tya
  pha
  lda (zp_sd_address),y
  jsr sd_writebyte
  pla
  tay
  iny
  cpy #6
  bne loop
  jmp sd_waitresult
.endproc


.proc sd_startblockcommand
  ; Select the card and send the read or write command in A for sector
  ; zp_sd_currentsector, with the address the card wants: the sector
  ; number for a block-addressed card, sector * 512 for a byte-addressed
  ; one.  Returns the R1 response in A, the card still selected.
  pha
  jsr sd_clockbyte_cs_high
  lda #SD_MOSI
  sta PORTA
  pla
  jsr sd_writebyte
  lda sd_cardtype
  lsr
  bcc byteaddress
  lda zp_sd_currentsector+3   ; sector 24:31
  jsr sd_writebyte
  lda zp_sd_currentsector+2   ; sector 16:23
  jsr sd_writebyte
  lda zp_sd_currentsector+1   ; sector 8:15
  jsr sd_writebyte
  lda zp_sd_currentsector     ; sector 0:7
  jmp crc
byteaddress:
  lda zp_sd_currentsector+1
  asl
  lda zp_sd_currentsector+2
  rol                         ; byte address 24:31
  jsr sd_writebyte
  lda zp_sd_currentsector
  asl
  lda zp_sd_currentsector+1
  rol                         ; byte address 16:23
  jsr sd_writebyte
  lda zp_sd_currentsector
  asl                         ; byte address 8:15
  jsr sd_writebyte
  lda #0                      ; byte address 0:7
crc:
  jsr sd_writebyte
  lda #$01                    ; crc (not checked)
  jsr sd_writebyte
  jmp sd_waitresult
.endproc


.proc sd_readsector
  ; Read a 512-byte sector.
  ;    zp_sd_currentsector   sector number
  ;    zp_sd_address         buffer to receive the data
  ; C=1 if the card did not return it.
  lda #$51                    ; CMD17, READ_SINGLE_BLOCK
  jsr sd_startblockcommand
  cmp #$00
  bne fail
  jsr sd_waitresult           ; data token
  cmp #$fe
  bne fail
  jsr sd_readpage
  inc zp_sd_address+1
  jsr sd_readpage
  dec zp_sd_address+1
  jsr sd_readbyte             ; CRC, ignored
  jsr sd_readbyte
  lda #SD_CS | SD_MOSI
  sta PORTA
  jsr sd_clockbyte_cs_high
  clc
  rts
fail:
  jmp sd_failcommand
.endproc


.proc sd_readpage
  ; Read 256 bytes to (zp_sd_address).
  ; Fully unrolled bit reads keep MOSI-low in X; bit 0 is rotated
  ; straight into A.
  ldx #SD_MOSI
  ldy #0
loop:
  .repeat 7
  stx PORTA
  lda #SD_MOSI | SD_SCK
  sta PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  rol sd_read_bits
  .endrepeat
  stx PORTA                   ; bit 0
  lda #SD_MOSI | SD_SCK
  sta PORTA
  lda PORTA
  and #SD_MISO
  cmp #1
  lda sd_read_bits            ; bits 7..1; carry holds bit 0
  rol a
  sta (zp_sd_address),y
  iny
  beq :+
  jmp loop                    ; the loop body is too long for bne
:
  rts
.endproc


.proc sd_writesector
  ; Write a 512-byte sector.
  ;    zp_sd_currentsector   sector number
  ;    zp_sd_address         buffer to take the data from
  ; C=1 if the card did not accept it.
  lda #$58                    ; CMD24, WRITE_BLOCK
  jsr sd_startblockcommand
  cmp #$00
  bne fail
  lda #$fe                    ; start token
  jsr sd_writebyte
  jsr sd_writepage
  inc zp_sd_address+1
  jsr sd_writepage
  dec zp_sd_address+1
  lda #$ff                    ; CRC, ignored but required
  jsr sd_writebyte
  lda #$ff
  jsr sd_writebyte
  jsr sd_waitresult           ; data response
  and #$1f
  cmp #$05                    ; accepted
  bne fail

  ; Wait while the card is busy (it holds MISO low), for up to about
  ; three seconds.
  lda #$40
  sta sd_count
  ldy #0
wait:
  jsr sd_readbyte
  cmp #$ff
  beq idle
  dey
  bne wait
  dec sd_count
  bne wait
  jmp fail
idle:
  lda #SD_CS | SD_MOSI
  sta PORTA
  jsr sd_clockbyte_cs_high
  clc
  rts
fail:
  jmp sd_failcommand
.endproc


.proc sd_failcommand
  ; Deselect the card and return an error.
  lda #SD_CS | SD_MOSI
  sta PORTA
  jsr sd_clockbyte_cs_high
  sec
  rts
.endproc


.proc sd_writepage
  ; Write 256 bytes from (zp_sd_address).
  ; Unrolled: each bit sets MOSI with SCK low, then raises SCK.
  ldy #0
loop:
  lda (zp_sd_address),y
  sta sd_read_bits
  .repeat 8
  lda #0
  asl sd_read_bits
  bcc :+
  lda #SD_MOSI
: sta PORTA
  ora #SD_SCK
  sta PORTA
  .endrepeat
  iny
  beq :+
  jmp loop                    ; the loop body is too long for bne
:
  rts
.endproc
