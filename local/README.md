# local/ — 二开与上游同步

本目录是**纯本地目录**，上游 (`linguo2625469/workbuddy2api-panel`) 永远不会包含 `local/`，
所以这里的改动**零冲突风险**。二开相关的工具、文档、变更记录都放这里。

## 仓库拓扑

```
linguo2625469/workbuddy2api-panel   = upstream  真正的活跃上游（866⭐，一天一个 release）
        └─ uxiner/workbuddy2api-panel = origin    你的 fork（就地二开）
```

> ⚠️ README 里写的 `Sliverkiss/workbuddy2api` 已公开访问 404。别去同步它。
> 你的 fork 的 parent 已指向 `linguo2625469`，`upstream` remote 也已按此配置。

## 一次性配置（已完成，供换机参考）

```bash
git clone https://github.com/uxiner/workbuddy2api-panel.git
cd workbuddy2api-panel
git remote add upstream https://github.com/linguo2625469/workbuddy2api-panel.git
git remote set-url --push upstream no_push      # 防止手滑推到上游
git config rerere.enabled true                  # 记住解过的冲突
git config rerere.autoupdate true
git config merge.conflictstyle zdiff3           # 冲突块带共同祖先，好解 10 倍
git fetch upstream --tags
```

## 日常用法

```bash
./local/sync-upstream.sh status     # 我改了什么 / 落后上游多少（最常用）
./local/sync-upstream.sh check      # 拉取上游，侦察下一个版本改了什么，预测冲突
./local/sync-upstream.sh sync       # 按最新 tag 同步（在独立分支解冲突，可回退）
./local/sync-upstream.sh sync v1.11.7   # 同步到指定 tag
./local/sync-upstream.sh abort      # 同步搞砸了，一键回退
```

## 三条铁律

1. **按 tag 同步，不要跟 `upstream/main` 的 HEAD。**
   上游一天多次提交，HEAD 常在半个功能没写完的状态。跟 HEAD 会让你天天解
   无意义的冲突。tag 是上游自己认可的稳定点。

2. **永远不要 force 覆盖 main。**
   `gh repo sync --force`、`git push --force`、`git reset --hard upstream/main`
   都会静默抹掉你的二开代码。你的 fork 是你唯一的备份。

3. **每次解完冲突必须跑测试。**
   这个项目测试密度很高，`internal/panel/frontend_test.go` 还专门做面板 JS 的
   运行时冒烟测试。编译通过 ≠ 没坏。

```bash
go build ./... && go vet ./... && go test ./...
```

## 二开应该往哪写（决定未来冲突量）

上游改得最凶的文件 —— 尽量别直接编辑：

| 文件 | 大小 | 说明 |
|---|---|---|
| `internal/upstream/client.go` | 86KB | 吸收腾讯 API 变更的地方 |
| `internal/panel/app.js` | 85KB | 单文件 SPA，几乎每个 release 都在改 |
| `internal/server/handler.go` | 57KB | 请求主链路 |
| `internal/panel/index.html` | 53KB | 面板结构 |
| `cmd/server/config.go` | 24KB | 配置项持续新增 |

低冲突的落点：

- **新建 `internal/你的功能/` 包**，只在 `cmd/server/wiring.go` 加一行接线 → 冲突面 = 1 行
- **配置类需求走 `config.example.json` + 面板热更新**，很多需求根本不用改代码
- **面板定制**：新建 `internal/panel/custom.js` + 在 `index.html` 加一行引用，
  远好过改 `app.js`（app.js 用 `go:embed` 内嵌，加文件只需动 `panel.go` 一处）
- **提示词**：`internal/prompt/defaultprompt.md` 很少被动

`local/` 目录本身是零冲突区。

## 绝对不要做的事

**不要改 `go.mod` 里的 module path**（现为 `github.com/linguo2625469/workbuddy2api-panel`）。
module path 不需要和你的 fork URL 一致。改它 = 全仓库 import 全部改动 = 永久性、
每文件、每次同步都冲突。你自己新建的包 import 上游包时，沿用这个 module path。

## commit 约定

二开 commit 一律加 `local:` 前缀，并同步记一行到 `LOCAL_CHANGES.md`：

```bash
git commit -m "local: 面板加积分导出按钮"
git log --grep '^local:' --oneline      # 随时列出全部二开
```

记录"为什么改"很关键：当上游后来实现了同一个功能，这份记录就是你敢删掉自己
那份代码的依据 —— **上游抢先实现了你的功能，是好事，删掉自己的，同步成本归零。**

## 冲突的三种类型与对策

| 类型 | 场景 | 对策 |
|---|---|---|
| 结构性 | 同一行两边都改 | 手工合并，保留**语义**而非文本；改完跑测试 |
| 功能性重复 | 上游已实现了你要的功能 | **删掉自己那份，用上游的**。最优解，不是妥协 |
| 接口漂移 | 上游重构了内部函数签名 | 编译失败会全部告诉你 → 跟着改，最省心 |

`git rerere` 已开启：解过一次的冲突，上游下次改同一处会自动套用你的解法。
后台自动运行的仓库建议再加一条定时体检（见 `sync-upstream.sh check`）。

## Go 环境（已装好）

本机 Go 由 Homebrew 安装：`go1.27.1 darwin/arm64`（`/opt/homebrew/bin/go`）。
`go.mod` 声明 `go 1.22.5`，1.27 向下兼容，构建与测试全部通过。

**缓存位置**：默认的 `~/go` 与 `~/Library/Caches/go-build` 在受限环境下不可写，
所以 `verify` 会把缓存重定向到工作区内的 `.gocache/`：

- `GOMODCACHE=./.gocache/mod`
- `GOCACHE=./.gocache/build`

这些通过 `local/sync-upstream.sh` 的 `setup_go_env` 自动设置，**无需手动 export**。
`.gocache/` 已写入 `.git/info/exclude`（纯本地规则，不进版本库、与上游零冲突）。

> ⚠️ **`GOFLAGS` 必须是 `-mod=readonly`。**
> 若用 `-mod=mod`，`go build` 会静默重写 `go.mod`（例如把间接依赖提升为直接依赖），
> 那等于改动了上游文件，会给每次同步制造无谓冲突。`verify` 现在会在构建前后
> 比对 `go.mod`/`go.sum` 的哈希，一旦被改写立即告警并自动还原。

手动跑 Go 命令时（不经脚本）：

```bash
export GOMODCACHE="$PWD/.gocache/mod" GOCACHE="$PWD/.gocache/build" GOFLAGS=-mod=readonly
go build ./... && go test ./...
```
