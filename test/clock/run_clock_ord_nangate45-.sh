#!/bin/bash

# Define the base directories
LOG_DIR="run_logs/nangate45_3D/aes/ord_clock"
SCRIPT_DIR="test/nangate45_3D/aes/ord_clock"

# Create the log directory
mkdir -p "$LOG_DIR"

# Generate clock periods from 1.0 down to 0.5 with a step of 0.05
clocks=()
for i in $(seq 0.99 -0.05 0.49); do
    clocks+=("$i")
done

# Loop through each pitch and run in background
for clk in "${clocks[@]}"; do
    (
        echo "Start: ${SCRIPT_DIR}/run.sh with CLK_PERIOD=$clk"
        export CLK_PERIOD=$clk
        bash "${SCRIPT_DIR}/run.sh" > "${LOG_DIR}/run_${clk}.log" 2>&1
        bash "${SCRIPT_DIR}/eval.sh" > "${LOG_DIR}/eval_${clk}.log" 2>&1
        echo "Done: ${LOG_DIR}/eval_${clk}.log"
    ) &
done

# Wait for all background jobs to finish
wait
echo "All jobs completed."