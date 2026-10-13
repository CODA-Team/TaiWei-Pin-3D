export DESIGN_NAME = tpu
export DESIGN_NICKNAME = tpu
export PLATFORM = nangate45

RTL_ROOT := $(DESIGN_HOME)/src/tpu/nangate45
RTL_FILELIST := $(DESIGN_HOME)/src/tpu/nangate45/rtl_files.f
export VERILOG_FILES = $(addprefix $(RTL_ROOT)/,$(shell awk 'NF' $(RTL_FILELIST)))
export SYNTH_HDL_FRONTEND = slang
export SDC_FILE = $(DESIGN_HOME)/nangate45_3D/tpu/constraint.sdc
export CORE_MARGIN = 1
export CORE_UTILIZATION ?= 60
export NUM_CORES ?= 32
export PIN3D_SPLIT_PORT_DRIVEN_NETS ?= 1
export GLOBAL_ROUTE_ARGS ?= -verbose -congestion_iterations 30
