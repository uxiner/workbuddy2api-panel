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

## ✅ 已入库（有意为之）

这 4 个脚本**已提交进 git**，这是刻意的决定：

- 它们是**删库后的唯一副本**，必须有 git 的多副本冗余（本地 + GitHub）保活
- `local/` 上游永不包含 → **零 merge 冲突**
- 已扫描确认**不含任何硬编码凭据 / 真实 uid**
- MIT 许可合规：根目录 `LICENSE` 本就含原始版权声明
  （`Copyright (c) 2026 Sliverkiss (original project: https://github.com/Sliverkiss/workbuddy2api)`），
  出处另见本目录 `NOTICE.md`

> 早前版本曾把本目录加入 `.gitignore` —— 那是个**错误**：把唯一副本排除出版本控制，
> 等于放弃了 git 的冗余保护，一次误删就永久丢失。已更正。

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

### ★ 正确放置位置：宿主机 `scripts/`（已实施）

`_script_path()` **宿主机目录优先**，而它是 bind mount，**不受镜像重建影响**：

```
/volume1/docker/workbuddy2api/scripts/    ← ① 优先（manager 内为 /opt/workbuddy2api/scripts/）
/volume1/docker/workbuddy-manager/data/upstream-scripts/   ← ② 回落（双保险）
```

**已把 4 个脚本 + 补丁放入 ①**，于是：
- 替换成 fork 镜像后**不会失效**（manager 从宿主机读，不从镜像读）
- 清空 `data/` 也不丢
- 不会被 `docker cp` 覆盖

> 补充：`docker cp` 经实测是**合并**语义，不会删除目标目录中镜像里不存在的文件。
> 这只作为次要保障；**主保障是放在宿主机 `scripts/`**。

### 另一个已确认的兼容性缺口

`task_runner.py` 依赖 `tc.auth_is_global`，而 **fork 的精简版 `task_common.py` 没有这个函数**。
若把 fork 的 `task_common.py` 放进镜像（或手工替换），`task_runner.py` 会在
**导入后首次调用时 AttributeError 崩溃**。

**因此：替换镜像时，务必保留本目录的 `task_common.py`（295 行版）**，
不要用 fork 的 222 行版覆盖它。

## 一键部署

```bash
./apply.sh            # 部署到群晖（原版 + 补丁 → 宿主机 scripts/ 与回落目录）
./apply.sh --verify   # 只读：检查群晖当前状态
./apply.sh --local    # 只在本机校验补丁能干净应用
```

补丁存放在 `patches/*.patch`（标准 unified diff，可 `patch -p0` 应用），
因此本目录的 `*.py` 保持**原版未改动**，便于：
1. 审阅补丁到底改了什么（`cat patches/*.patch`）
2. 将来上游若修复该 bug，据此判断是否还需要自己的补丁

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
