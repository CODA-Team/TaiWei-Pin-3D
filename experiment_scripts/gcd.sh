#!/bin/bash
source "${FLOW_ROOT}/env.sh"

export DESIGN_DIMENSION="3D"
export USE_FLOW="openroad"
export FLOW_VARIANT="base"
# export OPEN_GUI=0
export LOG_DIR=./logs/nangate45_3D/gcd/base
export OBJECTS_DIR=./objects/nangate45_3D/gcd/base
export REPORTS_DIR=./reports/nangate45_3D/gcd/base
export RESULTS_DIR=./results/nangate45_3D/gcd/base
make DESIGN_CONFIG=designs/nangate45_3D/gcd/config.mk clean_all
make DESIGN_CONFIG=designs/nangate45_3D/gcd/config2d.mk ord-3d-flow-2dpart
make DESIGN_CONFIG=designs/nangate45_3D/gcd/config.mk ord-3d-flow
