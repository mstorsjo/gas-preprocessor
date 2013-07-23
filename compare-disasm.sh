#!/bin/sh

rm -f log
for i in ../libav/lib*/arm/*.S; do
	echo $i
	arm-linux-gnueabihf-gcc -I. -I/home/martin/code/libav -c -o test.o $i
	arm-linux-gnueabihf-objdump -d test.o > disasm-orig
	$(dirname $0)/gas-preprocessor.pl -as-type gas -- arm-linux-gnueabihf-gcc -I. -I/home/martin/code/libav -c -o test.o $i
	arm-linux-gnueabihf-objdump -d test.o > disasm-new
	echo $i >> log
	diff -u disasm-orig disasm-new >> log || diffs=yes
done
if [ "$diffs" = "" ]; then
	echo "No differences found"
else
	echo "Some differences found"
fi

