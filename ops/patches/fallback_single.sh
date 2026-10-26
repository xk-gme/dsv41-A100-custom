#!/bin/bash
# ===== 回退到单副本 8 卡 + 网关（放弃双副本：放置器不支持同机多实例）=====
set -u
BASE="$HOME/dsv41_deploy"
U="$HOME/.config/systemd/user"
LOG="$BASE/logs/fallback.txt"
exec > >(tee -a "$LOG") 2>&1
echo "=== fallback @ $(date '+%F %T') ==="

# 1) 停双副本（r1 在崩溃循环，r2 占着 8 卡）
systemctl --user stop dsv41-r1 dsv41-r2
echo "  [OK] r1/r2 已停"

# 2) 等 8 卡释放
for i in $(seq 1 24); do
  sleep 5
  M=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | sort -rn | head -1)
  [ "$M" -lt 1000 ] && break
done
echo "  [INFO] 最大单卡残留: ${M}MiB"

# 3) r1 单元改为 8 卡（全天验证过的配置）
sed -i 's/--devices 0,1,2,3 /--devices 0,1,2,3,4,5,6,7 /' "$U/dsv41-r1.service" && echo "  [OK] r1 改为 8 卡"

# 4) 网关后端改为单 8011
sed -i 's#DSV41_GW_BACKENDS=127.0.0.1:8011,127.0.0.1:8013#DSV41_GW_BACKENDS=127.0.0.1:8011#' "$U/dsv41-gw.service" && echo "  [OK] 网关后端改为单副本"

systemctl --user daemon-reload

# 5) 启动 r1 并等待就绪
systemctl --user start dsv41-r1
READY=0
for i in $(seq 1 40); do
  sleep 15
  if curl -s --max-time 5 http://127.0.0.1:8011/v1/models >/dev/null 2>&1; then READY=1; break; fi
  systemctl --user is-active dsv41-r1 2>/dev/null | grep -qx active || continue
done
echo "  [INFO] r1 就绪: $READY（$((i*15))s）"

# 6) 网关上线
systemctl --user restart dsv41-gw
sleep 5
if curl -s --max-time 5 http://127.0.0.1:8012/health >/dev/null 2>&1; then
  echo "  [OK] 网关就绪（v2 单后端）"
else
  echo "  [FAIL] 网关异常"; echo "VERDICT: FAIL_GW"; exit 1
fi

if [ "$READY" -ne 1 ]; then
  echo "  [FAIL] r1 未就绪"; echo "VERDICT: FAIL_R1"; exit 1
fi

# 7) 服务器端验证三连：直连中文 / 网关中文 / 网关流式
echo "--- V1 直连8011裸中文（locale修复验证）---"
curl -s --max-time 120 http://127.0.0.1:8011/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"你好，一句话自我介绍"}],"max_tokens":48}' | head -c 220
echo; echo "--- V2 网关裸中文 ---"
curl -s --max-time 120 -H 'Authorization: Bearer changeme' http://127.0.0.1:8012/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"用一句话介绍长城"}],"max_tokens":48}' | head -c 220
echo; echo "--- V3 网关英文流式（v2修复验证，应有data:行）---"
curl -sN --max-time 60 -H 'Authorization: Bearer changeme' http://127.0.0.1:8012/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"count to 3"}],"max_tokens":24,"stream":true}' | head -3
echo
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader
echo "VERDICT: DONE（核对 V1-V3 输出）"
