#!/bin/bash
# ===== fetch_wheels_local.sh — 本地执行：为服务器准备离线依赖轮子 =====
# 在本地（git-bash，需已安装 python）运行，产物进 deploy/pkg/wheels/
# 平台目标：manylinux x86_64 / CPython 3.12（服务器 dsv41 环境口径）
#
# 说明：torch/triton 不在此列 —— 它们由 conda 克隆 GME-AICoding 获得；
# 若 preflight 显示克隆路线不可用，才需要额外准备 torch 轮子（~2.5GB，
# 走 GitHub Release 中转分片方案，见防封号文档 §4.2）。

set -e
WHEELS="$(dirname "$0")/pkg/wheels"
mkdir -p "$WHEELS"
cd "$WHEELS"

echo "下载目标平台轮子（manylinux2014_x86_64 / cp312）..."
python -m pip download \
  --dest . \
  --platform manylinux2014_x86_64 \
  --implementation cp \
  --python-version 3.12 \
  --only-binary=:all: \
  transformers tokenizers sympy pillow nvidia-cuda-nvcc-cu13

echo
echo "清单："
ls -la
echo
echo "完成。将 wheels/ 随 deploy.tar.gz 一起推送（总大小应 < 300MB，scp 单次可接受；"
echo "若超预算则仅推送 dsv41.tar.gz，轮子改走 GitHub Release 中转）。"
