#!/usr/bin/env bash
set -euo pipefail

# 工作目录：假设当前在 qrc/
ROOT="$(cd .. && pwd)"
QRC_DIR="$(pwd)"

# 依赖二进制
: "${QUANTUSHOME:?Please export QUANTUSHOME to your Quantus install root}"
TECHGEN_BIN="$QUANTUSHOME/tools/bin/Techgen"
QRC2RCX_BIN="$QUANTUSHOME/tools/bin/qrcTechToRcx"   # 仅在你需要格式互转时使用（可选）

if [[ ! -x "$TECHGEN_BIN" ]]; then
  echo "ERROR: Techgen binary not found or not executable: $TECHGEN_BIN"
  exit 2
fi

# 输出文件
OUT_TCH="$QRC_DIR/NG45.tch"
OUT_CAP="$QRC_DIR/typical.captable"

# Tcl 命令文件（上一节给的）
CMD_TCL="$QRC_DIR/techgen_batch.tcl"
if [[ ! -f "$CMD_TCL" ]]; then
  echo "ERROR: $CMD_TCL not found. Put techgen_batch.tcl in $QRC_DIR"
  exit 3
fi

echo "[INFO] QUANTUSHOME = $QUANTUSHOME"
echo "[INFO] Running Techgen (batch) ..."
# 典型批处理调用：部分版本接受 -nograph / -batch / -cmd / -files 等变体
# 下面尝试若干常见参数形态，命中一个即可；都失败则报错退出
set +e
"$TECHGEN_BIN" -nograph -files "$CMD_TCL"
rc=$?
if [[ $rc -ne 0 ]]; then
  echo "[WARN] Techgen -files failed with rc=$rc, trying -cmd ..."
  "$TECHGEN_BIN" -nograph -cmd "$CMD_TCL"
  rc=$?
fi
if [[ $rc -ne 0 ]]; then
  echo "[WARN] Techgen -cmd failed with rc=$rc, trying -batch ..."
  "$TECHGEN_BIN" -batch "$CMD_TCL"
  rc=$?
fi
set -e
if [[ $rc -ne 0 ]]; then
  echo "ERROR: Techgen batch run failed (rc=$rc). Check stdout/stderr for the first failing option."
  exit $rc
fi

# 可选：把 .tch 转为 RCX 旧格式（若你的下游需要）
# "$QRC2RCX_BIN" -qrcTechFile "$OUT_TCH" -out "$QRC_DIR/NG45.rcx"

# 汇总
if [[ -f "$OUT_TCH" && -s "$OUT_TCH" ]]; then
  echo "[OK] Wrote $OUT_TCH"
else
  echo "[ERR] $OUT_TCH missing or empty"
  exit 10
fi

if [[ -f "$OUT_CAP" && -s "$OUT_CAP" ]]; then
  echo "[OK] Wrote $OUT_CAP"
else
  echo "[ERR] $OUT_CAP missing or empty"
  exit 11
fi

echo "[DONE] NG45.tch & typical.captable generated in $QRC_DIR"
