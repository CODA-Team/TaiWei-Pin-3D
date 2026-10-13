set tpu_rtl_path [file dirname [info script]]

set vlog_files [list \
${tpu_rtl_path}/tpu_pe.sv  \
${tpu_rtl_path}/tpu_array.sv  \
${tpu_rtl_path}/tpu.sv  \
]

set top_module tpu
