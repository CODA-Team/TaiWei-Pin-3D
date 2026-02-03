# techgen_batch.tcl — Batch recipe for Techgen (run from qrc/)
# 输出文件名
set out_tch       [file normalize "NG45.tch"]
set out_captable  [file normalize "typical.captable"]

# 可按需修改：LEF/层叠等输入，若你有更详细的层叠/材料参数文件，可在这里引入
set tech_lef      [file normalize "../lef/NangateOpenCellLibrary.tech.lef"]
set cell_lef      [file normalize "../lef/NangateOpenCellLibrary.macro.lef"]  ;# 或 .macro.mod.lef / .macro.rect.lef

# --- 开始：创建/打开 Techgen 工程（不同版本命令名可能略有不同） ---
# 典型命令原型示例（若你的版本前缀不同，请替换成相应前缀命令）：
#   tgOpenProject -name ng45_proj -dir .
#   tgReset

catch { tgOpenProject -name ng45_proj -dir . } msg
if {[info exists msg] && $msg ne ""} { puts "INFO: tgOpenProject: $msg" }

# --- 导入必要技术/几何信息（若命令不可用，请注释或换等价导入） ---
# 常见做法：导入 tech lef；部分版本提供 tgImportTechLef / techgenImportTechLef 之类接口
if {[file exists $tech_lef]} {
  catch { tgImportTechLef -file $tech_lef } imsg
  if {[info exists imsg] && $imsg ne ""} { puts "INFO: tgImportTechLef: $imsg" }
}

# （可选）导入一个 cell lef 以补齐层名/方向等（不会影响 RC 数值，仅供栈推断辅助）
if {[file exists $cell_lef]} {
  catch { tgImportCellLef -file $cell_lef } imsg2
  if {[info exists imsg2] && $imsg2 ne ""} { puts "INFO: tgImportCellLef: $imsg2" }
}

# --- 设置金属栈与介电（占位：请按你的 NG45 设定替换） ---
# 如你有 foundry 的 layer-stack/材料参数 yaml/tcl，请在此读取：
#   tgLoadProcess -file ng45_stack.yaml
# 下面给出一份“占位默认”，仅为骨架（请按需改成真实厚度/间距/epsilon）
catch {
  tgSetMetalStack -layers {M1 M2 M3 M4 M5 M6 M7 M8}
  tgSetDielectric -name ILD -k 3.9
  # 示例：对若干金属层填占位几何（单位与精度视版本而定）
  tgSetMetalGeom -layer M1 -thickness 0.09 -minWidth 0.07 -minSpace 0.07
  tgSetMetalGeom -layer M2 -thickness 0.10 -minWidth 0.09 -minSpace 0.09
} cfgmsg
if {[info exists cfgmsg] && $cfgmsg ne ""} { puts "INFO: stack config messages: $cfgmsg" }

# --- 生成/选择 RC 模型角 ---
# 典型命令示例：tgCreateRCModel -name typical -type Cbest/Rbest/Typical 等
catch { tgCreateRCModel -name typical -type Typical } rcmsg
if {[info exists rcmsg] && $rcmsg ne ""} { puts "INFO: tgCreateRCModel: $rcmsg" }

# --- 导出 tech file 与 cap table ---
# 不同版本命令可能为：tgWriteTech / techgenWriteTech / extSaveTechnology 等
set ok 1
if {[catch { tgWriteTech -file $out_tch } emsg]} {
  puts "ERROR: write tech failed: $emsg"
  set ok 0
}
if {[catch { tgWriteCapTable -model typical -file $out_captable } emsg2]} {
  puts "ERROR: write captable failed: $emsg2"
  set ok 0
}

puts "=== SUMMARY ==="
puts "Techfile  : $out_tch"
puts "CapTable  : $out_captable"
puts [expr {$ok ? "STATUS: OK" : "STATUS: FAIL"}]

# 若在批处理模式，执行完退出
catch { tgCloseProject }
exit [expr {$ok ? 0 : 1}]
