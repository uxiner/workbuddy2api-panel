# 修复：manager「一键做任务」整批崩溃

**日期**：2026-09-24
**影响**：`workbuddy-manager`（7864）面板的「成长任务一键执行 → 做任务 / 一键领奖」
**状态**：✅ 已修复并验证

---

## 1. 现象

面板点「一键做任务」报错，堆栈：

```
File "/app/data/upstream-scripts/task_runner.py", line 1452, in <module>   main()
File ".../task_runner.py", line 1446, in main                              process_account(c, a, stats)
File ".../task_runner.py", line 1355, in process_account                   process_task(auth, code, t, opts, stats)
File ".../task_runner.py", line 1152, in process_task                      light_up(...)
File ".../task_runner.py", line 1188, in light_up                          if not _accept_with_verify(...)
File ".../task_runner.py", line 1172, in _accept_with_verify               t = tc.task_status(auth, code) or {}
```

---

## 2. 根因

**`task_common.py` 的 `_request()` 把网络层失败统一返回 `-1`，而 `list_tasks()` 见到非 200 就 `raise`。**

```python
def _request(...):
    ...
    except Exception as e:
        return -1, {"err": repr(e)}        # ← 网络层失败（超时/连接重置）

def list_tasks(auth) -> list:
    st, d = do_get(auth, chat_base(auth), PATH_LIST_TASKS)
    if st != 200:
        raise RuntimeError(f"list_tasks http={st}")   # ← 瞬时抖动直接抛
```

复现日志（完整 `--yes` 批次）：

```
[task_runner] 20e9aa1e Model_chat_GLM5.2: report 1/1 200 code=0 id=
Traceback (most recent call last):
  ...
RuntimeError: list_tasks http=-1
```

### 真实的破坏面（比截图显示的严重）

崩溃发生在**第 2 个账号**的 `Model_chat_GLM5.2` 任务上。由于 `main()` 里
`process_account()` **没有 try/except**，异常直接冒到顶层 → **整个批次终止**，
第 3~8 个账号**完全没有执行**。

即：一次瞬时抖动 = 6 个账号当天任务全部漏做，而面板只显示一个 traceback。

### 佐证：端点本身是健康的

直接对腾讯端点连打 4 次，全部正常：

```
尝试1: http=200 耗时=0.38s tasks=19
尝试2: http=200 耗时=0.45s tasks=19
尝试3: http=200 耗时=0.41s tasks=19
尝试4: http=200 耗时=0.43s tasks=19
```

→ 确认是**偶发瞬时错误**，不是接口变更或鉴权问题。

### 对比：同文件其它段落已有防护

`process_account` 里 `mp` 段（line 1367）和 `school` 段**都有** try/except，
唯独 growth 主循环（line 1355）没有 —— 属**遗漏**，非有意设计。

---

## 3. 修复

### 3.1 `task_common.py` — GET 请求加瞬时错误重试

```python
_TRANSIENT_RETRIES   = 2
_TRANSIENT_RETRY_GAP = 1.5

def _request(auth, method, base, path, body=None, headers=None, timeout=30):
    ...
    def _once():
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, json.loads(r.read().decode("utf-8", "replace"))
        except urllib.error.HTTPError as e:
            ...
        except Exception as e:
            return -1, {"err": repr(e)}

    st, d = _once()
    if method == "GET":
        for i in range(_TRANSIENT_RETRIES):
            if st != -1:
                break
            time.sleep(_TRANSIENT_RETRY_GAP * (i + 1))
            st, d = _once()
    return st, d
```

**为什么只重试 GET**：GET 幂等，重试绝对安全；POST（上报/领奖）**不重试**，
避免「服务端已处理但响应丢失」造成**重复入账**。

### 3.2 `task_runner.py` — 任务级 + 账号级隔离

```python
# growth 主循环（line 1355）
try:
    process_task(auth, code, t, opts, stats)
except Exception as e:
    print(f"[task_runner] {uid8} {code}: 任务异常，跳过待下次: {e!r}")
    stats["fail"] += 1

# main 账号循环（line 1446）
try:
    process_account(c, a, stats)
except Exception as e:
    print(f"ERR: [task_runner] {uid8} 账号处理异常，跳过: {e!r}")
    stats["fail"] += 1
```

效果：单个任务/账号出错**不再拖垮整批**，与文件内其它段的既有口径一致。

---

## 4. 验证

### 4.1 故障注入（决定性证据）

打桩让底层 `urlopen` 前 2 次抛 `OSError`：

```
修复后：✓ list_tasks 成功: 19 个任务 (重试3次调用, 耗时8.0s)
修复前：RuntimeError: list_tasks http=-1   → 崩溃
```

### 4.2 持续故障下仍抛出（但被隔离）

```
持续故障下 list_tasks 仍抛出（符合预期）: RuntimeError('list_tasks http=-1')
→ 此时由 task_runner 的任务级 try/except 兜住，不再终止整批
```

### 4.3 端到端全量

`task_runner.py ALL --yes`（8 账号全量）：

| 指标 | 修复前 | 修复后 |
|---|---|---|
| traceback | 1（第 2 个账号即崩） | **0** |
| 处理到的账号数 | 2 / 8 | **6+ / 8**（跑满 timeout 前连续处理） |
| 单账号任务数 | — | 25 |

单账号 `--only Sequential_Tasks_1` 验证：accept → report → re-read → claim 全链路正常，
`credit=+100 energy=+5`。

---

## 5. 部署位置

| 位置 | 路径 |
|---|---|
| 宿主机（持久） | `/volume1/docker/workbuddy-manager/data/upstream-scripts/{task_common,task_runner}.py` |
| 容器内（同挂载卷） | `/app/data/upstream-scripts/` |

属主 `10001:10001`，权限 `755`。

**补丁后 MD5**：

```
cd0365178950ea3c852ec94a29a0b7aa  task_common.py
07a342af896308515197e49630ddec07  task_runner.py
```

## 6. 回滚

原版已双重备份：

```bash
# 容器内（.orig 后缀）
/app/data/upstream-scripts/task_common.py.orig
/app/data/upstream-scripts/task_runner.py.orig

# 宿主机
/volume1/docker/wb2api-scripts-backup-2026-09-24-2040.tgz   # 含全部 4 个脚本

# 本机
local/upstream-scripts/*.py   # 原版全文（MD5 见该目录 README）
```

回滚：

```bash
D=/var/packages/ContainerManager/target/usr/bin/docker
sudo cp /volume1/docker/workbuddy-manager/data/upstream-scripts/task_common.py.orig \
        /volume1/docker/workbuddy-manager/data/upstream-scripts/task_common.py
sudo cp /volume1/docker/workbuddy-manager/data/upstream-scripts/task_runner.py.orig \
        /volume1/docker/workbuddy-manager/data/upstream-scripts/task_runner.py
sudo chown 10001:10001 /volume1/docker/workbuddy-manager/data/upstream-scripts/*.py
```

## 7. ⚠️ 补丁可能被覆盖的情形

`taskrun.py` 用**镜像 ID** 作缓存指纹（`_cache_is_fresh()`）：

- **镜像 ID 不变** → 不重新提取 → 补丁**保留** ✅（当前状态）
- **重建/替换 workbuddy2api 镜像** → ID 变化 → 下次调用 `extract_scripts()` 重新 `docker cp`
  → 用镜像内的 `task_runner.py` **覆盖**宿主机文件 → **补丁丢失** ⚠️

> 注：`docker cp` 是**合并**语义（实测确认：目标目录里镜像中不存在的文件不会被删）。
> 所以如果新镜像的 `/app/scripts/` 里**没有** `task_runner.py`，
> 旧文件会残留 —— 此时 `_fail('提取后仍未找到…')` 也不会触发，因为文件还在。
> 但**补丁会被镜像内的旧版本覆盖**（只要镜像里有该文件）。

**因此：每次替换/重建 workbuddy2api 镜像后，需重新应用本补丁。**
建议把补丁文件一并纳入 `local/` 管理，并在替换流程中加一步「重新打补丁」。

## 8. 上游是否已修复？

`linguo2625469/workbuddy2api-panel` **根本没有 `task_runner.py`**（全历史搜证），
所以上游不会有这个修复 —— 这属于原版镜像专有代码，随删库成为孤儿。

`uxiner` fork 的 `scripts/task_common.py`（222 行精简版）**有同样的 `list_tasks` raise 逻辑**，
但 fork 里没有 `task_runner.py` 调用它，故暂不影响；若将来移植需一并修。
