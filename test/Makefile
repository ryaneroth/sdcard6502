# File system tests for sdcard6502, run in kim1emu (see run.py).
#   make          build fstest.bin (load at $2000) and fstest.lbl
#   make test     run the tests

all: fstest.bin

fstest.bin: fstest.c glue.s fstest.cfg ../src/libsd.s ../src/libfat32.s ../src/hwconfig.s
	cl65 -t none -C fstest.cfg -O -g -Ln fstest.lbl -m fstest.map -o $@ fstest.c glue.s

test: fstest.bin
	python3 run.py

clean:
	rm -f fstest.bin fstest.lbl fstest.map *.o

.PHONY: all test clean
