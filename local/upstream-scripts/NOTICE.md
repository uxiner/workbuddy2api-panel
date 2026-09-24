# 第三方代码来源与许可声明（NOTICE）

本目录包含 **4 个来自第三方项目的 Python 脚本**，按 MIT 许可再分发。

## 原始出处

```
原始项目:  Sliverkiss/workbuddy2api
原始地址:  https://github.com/Sliverkiss/workbuddy2api
许可:      MIT License
版权:      Copyright (c) 2026 Sliverkiss
许可全文:  ../../LICENSE（与本仓库同一份，已包含原始版权声明）
```

⚠️ **该 GitHub 仓库现已删除（HTTP 404）**，无法再从上游获取。

## 本目录文件

| 文件 | 字节 | 说明 |
|---|---|---|
| `task_runner.py` | 73705 | 成长任务一体机（查询→点亮→领奖） |
| `school_open_day_2026.py` | 39867 | 小程序开学季活动 |
| `task_common.py` | 13140 | 公共 HTTP/鉴权层（**295 行完整版**） |
| `global_region.py` | 11024 | 国际版区域支持 |

## 为什么必须提交进版本库

这四份脚本**只存在于已删库的镜像里**。已用 `git log --all -S` 确认：
`task_runner.py` / `school_open_day_2026.py` / `global_region.py`
在 `uxiner/workbuddy2api-panel` 与 `linguo2625469/workbuddy2api-panel`
的**全部历史中从未出现过**。

而 `workbuddy-manager` 的「成长任务一键执行」功能依赖它们。
因此它们是**删库后的唯一副本**，必须有 git 的多副本冗余（本地 + GitHub）保活，
否则一次误删就永久丢失。

> 这也是为什么本目录**刻意不被 `.gitignore` 排除** —— 见 `../.gitignore` 中的说明注释。

## 安全审查

已扫描确认这 4 个文件**不含**任何硬编码凭据：

- 无 Bearer token / API key / 密码字面量
- 无真实 uid 或账号标识
- 凭据全部在运行时从 `auths/` 目录读取（路径经 `WB2A_AUTHS` 环境变量传入）

## 与镜像内版本的差异

本目录保存的是**原版**（未打补丁），MD5：

```
5d11d0bac678c64342ef9ddff3d4bfef  task_common.py
29b2c4fef029114017ba90e10641cd8d  task_runner.py
77ce8ff9702691576ae1770b3afa76f6  school_open_day_2026.py
6795c84c05694e35cef8bf332eef43a2  global_region.py
```

保留原版的目的：便于回滚对比，以及将来判断「上游是否已修复该 bug 而不再需要我们的补丁」。

**群晖上实际运行的是打过补丁的版本**（修复瞬时网络错误导致的整批崩溃），
补丁内容与理由见 `../FIX-task_runner-crash.md`。补丁后的 MD5：

```
cd0365178950ea3c852ec94a29a0b7aa  task_common.py
07a342af896308515197e49630ddec07  task_runner.py
```

## 许可合规

本仓库根目录的 `LICENSE` 为 MIT，且**已包含原始版权声明**
（`Copyright (c) 2026 Sliverkiss (original project: https://github.com/Sliverkiss/workbuddy2api)`），
满足 MIT 对再分发时保留版权声明与许可声明的要求。
