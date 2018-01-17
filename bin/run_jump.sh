#!/bin/bash

#!/bin/bash

mkdir -p ../test_out

export RAND_SEED=$RANDOM

TESTS=(jump)
FRECV=(spec undef def)
FLAGS=(jump jump1 jump2 alloff)

for t in ${TESTS[*]};
do
    for f in ${FRECV[*]};
    do    
	for fl in ${FLAGS[*]};
	do
		echo "Run $t $f ${fl}"
		./run_test $t $f ${fl} > ../test_out/${t}_${f}_${fl}`date +"%b%d_%H_%M_%S"`
	done
    done
done 