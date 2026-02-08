#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_HOME="${SCRIPT_DIR}"
source "${FLOW_HOME}/env.sh"

export DESIGN_DIMENSION="3D"
export DESIGN_NICKNAME="gcd"
export USE_FLOW="openroad"
export FLOW_VARIANT="openroad"
# export OPEN_GUI=0
export LOG_DIR=./logs/asap7_3D/${DESIGN_NICKNAME}/${FLOW_VARIANT}
export OBJECTS_DIR=./objects/asap7_3D/${DESIGN_NICKNAME}/${FLOW_VARIANT}
export REPORTS_DIR=./reports/asap7_3D/${DESIGN_NICKNAME}/${FLOW_VARIANT}
export RESULTS_DIR=./results/asap7_3D/${DESIGN_NICKNAME}/${FLOW_VARIANT}

make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk clean_all
# input: verilog source and sdc
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config2d.mk ord-synth
# input: 1_synth.v, 1_synth.sdc
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config2d.mk ord-preplace
# input: 2_2_floorplan_io.def, 1_synth.sdc
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config2d.mk ord-tier-partition
# input: 2_2_floorplan_io.def, 2_2_floorplan_io.v, partition.txt, map.json
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-pre
# input: $(DESIGN_NAME)_3D.fp.def, $(DESIGN_NAME)_3D.fp.v, 1_synth.sdc
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-3d-pdn
# input: 2_floorplan.def, 2_floorplan.v, 2_floorplan.sdc
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-place-init
# input: $env(DESIGN_NAME)_3D.tmp.def, $env(DESIGN_NAME)_3D.tmp.v, 2_floorplan.sdc
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-place-init-upper
# input: $env(DESIGN_NAME)_3D.tmp.def, $env(DESIGN_NAME)_3D.tmp.v, 2_floorplan.sdc
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-place-init-bottom
iteration=1
for ((i=1;i<=iteration;i++)); do
  echo "Iteration: $i"
  # input: $env(DESIGN_NAME)_3D.tmp.def, $env(DESIGN_NAME)_3D.tmp.v, 2_floorplan.sdc
  make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-place-upper
  # input: $env(DESIGN_NAME)_3D.tmp.def, $env(DESIGN_NAME)_3D.tmp.v, 2_floorplan.sdc
  make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk  ord-place-bottom
done
# input: $(DESIGN_NAME)_3D.v $(DESIGN_NAME)_3D.def
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-pre-opt
# input: $(DESIGN_NAME)_3D.lg.def, $(DESIGN_NAME)_3D.lg.v
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-legalize-bottom
# input: $(DESIGN_NAME)_3D.lg.def, $(DESIGN_NAME)_3D.lg.v
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-legalize-upper
# input: 3_place.def, 3_place.v, 3_place.sdc
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-cts
# input: 4_cts.def, 4_cts.v, 4_cts.sdc
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-route
# input: 5_route.def, 5_route.v, 5_route.sdc 
make DESIGN_CONFIG=designs/asap7_3D/${DESIGN_NICKNAME}/config.mk ord-final
