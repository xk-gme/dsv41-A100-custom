#!/bin/bash
# ===== 10_setup_env.sh — 环境搭建（后台自治，日志 logs/setup.txt）=====
# 幂等：重复执行安全。产物：conda env dsv41 + ~/dsv41_deploy/dsv41_runtime/
set -u
BASE="$HOME/dsv41_deploy"; LOGS="$BASE/logs"; PKG="$BASE/pkg"
mkdir -p "$LOGS"
exec > >(tee -a "$LOGS/setup.txt") 2>&1
echo "===== setup @ $(date '+%F %T') ====="
STEP=0
die() { echo "  [ABORT] $1"; echo ">>> setup 失败于步骤 $STEP"; exit 1; }

# 0) 修正可能的 CRLF 行尾（Windows 打包带入）
STEP=0
find "$BASE" -maxdepth 1 -name "*.sh" -exec sed -i 's/\r$//' {} + 2>/dev/null
echo "  [OK] 行尾规范化完成"

# 1) conda 环境：克隆 GME-AICoding（离线，自带 torch/triton 全家桶）
STEP=1
CONDA="$HOME/miniconda3/bin/conda"
[ -x "$CONDA" ] || die "miniconda 不可用"
if [ -d "$HOME/miniconda3/envs/dsv41" ]; then
  echo "  [SKIP] dsv41 环境已存在"
else
  echo "  [RUN] conda create -n dsv41 --clone GME-AICoding（约 5-15 分钟）..."
  "$CONDA" create -y -n dsv41 --clone GME-AICoding || die "克隆 GME-AICoding 失败"
fi
PY="$HOME/miniconda3/envs/dsv41/bin/python"
PIP="$HOME/miniconda3/envs/dsv41/bin/pip"
[ -x "$PY" ] || die "dsv41 环境 python 不存在"

# 2) 离线补装小依赖（wheelhouse 优先，失败则试清华镜像）
STEP=2
if [ -d "$PKG/wheels" ] && ls "$PKG/wheels"/*.whl >/dev/null 2>&1; then
  echo "  [RUN] 离线安装 wheelhouse 依赖..."
  "$PIP" install --no-index --find-links "$PKG/wheels" transformers tokenizers sympy pillow 2>&1 | tail -2 \
    || echo "  [WARN] 部分包离线安装失败（可能已存在，无碍）"
else
  echo "  [INFO] 无 wheelhouse，检查现有依赖..."
fi
"$PIP" install -i https://pypi.tuna.tsinghua.edu.cn/simple --quiet transformers tokenizers sympy pillow 2>/dev/null \
  && echo "  [OK] 镜像补装完成" || echo "  [INFO] 镜像不可达（若依赖已齐则无碍，后续自检确认）"

# 3) nvcc：优先系统，缺失则装轮子并记录 DSV41_NVCC
STEP=3
NVCC_PATH=""
if command -v nvcc >/dev/null 2>&1; then
  NVCC_PATH=$(command -v nvcc)
elif ls /usr/local/cuda*/bin/nvcc >/dev/null 2>&1; then
  NVCC_PATH=$(ls -d /usr/local/cuda*/bin/nvcc | head -1)
else
  "$PIP" install --no-index --find-links "$PKG/wheels" nvidia-cuda-nvcc-cu13 2>/dev/null \
    || "$PIP" install -i https://pypi.tuna.tsinghua.edu.cn/simple --quiet nvidia-cuda-nvcc-cu13 2>/dev/null \
    || true
  CAND=$(ls "$HOME/miniconda3/envs/dsv41/lib"/python3*/site-packages/nvidia/cuda_nvcc/bin/nvcc 2>/dev/null | head -1)
  [ -n "$CAND" ] && NVCC_PATH="$CAND"
fi
if [ -n "$NVCC_PATH" ]; then
  echo "export DSV41_NVCC=\"${NVCC_PATH}\"" > "$BASE/env_dsv41.sh"
  echo "  [OK] nvcc: $NVCC_PATH（已写入 env_dsv41.sh）"
else
  echo "  [WARN] nvcc 未找到 —— 首次运行 kernel 编译可能失败，届时解决"
fi

# 4) 解压 dsv41 运行时
STEP=4
RT="$BASE/dsv41_runtime"
mkdir -p "$RT"
if [ -f "$PKG/dsv41.tar.gz" ]; then
  tar xzf "$PKG/dsv41.tar.gz" -C "$RT" || die "运行时解压失败"
  echo "  [OK] 运行时解压至 $RT（$(du -sh "$RT" | cut -f1)）"
else
  die "缺少 $PKG/dsv41.tar.gz"
fi

# 5) encoding/ 依赖：权重目录软链，或 ModelScope 定向补拉
STEP=5
CKPT=/data/models/DeepSeek-V4.1-Flash
if [ ! -e "$RT/encoding" ]; then
  if [ -d "$CKPT/encoding" ]; then
    ln -s "$CKPT/encoding" "$RT/encoding" && echo "  [OK] encoding/ 已软链到运行时目录"
  else
    echo "  [RUN] ModelScope 定向补拉 encoding/ ..."
    "$PY" - <<'PYEOF' || echo "  [WARN] 补拉失败 —— 手工处理：从 ModelScope 仓库下载 encoding/ 目录"
from modelscope.hub.snapshot_download import snapshot_download
try:
    from modelscope import snapshot_download as sd
    p = sd("deepseek-ai/DeepSeek-V4.1-Flash", allow_patterns=["encoding/*"])
    print(f"  [OK] encoding/ 已下载到 {p}")
except Exception as e:
    print(f"  [FAIL] {e}"); raise SystemExit(1)
PYEOF
    ENC=$(find "$HOME/.cache/modelscope" -maxdepth 6 -type d -name encoding 2>/dev/null | head -1)
    [ -n "$ENC" ] && ln -s "$ENC" "$RT/encoding" && echo "  [OK] encoding/ 已软链"
  fi
else
  echo "  [SKIP] encoding/ 已存在"
fi

# 6) 环境自检（torch 版本 / float8 / 各依赖 / encoding 可导入）
STEP=6
cd "$RT" || die "无法进入运行时目录"
[ -f "$BASE/env_dsv41.sh" ] && source "$BASE/env_dsv41.sh"
"$PY" - <<'PYEOF'
ok = True
try:
    import torch
    has = hasattr(torch, "float8_e8m0fnu")
    print(f"  [{'PASS' if has else 'FAIL'}] torch {torch.__version__} float8_e8m0fnu={has}")
    ok = ok and has
except Exception as e:
    print(f"  [FAIL] torch: {e}"); ok = False
for m in ("triton", "transformers", "tokenizers", "sympy", "PIL"):
    try:
        mod = __import__(m)
        v = getattr(mod, "__version__", "?")
        print(f"  [PASS] {m} {v}")
    except Exception as e:
        print(f"  [FAIL] {m}: {e}"); ok = False
try:
    import sys; sys.path.insert(0, ".")
    import encoding
    print("  [PASS] encoding 模块可导入")
except Exception as e:
    print(f"  [FAIL] encoding: {e}"); ok = False
raise SystemExit(0 if ok else 1)
PYEOF
[ $? -ne 0 ] && die "环境自检未通过"

# 7) 2 层速测（kernel 编译链路 + 单卡，~1-2 分钟）
STEP=7
echo "  [RUN] 2 层无 Engram 速测（首次含 kernel 编译）..."
timeout 600 "$PY" -m dsv41.run --ckpt "$CKPT" --devices 0 --n-layers 2 --no-engram \
  --prompt "The capital of France is" --max-new-tokens 8 --max-seq-len 512 2>&1 | tail -5 \
  || die "2 层速测失败（检查上方日志：多为 nvcc/依赖问题）"

echo
echo ">>> setup 全部完成（步骤 0-7）。下一步：bash 20_smoke.sh"
