#!/bin/sh

rm -f log
for i in ../libav/lib*/arm/*.S; do
	echo $i
	gas-wrapper -I. -I/home/martin/code/libav -c -o test.o $i
	dumpbin -disasm test.o | cut -f 2- -d : > disasm-orig
	$(dirname $0)/gas-preprocessor.pl -as-type armasm -- armasm -nologo -U__ELF__ -ignore 4509 -I. -I/home/martin/code/libav -c -o test.o $i
	dumpbin -disasm test.o | cut -f 2- -d : > disasm-new
	echo $i >> log
	diff -u disasm-orig disasm-new >> log
done

