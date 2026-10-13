#!/bin/bash
cd $(dirname $0)
./cold.sh && ./rounds.sh && SAT=1 ROUNDS="1 2" ./rounds.sh
echo DRIVER_DONE
