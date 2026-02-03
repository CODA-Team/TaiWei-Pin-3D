#!/usr/bin/env bash
# run_all_parallel_logs.sh - parallel version, write output to logs

echo "Starting all process variants in parallel..."

# Ensure work directory exists
mkdir -p work

# Variant 1: asap7_nangate45_2A6M10M
(
  export FLOW_VARIANT="asap7_nangate45_2A6M10M"
  echo "[$FLOW_VARIANT] Starting"
  source env.sh
  ./01_gen_patterns.sh > work/${FLOW_VARIANT}/step1.log 2>&1
  ./02_cds_extract.sh > work/${FLOW_VARIANT}/step2.log 2>&1
  ./03_gen_rules.sh > work/${FLOW_VARIANT}/step3.log 2>&1
  echo "[${FLOW_VARIANT}] Done"
) &

# Variant 2: asap7_tech_1x_2A6M7M
(
  export FLOW_VARIANT="asap7_tech_1x_2A6M7M"
  echo "[$FLOW_VARIANT] Starting"
  source env.sh
  ./01_gen_patterns.sh > work/${FLOW_VARIANT}/step1.log 2>&1
  ./02_cds_extract.sh > work/${FLOW_VARIANT}/step2.log 2>&1
  ./03_gen_rules.sh > work/${FLOW_VARIANT}/step3.log 2>&1
  echo "[${FLOW_VARIANT}] Done"
) &

# Variant 3: NangateOpenCellLibrary.tech
(
  export FLOW_VARIANT="NangateOpenCellLibrary.tech"
  echo "[$FLOW_VARIANT] Starting"
  source env.sh
  ./01_gen_patterns.sh > work/${FLOW_VARIANT}/step1.log 2>&1
  ./02_cds_extract.sh > work/${FLOW_VARIANT}/step2.log 2>&1
  ./03_gen_rules.sh > work/${FLOW_VARIANT}/step3.log 2>&1
  echo "[${FLOW_VARIANT}] Done"
) &

# Variant 4: asap7_nangate45_6M10M
(
  export FLOW_VARIANT="asap7_nangate45_6M10M"
  echo "[$FLOW_VARIANT] Starting"
  source env.sh
  ./01_gen_patterns.sh > work/${FLOW_VARIANT}/step1.log 2>&1
  ./02_cds_extract.sh > work/${FLOW_VARIANT}/step2.log 2>&1
  ./03_gen_rules.sh > work/${FLOW_VARIANT}/step3.log 2>&1
  echo "[${FLOW_VARIANT}] Done"
) &

# Variant 5: asap7_tech_1x_6M7M
(
  export FLOW_VARIANT="asap7_tech_1x_6M7M"
  echo "[$FLOW_VARIANT] Starting"
  source env.sh
  ./01_gen_patterns.sh > work/${FLOW_VARIANT}/step1.log 2>&1
  ./02_cds_extract.sh > work/${FLOW_VARIANT}/step2.log 2>&1
  ./03_gen_rules.sh > work/${FLOW_VARIANT}/step3.log 2>&1
  echo "[${FLOW_VARIANT}] Done"
) &

# Variant 6: NangateOpenCellLibrary.tech21
(
  export FLOW_VARIANT="NangateOpenCellLibrary.tech21"
  echo "[$FLOW_VARIANT] Starting"
  source env.sh
  ./01_gen_patterns.sh > work/${FLOW_VARIANT}/step1.log 2>&1
  ./02_cds_extract.sh > work/${FLOW_VARIANT}/step2.log 2>&1
  ./03_gen_rules.sh > work/${FLOW_VARIANT}/step3.log 2>&1
  echo "[${FLOW_VARIANT}] Done"
) &

echo "All variants started and running in the background..."
echo "Use 'jobs' to check status"
echo "View logs: ls -la work/*/step*.log"