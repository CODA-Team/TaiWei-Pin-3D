ssh -Y zhiyuzheng@hnode33 "
    cd ~/Projects/3DIC/scripts/ORFS-Research/flow-Pin3D || exit
    source env.sh
    export NUM_CORES=16
    export DESIGN_DIMENSION="3D"
    export DESIGN_NICKNAME="aes" 
    export USE_FLOW="openroad"
    export FLOW_VARIANT="mixed1"
    make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config.mk cds-final > run_logs/MIXED_FLOW/miexd_eval1.log &
    export FLOW_VARIANT="mixed2"
    make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config.mk cds-final > run_logs/MIXED_FLOW/miexd_eval2.log &
    export FLOW_VARIANT="mixed3"
    make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config.mk cds-final > run_logs/MIXED_FLOW/miexd_eval3.log &
    export FLOW_VARIANT="mixed4"
    make DESIGN_CONFIG=designs/nangate45_3D/\${DESIGN_NICKNAME}/config.mk cds-final > run_logs/MIXED_FLOW/miexd_eval4.log &
    wait
"