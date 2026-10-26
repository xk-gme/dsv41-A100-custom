#!/bin/bash
# ===== 00_preflight.sh — T-Day 预检（纯只读，不修改任何文件）=====
# 用法: bash 00_preflight.sh [--services-running]
#   --services-running: 同事服务还在跑时使用，GPU 占用记为 INFO 而非 FAIL
# 输出: 终端 + ~/dsv41_deploy/logs/preflight.txt

BASE="$HOME/dsv41_deploy"
LOGS="$BASE/logs"
mkdir -p "$LOGS"
OUT="$LOGS/preflight.txt"
exec > >(tee -a "$OUT") 2>&1

SVC_OK=0
[ "$1" = "--services-running" ] && SVC_OK=1

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
info() { echo "  [INFO] $1"; WARN=$((WARN+1)); }

echo "===== preflight @ $(date '+%F %T') ====="

echo "--- 1. GPU 空闲度 ---"
IDLE_CARDS=$(nvidia-smi --query-gpu=index --format=csv,noheader,nounits | wc -l)
[ "$IDLE_CARDS" -eq 8 ] && ok "检测到 8 张 GPU" || bad "GPU 数量异常: $IDLE_CARDS"
BUSY=0
while IFS=, read -r idx mumem; do
  if [ "$mumem" -gt 2000 ]; then
    BUSY=$((BUSY+1))
    if [ $SVC_OK -eq 1 ]; then info "GPU $idx 已用 ${mumem}MiB（服务未停，预期内）"; else bad "GPU $idx 已用 ${mumem}MiB"; fi
  fi
done < <(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits)
[ $BUSY -eq 0 ] && ok "8 卡全部空闲（<2GB）"

echo "--- 2. 主机资源 ---"
AVAIL_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
AVAIL_GB=$((AVAIL_KB/1024/1024))
[ "$AVAIL_GB" -ge 300 ] && ok "可用内存 ${AVAIL_GB}GB（需 ≥300GB）" || bad "可用内存仅 ${AVAIL_GB}GB"
DISK_GB=$(df --output=avail -BG /data 2>/dev/null | tail -1 | tr -dc '0-9')
[ "${DISK_GB:-0}" -ge 100 ] && ok "/data 剩余 ${DISK_GB}GB" || info "/data 剩余 ${DISK_GB:-?}GB（权重已在盘，仅影响缓存）"

echo "--- 3. 权重完整性（只读）---"
CKPT=/data/models/DeepSeek-V4.1-Flash
if [ -d "$CKPT" ]; then
  NST=$(find "$CKPT" -maxdepth 1 -name "*.safetensors" | wc -l)
  [ "$NST" -ge 48 ] && ok "safetensors 分片 ${NST}/48" || bad "safetensors 分片仅 ${NST}/48"
  ZERO=$(find "$CKPT" -maxdepth 1 -name "*.safetensors" -size 0 | wc -l)
  [ "$ZERO" -eq 0 ] && ok "无零字节分片" || bad "存在 ${ZERO} 个零字节分片"
  [ -f "$CKPT/config.json" ] && ok "config.json 存在" || bad "config.json 缺失"
  [ -f "$CKPT/tokenizer.json" ] && ok "tokenizer.json 存在" || bad "tokenizer.json 缺失"
  if [ -d "$CKPT/encoding" ]; then ok "encoding/ 目录存在（dsv41 依赖）"; else info "encoding/ 不在权重目录 —— setup 阶段需 ModelScope 定向补拉"; fi
else
  bad "权重目录不存在: $CKPT"
fi

echo "--- 4. Python 环境 ---"
GME_PY=$HOME/miniconda3/envs/GME-AICoding/bin/python
if [ -x "$GME_PY" ]; then
  $GME_PY - <<'PYEOF'
import sys
print(f"  [INFO] GME-AICoding: python {sys.version.split()[0]}")
try:
    import torch
    has_f8 = hasattr(torch, "float8_e8m0fnu")
    v = torch.__version__
    major = int(v.split(".")[0]); minor = int(v.split(".")[1])
    print(f"  [PASS] torch {v} (float8_e8m0fnu={has_f8})" if (major > 2 or (major==2 and minor >= 10)) and has_f8
          else f"  [FAIL] torch {v} 需 >=2.10 且含 float8_e8m0fnu (实际 {has_f8})")
except Exception as e:
    print(f"  [FAIL] torch 导入失败: {e}")
try:
    import triton; print(f"  [PASS] triton {triton.__version__}" if tuple(int(x) for x in triton.__version__.split(".")[:2]) >= (3,5)
          else f"  [FAIL] triton {triton.__version__} < 3.5")
except Exception as e:
    print(f"  [FAIL] triton 导入失败: {e}")
for m in ("transformers", "tokenizers", "sympy", "PIL"):
    try:
        __import__(m); print(f"  [PASS] {m} 已安装")
    except ImportError:
        print(f"  [INFO] {m} 缺失 —— setup 阶段从 wheelhouse 离线补装")
PYEOF
else
  info "GME-AICoding 环境不存在，setup 将无法克隆（需改走全量 wheelhouse 路线）"
fi
[ -d "$HOME/miniconda3/envs/dsv41" ] && info "dsv41 环境已存在（setup 将跳过创建）"

echo "--- 5. nvcc（sm_80 kernel 编译）---"
if command -v nvcc >/dev/null 2>&1; then
  ok "nvcc: $(nvcc --version | tail -1)"
elif ls /usr/local/cuda*/bin/nvcc >/dev/null 2>&1; then
  ok "nvcc: $(ls -d /usr/local/cuda*/bin/nvcc | head -1)（setup 将导出 DSV41_NVCC）"
else
  info "系统无 nvcc —— setup 阶段安装 nvidia-cuda-nvcc-cu13 轮子"
fi

echo "--- 6. 端口 8010 ---"
if ss -tln 2>/dev/null | grep -q ":8010 "; then bad "8010 端口被占用"; else ok "8010 端口空闲"; fi

echo "--- 7. 同事服务命令行存档（供恢复参考）---"
ps -ef | grep "vllm serve" | grep -v grep > "$LOGS/colleague_services.txt" 2>/dev/null
LINES=$(wc -l < "$LOGS/colleague_services.txt" 2>/dev/null || echo 0)
if [ "$LINES" -gt 0 ]; then
  ok "已存档 ${LINES} 条 vllm serve 命令行到 logs/colleague_services.txt"
  [ $SVC_OK -eq 1 ] && info "同事服务仍在运行（T-Day 前应停用）" || ok "当前无 vllm serve 在跑"
else
  ok "当前无 vllm serve 在跑；存档文件为空"
fi

echo "--- 8. ModelScope 通道（编码目录补拉兜底）---"
if $HOME/miniconda3/bin/conda env list 2>/dev/null | grep -q "."; then info "miniconda 可用"; fi

echo
echo "===== preflight 结果: PASS=$PASS FAIL=$FAIL INFO/WARN=$WARN ====="
[ $FAIL -eq 0 ] && echo ">>> 结论：可以进入 10_setup_env" || echo ">>> 结论：存在 FAIL 项，先处理再继续（INFO 项不阻塞）"
