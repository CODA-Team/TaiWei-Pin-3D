#!/bin/bash

# Define the base directories
LOG_DIR="run_logs/asap7_3D/aes/ord_pitch"
SCRIPT_DIR="test/asap7_3D/aes/ord_pitch"

# Create the log directory
mkdir -p "$LOG_DIR"

# List of pitch suffixes to run
pitches=("V6" "0p2" "0p3" "0p4" "0p5" "0p6" "0p7" "0p8" "0p9" "1")

# Loop through each pitch and run in background
for p in "${pitches[@]}"; do
    (
        echo "Start: ${SCRIPT_DIR}/eval_${p}.sh"
        export hbPitch="hbPitch_${p}"
        bash "${SCRIPT_DIR}/eval.sh" > "${LOG_DIR}/eval_${p}.log" 2>&1
        echo "Done: ${LOG_DIR}/eval_${p}.log"
    ) &
done

# Wait for all background jobs to finish
wait
echo "All jobs completed."