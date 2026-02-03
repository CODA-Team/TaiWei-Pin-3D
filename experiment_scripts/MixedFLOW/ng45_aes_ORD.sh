#!/bin/bash
cd ~/Projects/3DIC/scripts/ORFS-Research/flow-Pin3D || exit
source env.sh
export NUM_CORES=16
export DESIGN_DIMENSION="3D"
export DESIGN_NICKNAME="aes" 
export FLOW_VARIANT="ORD"
export USE_FLOW="openroad"
cp -r results/nangate45_3D/aes/openroad results/nangate45_3D/aes/ORD
make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config.mk cds-3d-pdn
make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config_upper_cover.mk cds-place-init
make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config_bottom_cover.mk cds-place-upper
make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config_upper_cover.mk cds-place-bottom
make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config.mk cds-place-finish
iteration=1
for ((i=1;i<=iteration;i++))
do
    echo "Iteration: \$i"
    make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config_upper_cover.mk cds-legalize-bottom
    make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config_bottom_cover.mk cds-legalize-upper
done
make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config_upper_cover.mk cds-cts 
make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config.mk cds-route 
make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config.mk cds-final 
