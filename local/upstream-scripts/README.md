# 原版镜像专有脚本 —— 删库后唯一副本，请勿删除

## 为什么存在这个目录

这 4 个脚本来自**已删库**的 `ghcr.io/sliverkiss/workbuddy2api` 镜像内的 `/app/scripts/`。
经实测确认：

| 脚本 | 在 `uxiner` fork | 在 `linguo2625469` 上游 | 说明 |
|---|---|---|---|
| `task_runner.py` (73705B) | ❌ 无 | ❌ 无 | **两仓库都没有，仅存于镜像** |
| `school_open_day_2026.py` (39867B) | ❌ 无 | ❌ 无 | 同上 |
| `global_region.py` (11024B) | ❌ 无 | ❌ 无 | 同上 |
| `task_common.py` (13140B) | ⚠️ 有，但**是精简版** | ⚠️ 同 | fork 版 222 行 vs 镜像版 295 行 |

已用 `git log --all -S` 确认：`task_runner.py` 在**两个仓库的全部历史中从未出现过**。
因此这四份是本机唯一的备份 —— **上游删库后已无处可取**。

保存时间：2026-09-24 20:53，MD5：

```
6795c84c05694e35cef8bf332eef43a2  global_region.py
77ce8ff9702691576ae1770b3afa76f6  school_open_day_2026.py
5d11d0bac678c64342ef9ddff3d4bfef  task_common.py     ← 原版，未打补丁
29b2c4fef029114017ba90e10641cd8d  task_runner.py     ← 原版，未打补丁
```

## ⚠️ 发布风险（重要）

本目录位于 `local/`，**受版本控制**，而 `uxiner/workbuddy2api-panel` 是 **public 仓库**。
原版是 MIT 许可（`Copyright (c) 2026 Sliverkiss`），再分发需保留版权声明。

**如果你不打算公开这些脚本**，请在提交前把本目录加入 `local/.gitignore`，
或用 `git update-index --skip-worktree` 排除。当前**尚未提交**。

## ★ 对镜像替换的决定性影响

`workbuddy-manager` 的「一键做任务」功能依赖这些脚本，其获取顺序是
（`taskrun.py` 的 `_script_path()`）：

1. **宿主机挂载目录** `<WB_UPSTREAM_DIR>/scripts/task_runner.py` —— 群晖上是
   `/volume1/docker/workbuddy2api/scripts/`（**当前不存在**）
2. 否则从**上游容器镜像** `docker cp <container>:/app/scripts/.` 提取到
   `/app/data/upstream-scripts/`，用镜像 ID 作指纹缓存

### 如果替换成 fork 的镜像，会发生什么

fork 的 `Dockerfile` 只复制了一个脚本：

```dockerfile
COPY scripts/probe_active.py /app/scripts/probe_active.py
```

而 `taskrun.py:225` 在提取后会检查：

```python
if not (dest / 'task_runner.py').is_file():
    return _fail('提取后仍未找到 task_runner.py（容器内 /app/scripts/ 是否存在？）')
```

**好消息**（已实测 `docker cp` 语义）：`docker cp` 是**合并**，不会删除目标目录里的已有文件。
所以替换镜像后，`/app/data/upstream-scripts/` 里**旧的 `task_runner.py` 会残留**，
功能**不会立刻失效** —— 但也不会更新（新镜像里没有可更新的版本）。

**坏消息 —— 真正的坑**：新镜像里**没有** `task_common.py`。
但 `docker cp` 合并语义下旧文件仍残留，所以只要不手动清理该目录，就还能跑。
**一旦 `docker compose down` 后清空 data、或迁移到新机器，这 4 个脚本就会永久消失。**

### 另一个已确认的兼容性缺口

`task_runner.py` 依赖 `tc.auth_is_global`，而 **fork 的精简版 `task_common.py` 没有这个函数**。
若把 fork 的 `task_common.py` 放进镜像（或手工替换），`task_runner.py` 会在
**导入后首次调用时 AttributeError 崩溃**。

**因此：替换镜像时，务必保留本目录的 `task_common.py`（295 行版）**，
不要用 fork 的 222 行版覆盖它。

## 恢复方法

```bash
# 把抢救的脚本放回群晖（保持属主 10001）
scp local/upstream-scripts/*.py temp-admin@192.168.50.199:/tmp/
ssh temp-admin@192.168.50.199 "sudo cp /tmp/*.py /volume1/docker/workbuddy-manager/data/upstream-scripts/ \
  && sudo chown 10001:10001 /volume1/docker/workbuddy-manager/data/upstream-scripts/*.py"
```

## 已打补丁版本的差异

群晖上运行的是**打过补丁**的版本（修复瞬时网络错误导致的整批崩溃，见 `../FIX-task_runner-crash.md`）。
本目录保存的是**原版**，用于：
1. 回滚对比
2. 将来上游若修复了该 bug，可据此判断是否还需要自己的补丁
