PROGRAM = test_listfile

all: $(PROGRAM).ptp

$(PROGRAM).ptp: $(PROGRAM).bin Makefile
	srec_cat $(PROGRAM).bin -binary -offset 0xa000 -o $(PROGRAM).ptp -MOS_Technologies

$(PROGRAM).bin: $(PROGRAM).o
	ld65 -C kim1-60k.cfg -vm -m $(PROGRAM).map -o $(PROGRAM).bin $(PROGRAM).o

$(PROGRAM).o:	$(PROGRAM).s
	ca65 -g -l $(PROGRAM).lst $(PROGRAM).s

clean:
	$(RM) *.o *.lst *.map *.bin *.ptp

flash:
	minipro -p AT28C64B -w $(PROGRAM).bin -s

distclean: clean
