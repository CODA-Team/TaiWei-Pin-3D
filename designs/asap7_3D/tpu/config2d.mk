export DESIGN_NAME = tpu
export DESIGN_NICKNAME = tpu
export PLATFORM = asap7

RTL_ROOT := $(DESIGN_HOME)/src/tpu/asap7
RTL_FILELIST := $(DESIGN_HOME)/src/tpu/asap7/rtl_files.f
export VERILOG_FILES = $(addprefix $(RTL_ROOT)/,$(shell awk 'NF' $(RTL_FILELIST)))
export SYNTH_HDL_FRONTEND = slang
export SDC_FILE = $(DESIGN_HOME)/asap7_3D/tpu/constraint.sdc
export CORE_MARGIN = 0.2
export CORE_UTILIZATION ?= 60
export NUM_CORES ?= 32
