# ops/ — 生产化运维层（xk-gme 定制）

在 [shi3z/deepseekv4.1-A100-custom](https://github.com/shi3z/deepseekv4.1-A100-custom) 运行时之上，
为 8×A100 服务器实际部署 DeepSeek-V4.1-Flash 而增加的运维组件。
2026-10-25/26 两日完成部署并稳定运行，以下全部结论来自实测。

## 生产架构

```
客户端 ──> API 网关 (0.0.0.0:8012, 鉴权+统计+SSE透传)
              │
              └──> dsv41 serve (127.0.0.1:8011, 8卡, systemd 管理自动重启)
```

| 组件 | 位置 | 说明 |
|---|---|---|
| API 网关 | `gateway/gateway.py` | 纯标准库零依赖；Bearer 鉴权、最闲路由（多后端）、逐请求日志、`/stats` 统计、`/health` 探针 |
| systemd 单元 | `systemd/dsv41-*.service` | 模型服务 r1 + 网关 gw；崩溃自动重启；配 linger 可开机自启 |
| 部署脚本 | `deploy/` | 预检→环境→冒烟→基准，全链路自治脚本 |
| 补丁记录 | `patches/` | 实际踩坑后的一次性修复脚本（见下方经验） |
| 旧方案 | `legacy/` | tmux 启动脚本（已被 systemd 取代） |

## 网关版本演进（每版都是实测教训）

| 版本 | 修复的问题 |
|---|---|
| v1 | 初版：鉴权 + 路由 |
| v2 | 响应按 Content-Length / chunked / 连接关闭定界三种方式分别转发 |
| v2.1 | 流式读取改 `read1()` 增量转发——`read(64K)` 等满块会把短 SSE 流挂死 |
| v2.2 | 转发请求带 `Connection: close`（该运行时后端不遵守，此版无效，保留记录） |
| **v2.3** | **转发流中检测 SSE `[DONE]` 标记即收尾**——后端发完流后坚持 keep-alive，网关必须自行终结，否则等连接关闭的客户端会永久挂起（实测修复前挂死 85s+，修复后 0.69s 自然结束） |

## 部署经验（血泪清单，均实测验证）

1. **systemd 单元必须显式设 `LANG=C.UTF-8` + `PYTHONUTF8=1`**：最小环境下 Python 按 ASCII
   解码请求体，含多字节字符的请求直接崩连接。
2. **该运行时的放置器不支持同机多实例**：卡空闲时它不遵守 `--devices` 限制，会把权重摊满
   全部可见 GPU。双副本方案（r2 单元）已实测失败并存档于 systemd/，勿启用。
3. **重启要用"stop → 等显存释放 → start"**：restart 会因旧进程显存未放好而进入
   `not enough GPU memory` 崩溃循环（依赖 Restart=on-failure 自愈，一般 1-2 次内成功）。
4. **上下文 256K 是实用上限**（模型标称 1M，社区实测 ~250K 后质量下降）；70K token 请求
   实测 82s 完成。KV 需求约 1GiB/32K tokens。
5. **内网隔离服务器**的依赖安装顺序：克隆已有 conda 环境（torch 全家桶零下载）→ 离线
   wheel 补小依赖（transformers/tokenizers/sympy/pillow）→ `DSV41_NVCC` 指向系统 nvcc。
6. 运行时硬依赖官方模型仓库的 `encoding/` 目录——从权重目录软链进运行时目录即可。

## 部署流程（deploy/ 脚本按序执行）

```bash
00_preflight.sh    # 只读预检：GPU/权重完整性/依赖版本/nvcc/端口
10_setup_env.sh    # conda 克隆环境 + 运行时解压 + encoding 软链 + 2层速测
20_smoke.sh        # 冒烟四连：速测→8卡全量→HTTP联通→显存核查
# 通过后安装 systemd 单元并启用（见 systemd/ 内注释）
40_bench.sh        # 基准：单流吞吐/MTP A-B/上下文阶梯/EP对比
```

上游运行时的用法、性能数据、原 README 见仓库根目录。
