#!/bin/bash
# ===== 30_serve.sh — 正式服务启动（tmux 会话 dsv41，端口 8010）=====
# 可调参数（环境变量覆盖）：
#   DSV41_DEVICES（默认 0,1,2,3,4,5,6,7）  DSV41_PORT（默认 8010）
#   DSV41_HOST（默认 0.0.0.0；仅内网自用可改 127.0.0.1）
#   DSV41_MAXSEQ（默认 65536）
set -u
BASE="$HOME/dsv41_deploy"; LOGS="$BASE/logs"
RT="$BASE/dsv41_runtime"; CKPT=/data/models/DeepSeek-V4.1-Flash
DEVICES="${DSV41_DEVICES:-0,1,2,3,4,5,6,7}"
PORT="${DSV41_PORT:-8010}"
HOST="${DSV41_HOST:-0.0.0.0}"
MAXSEQ="${DSV41_MAXSEQ:-65536}"
mkdir -p "$LOGS"

# 已在跑则不重复启动
if tmux has-session -t dsv41 2>/dev/null; then
  echo "tmux 会话 dsv41 已存在。如需重启先运行: bash 31_stop.sh"
  tmux capture-pane -t dsv41 -p | tail -10
  exit 0
fi

tmux new-session -d -s dsv41 "cd $RT && \
  ${DSV41_NVCC:+export DSV41_NVCC=$DSV41_NVCC;} \
  $HOME/miniconda3/envs/dsv41/bin/python -m dsv41.serve \
  --ckpt $CKPT --devices $DEVICES --host $HOST --port $PORT --max-seq-len $MAXSEQ \
  >> $LOGS/serve.log 2>&1"
echo "serve 已在 tmux 会话 [dsv41] 启动（devices=$DEVICES port=$PORT host=$HOST maxseq=$MAXSEQ）"
echo "日志: $LOGS/serve.log"

# 服务器端健康检查（自身轮询，最长 40 分钟；结果落盘，本地无需重连）
nohup bash -c "
  for i in \$(seq 1 80); do
    sleep 30
    if curl -s --max-time 5 http://127.0.0.1:$PORT/v1/models >/dev/null 2>&1; then
      echo \"\$(date '+%F %T') READY (attempt \$i)\" >> $BASE/logs/serve_status.txt
      exit 0
    fi
  done
  echo \"\$(date '+%F %T') TIMEOUT after 40min\" >> $BASE/logs/serve_status.txt
" >/dev/null 2>&1 &
echo "健康检查已挂后台（每 30s 自查一次，状态写入 logs/serve_status.txt）"
echo
echo "客户端使用示例："
echo "  from openai import OpenAI"
echo "  client = OpenAI(base_url='http://<SERVER_IP>:$PORT/v1', api_key='none')"
echo "  r = client.chat.completions.create(model='deepseek-v4.1-flash',"
echo "      messages=[{'role':'user','content':'你好'}], max_tokens=256)"
