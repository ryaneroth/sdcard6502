# 6502 FAT32 Library

`src/libsd.s` talks to the SD card; `src/libfat32.s` is a FAT32 file system
on top of it: files and directories by path, several files open at once,
reading, writing, appending, seeking, renaming and moving, making and
removing directories, and free space.

It works with SDHC/SDXC cards and with standard-capacity (2 GB and
smaller) cards, version 1 or 2, on a FAT32 volume: an MBR partition of type
`$0B` or `$0C`, or a card formatted without a partition table.

## Setup

`.include` `hwconfig.s` (the port and pins), `libsd.s` and `libfat32.s`,
and provide:

* `fat32_workspace`: a page-aligned 512-byte buffer, the sector cache.
* The `ZEROPAGE` and `BSS` segments in your linker configuration.  The
  library uses about 20 bytes of zero page and 300 bytes of other RAM.

The code is about 6.5 KB.  `src/examples.cfg` is a linker configuration for
the example programs (code in an EEPROM at `$A000`).

Start with:

```
  lda #PORTA_OUTPUTPINS     ; the SD card's pins on port A
  sta DDRA
  jsr sd_init               ; wake the card
  bcs no_card
  jsr fat32_init            ; mount the volume
  bcs no_volume
```

(`hwconfig.s` also has `via_init`, which makes all of port B outputs as
well.  The library does not use port B.  On a KIM-1 whose timer interrupt
is jumpered from PB7 to IRQ, set up only port A, as above.)

## Calling convention

Every routine returns C=0 on success, or C=1 with an error code in A (also
in `fat32_error`):

| Code | Name | Meaning |
| --- | --- | --- |
| 1 | `FAT32_ERR_IO` | the card did not answer, or failed a read or write |
| 2 | `FAT32_ERR_NOTFOUND` | no such file or directory |
| 3 | `FAT32_ERR_EXISTS` | it already exists |
| 4 | `FAT32_ERR_FULL` | the card is full |
| 5 | `FAT32_ERR_NOTEMPTY` | the directory is not empty |
| 6 | `FAT32_ERR_BADNAME` | not a valid 8.3 name |
| 7 | `FAT32_ERR_ISDIR` | it is a directory |
| 8 | `FAT32_ERR_NOTDIR` | part of the path is a file, not a directory |
| 9 | `FAT32_ERR_ACCESS` | not open for that, read-only, or the root directory |
| 10 | `FAT32_ERR_RANGE` | seek past the end of the file |
| 11 | `FAT32_ERR_BADFS` | no FAT32 volume on the card |

Arguments go in these variables:

| Variable | Size | Use |
| --- | --- | --- |
| `fat32_ptr1` | 2 (zero page) | a path, or a buffer |
| `fat32_ptr2` | 2 (zero page) | a second path, or a 32-byte buffer |
| `fat32_len` | 2 | a byte count, in and out |
| `fat32_pos` | 4 | a file position, or a result |

A **handle** is `FAT32_FILESIZE` (30) bytes of your memory, one per open
file or directory, passed with its address in A (low byte) and X (high
byte).  You may read its position (`FAT32_F_POS`, 4 bytes) and size
(`FAT32_F_SIZE`, 4 bytes).

**Paths** are zero-terminated strings, with `/` between directories:
`GAMES/ADVENT.SAV`.  A leading `/` is allowed, and `.` and `..` work.  Names
are 8.3 and matched without regard to case.  Long file names written by
other systems are skipped: reach a file by its short name (for example
`LONGFI~1.TXT`).  Deleting or renaming a file removes its long name too.

## Files

| Routine | Arguments | Does |
| --- | --- | --- |
| `fat32_open` | A/X handle, `ptr1` path, Y mode | open a file |
| `fat32_read` | A/X handle, `ptr1` buffer, `len` | read up to `len` bytes; `len` = bytes read, 0 at the end |
| `fat32_write` | A/X handle, `ptr1` buffer, `len` | write `len` bytes; `len` = bytes written |
| `fat32_seek` | A/X handle, `pos` | move to `pos`, at most the size |
| `fat32_close` | A/X handle | finish: update the directory entry, write out the cache |
| `fat32_delete` | `ptr1` path | delete a file |
| `fat32_rename` | `ptr1` old path, `ptr2` new path | rename or move a file or directory |
| `fat32_stat` | `ptr1` path, `ptr2` buffer | copy its 32-byte directory entry |

The open mode in Y combines:

| Flag | Meaning |
| --- | --- |
| `FAT32_READ` | open for reading |
| `FAT32_WRITE` | open for writing (writes overwrite, or extend at the end) |
| `FAT32_CREATE` | create the file if it is not there (needs `FAT32_WRITE`) |
| `FAT32_TRUNC` | empty the file first |
| `FAT32_APPEND` | start at the end |
| `FAT32_EXCL` | fail with `FAT32_ERR_EXISTS` if it is there |

For example `FAT32_WRITE | FAT32_CREATE | FAT32_TRUNC` creates or replaces
a file.  Files may be up to 4 GB; `fat32_len` limits one call to 64 KB.

A file's directory entry (its size) is updated when it is closed, so
**close every file you write**.  Written data sits in the cache until
another sector is needed, the file is closed, or `fat32_sync` is called.

## Directories

| Routine | Arguments | Does |
| --- | --- | --- |
| `fat32_mkdir` | `ptr1` path | make a directory |
| `fat32_rmdir` | `ptr1` path | remove an empty directory |
| `fat32_opendir` | A/X handle, `ptr1` path | start listing a directory (`""` or `/` for the root) |
| `fat32_readdir` | A/X handle, `ptr1` buffer | the next entry, 32 bytes in FAT layout; C=1 with A=0 at the end |

`fat32_readdir` skips deleted entries, long-name entries, the volume label,
`.` and `..`.  In the entry, bytes 0-10 are the name (8 + 3, space padded),
byte 11 the attributes (`$10` for a directory) and bytes 28-31 the size.
Directories grow as entries are added.

## The card

| Routine | Does |
| --- | --- |
| `fat32_free` | `fat32_pos` = the number of free clusters |
| `fat32_sync` | write out the cache and the free-space information |

A cluster is `fat32_sectorspercluster` sectors of 512 bytes.  The free count
comes from the card's FSInfo sector.  If that has no count, `fat32_free`
counts the free clusters, which can take minutes on a big card, but only
the first time.

`fat32_date` and `fat32_time` (2 bytes each, in FAT format) are stamped on
files and directories as they are created and changed; `fat32_init` sets
1 January 1980.

## Examples

* [test\_listfile.s](../src/test_listfile.s): list a directory.
* [test\_dumpfile.s](../src/test_dumpfile.s): print a file.
* [test\_savefile.s](../src/test_savefile.s): write a file.
* [loadfile.s](../src/loadfile.s): an interactive loader: list
  directories, and load a file to a given address.

Build one with `make PROGRAM=loadfile` in `src`.

## Tests

`test/` runs the library in the kim1emu KIM-1 emulator:

```
cd test
make test
```

`fstest.c` executes scripts of file operations.  `run.py` checks every
result against a model of the file system.  `fatfs.py` then checks the
card image: no lost or cross-linked clusters, chains that match the file
sizes, correct `.` and `..` entries, no orphan long names, matching FAT
copies, and a correct free count.  The tests cover directories that grow,
files over 64 KB, several open files, long names, a full card, and runs of
random operations (`python3 run.py random --seed N`).  `--spc N` tests other
cluster sizes, and `--real --cardtype sdsc` (or `sdhc`, `sdsc-v1`) sends
everything through the bit-banged SPI to an emulated card of that kind,
which is slow.
