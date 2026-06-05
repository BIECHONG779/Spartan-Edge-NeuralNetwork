## build.tcl — Vivado 非项目模式编译流程
##
## 用法 (Windows / Linux / macOS Vivado 都支持):
##   vivado -mode batch -source build.tcl
##
## 产物: build/spartan_edge_mlp.bit  (拷贝到 SD 卡, ESP32 加载)
##
## 注意: 如果你的板子是 XC7S15-1FTGB196C 之外的型号, 改下面 PART 即可.

set PART        "xc7s15ftgb196-1"
set TOP         "top"
set RTL_DIR     "../rtl"
set MEM_DIR     "../rtl/mem"
set BUILD_DIR   "./build"

file mkdir $BUILD_DIR

create_project -in_memory -part $PART

# RTL 源
add_files [glob ${RTL_DIR}/*.v]
# 让 $readmemh 能找到权重 (相对路径基于 Vivado 启动 cwd, 这里我们用绝对路径)
set_property file_type {Verilog Header} [get_files ${RTL_DIR}/mem/params.vh]

# 把 .mem 文件加入工程, 综合时 $readmemh 会从同目录找到
add_files [glob ${MEM_DIR}/*.mem]

# 顶层 + 约束
add_files -fileset constrs_1 [list constraints.xdc]
set_property top $TOP [current_fileset]

# 包含目录 (params.vh)
set_property include_dirs ${RTL_DIR} [current_fileset]

# 综合
synth_design -top $TOP -part $PART -include_dirs ${RTL_DIR}
write_checkpoint -force ${BUILD_DIR}/post_synth.dcp
report_utilization -file ${BUILD_DIR}/util_synth.rpt

# 实现
opt_design
place_design
route_design
write_checkpoint -force ${BUILD_DIR}/post_route.dcp
report_timing_summary -file ${BUILD_DIR}/timing.rpt
report_utilization     -file ${BUILD_DIR}/util_impl.rpt

# 生成 bit
write_bitstream -force ${BUILD_DIR}/spartan_edge_mlp.bit

puts "==== DONE ===="
puts "bitstream: ${BUILD_DIR}/spartan_edge_mlp.bit"
