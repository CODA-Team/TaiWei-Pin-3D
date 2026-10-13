set mempool_group_rtl_path [file dirname [info script]]

# define TARGET_SYNTHESIS
# define XPULPIMG=1
# define AXI_DATA_WIDTH=512
# define NUM_CORES=256
# define NUM_CORES_PER_TILE=4
# define NUM_GROUPS=4
# define BANKING_FACTOR=4
# define AXI_HIER_RADIX=17
# define AXI_MASTERS_PER_GROUP=1
# define DMAS_PER_GROUP=1
# define L2_SIZE=4194304
# define L2_BANKS=4
# define RO_LINE_WIDTH=512
# define SEQ_MEM_SIZE=512
# define XQUEUE_SIZE=0
set mempool_group_incdirs [list \
    ${mempool_group_rtl_path}/include \
]
set vlog_files [list \
${mempool_group_rtl_path}/cf_math_pkg.sv  \
${mempool_group_rtl_path}/axi_pkg.sv  \
${mempool_group_rtl_path}/riscv_instr.sv  \
${mempool_group_rtl_path}/snitch_pkg.sv  \
${mempool_group_rtl_path}/reqrsp_pkg.sv  \
${mempool_group_rtl_path}/mempool_pkg.sv  \
${mempool_group_rtl_path}/snitch_icache_pkg.sv  \
${mempool_group_rtl_path}/tcdm_interconnect_pkg.sv  \
${mempool_group_rtl_path}/axi_intf.sv  \
${mempool_group_rtl_path}/reg_intf.sv  \
${mempool_group_rtl_path}/reqrsp_intf.sv  \
${mempool_group_rtl_path}/stream_intf.sv  \
${mempool_group_rtl_path}/addr_decode.sv  \
${mempool_group_rtl_path}/addr_decoder.sv  \
${mempool_group_rtl_path}/address_scrambler.sv  \
${mempool_group_rtl_path}/axi2mem.sv  \
${mempool_group_rtl_path}/axi_atop_filter.sv  \
${mempool_group_rtl_path}/axi_cut.sv  \
${mempool_group_rtl_path}/axi_demux.sv  \
${mempool_group_rtl_path}/axi_dma_backend.sv  \
${mempool_group_rtl_path}/axi_dma_burst_reshaper.sv  \
${mempool_group_rtl_path}/axi_dma_data_mover.sv  \
${mempool_group_rtl_path}/axi_dma_data_path.sv  \
${mempool_group_rtl_path}/axi_err_slv.sv  \
${mempool_group_rtl_path}/axi_hier_interco.sv  \
${mempool_group_rtl_path}/axi_id_prepend.sv  \
${mempool_group_rtl_path}/axi_id_remap.sv  \
${mempool_group_rtl_path}/axi_mux.sv  \
${mempool_group_rtl_path}/axi_rab_wrap.sv  \
${mempool_group_rtl_path}/axi_to_reqrsp.sv  \
${mempool_group_rtl_path}/axi_xbar.sv  \
${mempool_group_rtl_path}/bootrom.sv  \
${mempool_group_rtl_path}/cc_onehot.sv  \
${mempool_group_rtl_path}/counter.sv  \
${mempool_group_rtl_path}/ctrl_registers.sv  \
${mempool_group_rtl_path}/delta_counter.sv  \
${mempool_group_rtl_path}/fall_through_register.sv  \
${mempool_group_rtl_path}/fifo_v2.sv  \
${mempool_group_rtl_path}/fifo_v3.sv  \
${mempool_group_rtl_path}/find_first_one.sv  \
${mempool_group_rtl_path}/full_duplex_xbar.sv  \
${mempool_group_rtl_path}/id_queue.sv  \
${mempool_group_rtl_path}/idma_distributed_midend.sv  \
${mempool_group_rtl_path}/isochronous_spill_register.sv  \
${mempool_group_rtl_path}/latch_scm.sv  \
${mempool_group_rtl_path}/lzc.sv  \
${mempool_group_rtl_path}/mempool_cc.sv  \
${mempool_group_rtl_path}/mempool_cluster.sv  \
${mempool_group_rtl_path}/mempool_group.sv  \
${mempool_group_rtl_path}/mempool_system.sv  \
${mempool_group_rtl_path}/mempool_tile.sv  \
${mempool_group_rtl_path}/onehot_to_bin.sv  \
${mempool_group_rtl_path}/reqrsp_demux.sv  \
${mempool_group_rtl_path}/rr_arb_tree.sv  \
${mempool_group_rtl_path}/simplex_xbar.sv  \
${mempool_group_rtl_path}/snitch.sv  \
${mempool_group_rtl_path}/snitch_addr_demux.sv  \
${mempool_group_rtl_path}/snitch_axi_adapter.sv  \
${mempool_group_rtl_path}/snitch_axi_to_cache.sv  \
${mempool_group_rtl_path}/snitch_demux.sv  \
${mempool_group_rtl_path}/snitch_icache.sv  \
${mempool_group_rtl_path}/snitch_icache_handler.sv  \
${mempool_group_rtl_path}/snitch_icache_l0.sv  \
${mempool_group_rtl_path}/snitch_icache_lfsr.sv  \
${mempool_group_rtl_path}/snitch_icache_lookup_parallel.sv  \
${mempool_group_rtl_path}/snitch_icache_lookup_serial.sv  \
${mempool_group_rtl_path}/snitch_icache_refill.sv  \
${mempool_group_rtl_path}/snitch_ipu.sv  \
${mempool_group_rtl_path}/snitch_lsu.sv  \
${mempool_group_rtl_path}/snitch_read_only_cache.sv  \
${mempool_group_rtl_path}/snitch_regfile_ff.sv  \
${mempool_group_rtl_path}/snitch_shared_muldiv.sv  \
${mempool_group_rtl_path}/spill_register.sv  \
${mempool_group_rtl_path}/spill_register_flushable.sv  \
${mempool_group_rtl_path}/stream_arbiter.sv  \
${mempool_group_rtl_path}/stream_arbiter_flushable.sv  \
${mempool_group_rtl_path}/stream_demux.sv  \
${mempool_group_rtl_path}/stream_fifo.sv  \
${mempool_group_rtl_path}/stream_fork.sv  \
${mempool_group_rtl_path}/stream_fork_dynamic.sv  \
${mempool_group_rtl_path}/stream_join.sv  \
${mempool_group_rtl_path}/stream_mux.sv  \
${mempool_group_rtl_path}/stream_register.sv  \
${mempool_group_rtl_path}/stream_xbar.sv  \
${mempool_group_rtl_path}/tc_clk.sv  \
${mempool_group_rtl_path}/tcdm_adapter.sv  \
${mempool_group_rtl_path}/tcdm_shim.sv  \
${mempool_group_rtl_path}/tcdm_wide_narrow_mux.sv  \
${mempool_group_rtl_path}/variable_latency_interconnect.sv  \
${mempool_group_rtl_path}/tc_sram_ng45.sv  \
]
