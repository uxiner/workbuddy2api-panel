# 镜像替换：config 迁移包

**目的**：把群晖现跑的原版配置，翻译成 fork (v1.11.10+) 可直接使用的格式。
**状态**：已生成并 **canary 实测通过**，尚未部署。

---

## 目录内容

| 文件 | 可否提交 | 说明 |
|---|---|---|
| `config.json` | ❌ **含真实凭据** | 从群晖现场配置翻译而来，含 api_key / upstash token |
| `config.example.translated.json` | ✅ 可提交 | 脱敏版，供审阅 diff |
| `translate-config.py` | ✅ | 翻译脚本（可重复运行，幂等） |
| `.gitignore` | ✅ | 显式挡住 `config.json`，不依赖上游规则 |

> ⚠️ `config.json` 已由本目录 `.gitignore` 显式排除。
> 根 `.gitignore` 恰好也有 `config.json` 规则，但那是上游的偶然规则，不应依赖。

---

## 为什么必须翻译

原版与 fork 的 `schedule` 字段口径不同，而 Go 的 `json.Unmarshal` 对**未知字段静默忽略**
（`cmd/server/config.go:255`，非 `DisallowUnknownFields`）。

**实证**（canary 实测，非推测）：

```
直接拿原版配置跑 fork：
  夜猫子已启用：[23] 点        ← 配置里写的是 cat_hours=[1]，被静默丢弃，回落默认 23
翻译后：
  夜猫子已启用：[1] 点        ← 与配置一致 ✓
```

即：不翻译也能跑，**不报任何错**，但夜猫任务会在错误的时间执行。

---

## 翻译映射

| 原版 | fork | 处理 | 依据 |
|---|---|---|---|
| `cat_hours` | `blackcat_hours` | **改名** | 语义等价：`cat_hours=[1]` 落在 23:00–08:00 夜猫窗口内；fork 注释明确 `blackcat_hours` 即夜猫子 |
| `cat_enabled` | `blackcat_enabled` | **改名** | 同上 |
| `school_hours` | — | **删除** | 上游 `729247b`：开学季活动 9/24 结束，`internal/scheduler/school.go` 已删除 |
| `school_enabled` | — | **删除** | 同上 |
| — | `growth_hours` | **新增** `[1]` | fork 内置成长任务队列，01:00 自动扫描全部账号待办 |
| — | `growth_enabled` | **新增** `true` | 缺省即启用，显式写出便于审阅 |

其余字段（`pool` / `cooldown` / `upstream` / `prompt` / `global` / `session_sticky` /
`features` / `upstash` / `listen` / `api_key` / `auth_dir` / `state_file`）**原样保留**。

---

## 实测验证（2026-09-29）

用翻译后的配置在群晖起隔离 canary（端口 17864，挂载生产同一份 `auths/`）：

| 检查 | 结果 |
|---|---|
| 账号加载 | ✅ 8 个 |
| 启动日志 | ✅ `夜猫子已启用：[1] 点`（**目标字段翻译成功**） |
| 面板 API 读回配置 | ✅ `blackcat_hours=[1]`、`growth_hours=[1]`、`growth_enabled=true`，`school_*` 已消失 |
| `/healthz` | ✅ `healthy=8, total=8` |
| 生产影响 | ✅ 无（canary 已删除，生产 `healthy=8`，config 哈希未变） |

---

## 部署步骤（替换镜像时）

```bash
D=/var/packages/ContainerManager/target/usr/bin/docker
NAS=/volume1/docker/workbuddy2api

# 0) 备份（必做）
$D exec ... # 或直接：
cp -a $NAS/config.json $NAS/config.json.bak-$(date +%F-%H%M)
cp -a $NAS/docker-compose.yml $NAS/docker-compose.yml.bak-$(date +%F-%H%M)
tar czf /volume1/docker/_wb2api-backups/pre-switch-$(date +%F-%H%M).tgz -C /volume1/docker workbuddy2api

# 1) 放入翻译后的配置（注意保留原 api_key —— 本目录 config.json 已含）
cp local/migration/config.json $NAS/config.json     # 从本机传上去
chown 10001:10001 $NAS/config.json && chmod 600 $NAS/config.json

# 2) 改 compose 的 image（建议锁 digest，避免上游重建 latest）
#    image: ghcr.io/uxiner/workbuddy2api-panel@sha256:<digest>

# 3) 重建
cd $NAS && $D compose up -d

# 4) 验收（关键：夜猫必须是 1 点）
$D logs --tail 20 workbuddy2api | grep 夜猫子     # 期望：[1] 点
curl -s http://192.168.50.199:7863/healthz        # 期望 healthy=8
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.50.199:7863/panel/   # 期望 200
```

## 回滚

```bash
cd $NAS
cp docker-compose.yml.bak-<ts> docker-compose.yml
cp config.json.bak-<ts> config.json
$D compose up -d
```

---

## 替换后的额外好处：growth 可替代 task_runner.py

fork 的 `growth_hours` 排程走**网关内置**的成长任务队列
（`internal/panel/taskcenter.go` 的 `RunGrowthQueueOnce`，经 `sch.SetGrowthHook` 挂载），
直接调 Go 原生 `ListTasks` / `ListTasksMP`，**不依赖 `task_runner.py`**。

→ 替换镜像后，理论上可以让内置 growth 排程接管日常扫任务，
逐步退役那个「删库遗留 + 需要手工打补丁」的 `task_runner.py`。
建议先并行观察一段时间再决定（两者都幂等，重复执行安全）。
