zp_sd_address = $40         ; 2 bytes
zp_sd_currentsector = $42   ; 4 bytes
zp_fat32_variables = $46    ; 52 bytes

fat32_workspace = $200      ; two pages

; Keep traversal state well away from page $0100 (6502 hardware stack)
dir_cluster_stack = $600    ; MAX_DEPTH * 4 bytes
dir_index_stack = $640      ; MAX_DEPTH * 2 bytes
cur_depth = $680            ; 1 byte
depth_off2 = $681           ; 1 byte
depth_off4 = $682           ; 1 byte
skip_lo = $683              ; 1 byte
skip_hi = $684              ; 1 byte
child_cluster = $685        ; 4 bytes

MAX_DEPTH = 12

  .org $A000
reset:
  ldx #$ff
  txs

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
  jsr newline
  lda #'L'
  jsr print_char
  lda #'2'
  jsr print_char
  jsr newline

  ; Depth 0 starts at root cluster, index 0.
  lda #0
  sta cur_depth
  sta dir_index_stack
  sta dir_index_stack+1

  lda fat32_rootcluster
  sta dir_cluster_stack
  lda fat32_rootcluster+1
  sta dir_cluster_stack+1
  lda fat32_rootcluster+2
  sta dir_cluster_stack+2
  lda fat32_rootcluster+3
  sta dir_cluster_stack+3

walk_loop:
  jsr _set_depth_offsets

  ; Open directory for current depth.
  ldx depth_off4
  lda dir_cluster_stack,x
  sta fat32_cdcluster
  lda dir_cluster_stack+1,x
  sta fat32_cdcluster+1
  lda dir_cluster_stack+2,x
  sta fat32_cdcluster+2
  lda dir_cluster_stack+3,x
  sta fat32_cdcluster+3
  jsr fat32_open_cd

  ; Skip entries we've already processed at this depth.
  ldy depth_off2
  lda dir_index_stack,y
  sta skip_lo
  lda dir_index_stack+1,y
  sta skip_hi

_skip_loop:
  lda skip_lo
  ora skip_hi
  beq _after_skip
  jsr fat32_readdirent
  bcc _skip_ok
  jmp _end_of_dir
_skip_ok:
  lda skip_lo
  bne _dec_skip_lo
  dec skip_hi
_dec_skip_lo:
  dec skip_lo
  jmp _skip_loop

_after_skip:
  jsr fat32_readdirent
  bcc _read_ok
  jmp _end_of_dir
_read_ok:

  ; Consumed one more entry at this depth.
  ldx depth_off2
  inc dir_index_stack,x
  bne _print_entry
  inc dir_index_stack+1,x

_print_entry:
_print_name:
  jsr _print_indent
  ldy #0
_name_loop:
  tya
  pha
  lda (zp_sd_address),y
  jsr _print_name_char
  pla
  tay
  iny
  cpy #11
  bne _name_loop

  ; Print "." and ".." entries as normal lines, but don't descend.
  ldy #0
  lda (zp_sd_address),y
  cmp #'.'
  bne _check_dir_attr
  iny
  lda (zp_sd_address),y
  cmp #' '
  beq _dot_entry_done
  cmp #'.'
  beq _dot_entry_done

_check_dir_attr:
  ; Directory?
  ldy #11
  lda (zp_sd_address),y
  and #$10
  bne _descend_dir
  jmp _handle_file

_dot_entry_done:
  jsr newline
  jmp walk_loop

_descend_dir:
  lda #$5C
  jsr print_char
  jsr newline

  ; Read child cluster from the current dir entry.
  ldy #26
  lda (zp_sd_address),y
  sta child_cluster
  iny
  lda (zp_sd_address),y
  sta child_cluster+1
  ldy #20
  lda (zp_sd_address),y
  sta child_cluster+2
  iny
  lda (zp_sd_address),y
  sta child_cluster+3

  ; For zero-cluster directory entries, use root cluster.
  lda child_cluster
  ora child_cluster+1
  ora child_cluster+2
  ora child_cluster+3
  bne _push_child
  lda fat32_rootcluster
  sta child_cluster
  lda fat32_rootcluster+1
  sta child_cluster+1
  lda fat32_rootcluster+2
  sta child_cluster+2
  lda fat32_rootcluster+3
  sta child_cluster+3

_push_child:
  ; Cycle guard: do not descend if this cluster is already in the current path.
  ldx #0
_cycle_scan:
  txa
  asl
  asl
  tay
  lda dir_cluster_stack,y
  cmp child_cluster
  bne _cycle_next
  lda dir_cluster_stack+1,y
  cmp child_cluster+1
  bne _cycle_next
  lda dir_cluster_stack+2,y
  cmp child_cluster+2
  bne _cycle_next
  lda dir_cluster_stack+3,y
  cmp child_cluster+3
  bne _cycle_next
  jmp walk_loop
_cycle_next:
  inx
  cpx cur_depth
  bcc _cycle_scan
  beq _cycle_scan

  lda cur_depth
  cmp #(MAX_DEPTH-1)
  bcc _can_push
  jmp walk_loop
_can_push:
  inc cur_depth
  jsr _set_depth_offsets

  ldx depth_off4
  lda child_cluster
  sta dir_cluster_stack,x
  lda child_cluster+1
  sta dir_cluster_stack+1,x
  lda child_cluster+2
  sta dir_cluster_stack+2,x
  lda child_cluster+3
  sta dir_cluster_stack+3,x

  ldy depth_off2
  lda #0
  sta dir_index_stack,y
  sta dir_index_stack+1,y
  jmp walk_loop

_handle_file:
  jsr newline
  jmp walk_loop

_end_of_dir:
  lda cur_depth
  beq _done
  dec cur_depth
  jmp walk_loop

_done:
  jsr newline
  lda #'O'
  jsr print_char
  lda #'K'
  jsr print_char
  jsr newline

loop:
  jsr EXIT
  jmp loop

_set_depth_offsets:
  lda cur_depth
  asl
  sta depth_off2
  asl
  sta depth_off4
  rts

_print_indent:
  ldx cur_depth
  beq _indent_done
_indent_loop:
  lda #' '
  jsr print_char
  lda #' '
  jsr print_char
  dex
  bne _indent_loop
_indent_done:
  rts

_print_name_char:
  ; Emit only visible ASCII to keep terminal output stable.
  cmp #$20
  bcc _name_dot
  cmp #$7F
  bcs _name_dot
  jsr print_char
  rts
_name_dot:
  lda #'.'
  jsr print_char
  rts

  .include "hwconfig.s"
  .include "libsd.s"
  .include "libfat32.s"
  .include "libio.s"

  .word reset
  .word $0000
