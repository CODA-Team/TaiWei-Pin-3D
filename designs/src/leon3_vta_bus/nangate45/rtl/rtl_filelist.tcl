set leon3_vta_rtl_path [file dirname [info script]]

set vlog_files [list \
  ${leon3_vta_rtl_path}/leon3core-inferred-nojtag.sv \
  ${leon3_vta_rtl_path}/VTA.DefaultDe10Config.replmem.noqueue.sv \
  ${leon3_vta_rtl_path}/vta_small_memories.sv \
  ${leon3_vta_rtl_path}/vta_queue_512x128_adapter.sv \
  ${leon3_vta_rtl_path}/leon3_banked_mems.sv \
  ${leon3_vta_rtl_path}/vta_scratchpad_wrappers.sv \
  ${leon3_vta_rtl_path}/vta_queue_wrapper.sv \
  ${leon3_vta_rtl_path}/vta_host_bridge.sv \
  ${leon3_vta_rtl_path}/leon3_vta_soc.sv \
]
