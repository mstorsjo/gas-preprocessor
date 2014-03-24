
CROSS=arm-linux-gnueabihf-

test:
	./gas-preprocessor.pl -as-type gas -- $(CROSS)gcc -c test.S -o test.o
	$(CROSS)objdump -d test.o > disasm
	$(CROSS)gcc -c test.S -o test.o
	$(CROSS)objdump -d test.o > disasm-ref
	diff -u disasm-ref disasm

test2:
	GASPP_DEBUG=1 ./gas-preprocessor.pl -as-type gas -- $(CROSS)gcc -c test.S -o test.o > test.out
	diff -u test.out.ref test.out

clean:
	rm -f test.o disasm disasm-ref test.out
