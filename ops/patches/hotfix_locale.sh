#!/bin/bash
# ===== 热修复：1) 单元加 UTF-8 locale（修中文请求崩溃）2) 换网关 v2（修流式空响应）=====
set -u
BASE="$HOME/dsv41_deploy"
U="$HOME/.config/systemd/user"
LOG="$BASE/logs/hotfix.txt"
exec > >(tee -a "$LOG") 2>&1
echo "=== hotfix @ $(date '+%F %T') ==="

# 1) 单元补 locale（用 sed 在两个副本单元的 Environment 行后追加）
for u in dsv41-r1 dsv41-r2; do
  if ! grep -q "^Environment=PYTHONUTF8" "$U/$u.service"; then
    sed -i '/^Environment=DSV41_NVCC/a Environment=LANG=C.UTF-8\nEnvironment=LC_ALL=C.UTF-8\nEnvironment=PYTHONUTF8=1' "$U/$u.service"
    echo "  [OK] $u 补 locale"
  fi
done
systemctl --user daemon-reload && echo "  [OK] daemon-reload"

# 2) 重启两个副本（网关不用动，下一步换文件后重启）
systemctl --user restart dsv41-r1 dsv41-r2
echo "  [RUN] r1/r2 重启中（各自 ~90s 加载）"

# 3) 等两个副本就绪
wait_port() {
  for i in $(seq 1 40); do
    sleep 15
    curl -s --max-time 5 "http://127.0.0.1:$1/v1/models" >/dev/null 2>&1 && return 0
    systemctl --user is-active "$2" 2>/dev/null | grep -q active || return 1
  done
  return 1
}
if wait_port 8011 dsv41-r1 && wait_port 8013 dsv41-r2; then
  echo "  [OK] r1/r2 均就绪"
else
  echo "  [FAIL] 副本未就绪，查 journalctl --user -u dsv41-r1 -u dsv41-r2"
  echo "VERDICT: FAIL_READY"; exit 1
fi

# 4) 重启网关（gateway.py 已由外部推送为 v2）
systemctl --user restart dsv41-gw
sleep 5
curl -s --max-time 5 http://127.0.0.1:8012/health >/dev/null && echo "  [OK] 网关就绪" || { echo "  [FAIL] 网关未就绪"; echo "VERDICT: FAIL_GW"; exit 1; }

# 5) 验证：直连 8011 裸中文 / 经网关裸中文 / 经网关英文流式
echo "--- V1 直连8011裸中文 ---"
curl -s --max-time 120 http://127.0.0.1:8011/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"你好，一句话自我介绍"}],"max_tokens":48}' | head -c 200
echo; echo "--- V2 网关裸中文 ---"
curl -s --max-time 120 -H 'Authorization: Bearer changeme' http://127.0.0.1:8012/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"用一句话介绍长城"}],"max_tokens":48}' | head -c 200
echo; echo "--- V3 网关英文流式（应有 data: 行）---"
curl -sN --max-time 60 -H 'Authorization: Bearer changeme' http://127.0.0.1:8012/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"count to 3"}],"max_tokens":24,"stream":true}' | head -3
echo
echo "VERDICT: DONE（人工核对上方三段输出）"
