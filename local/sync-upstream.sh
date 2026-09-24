#!/usr/bin/env bash
# local/sync-upstream.sh — 按 tag 同步上游，二开冲突可控、可回退
#
#   status          我现在偏离上游多少？改了哪些文件？
#   check           拉取上游，侦察下一个版本改了什么、预测冲突文件
#   sync [tag]      同步到指定 tag（默认最新），在独立分支解冲突
#   verify          编译 + vet + 测试（同步后必跑）
#   abort           同步搞砸了，回退到同步前的状态
#   conflicts       列出未解决的冲突文件 + 冲突标记速查
#   tags            列出版本 tag
#   bootstrap       全新 clone 后一键配好 remote 与 git 配置
#
# 设计要点：
#   - 只在独立分支上 merge，main 从不处于「半解完冲突」状态
#   - 冲突时立刻打印冲突文件 + 三种对策，不猜
#   - 同步完成后 main 用 --no-ff 合并，保留清晰的同步边界
#   - 任何一步失败都不静默继续

set -euo pipefail

UPSTREAM="${UPSTREAM_REMOTE:-upstream}"
ORIGIN="${ORIGIN_REMOTE:-origin}"
MAIN_BRANCH="${MAIN_BRANCH:-main}"

c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_yel()  { printf '\033[33m%s\033[0m\n' "$*"; }
c_cyn()  { printf '\033[36m%s\033[0m\n' "$*"; }
hdr()    { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

die() { c_red "错误：$*"; exit 1; }

# git clone 不会继承本地 config（rerere / zdiff3 会静默失效），
# 所以每次运行都自愈式补上，而不是只在 bootstrap 时设一次。
ensure_git_config() {
  [ "$(git config --local --get rerere.enabled || echo '')" = "true" ] \
    || git config --local rerere.enabled true
  [ "$(git config --local --get rerere.autoupdate || echo '')" = "true" ] \
    || git config --local rerere.autoupdate true
  [ "$(git config --local --get merge.conflictstyle || echo '')" = "zdiff3" ] \
    || git config --local merge.conflictstyle zdiff3
}

need_repo() {
  git rev-parse --git-dir >/dev/null 2>&1 || die "当前目录不是 git 仓库"
  git remote get-url "$UPSTREAM" >/dev/null 2>&1 \
    || die "没有 remote '$UPSTREAM'。执行 bootstrap，或手动：
  git remote add $UPSTREAM https://github.com/linguo2625469/workbuddy2api-panel.git
  git config rerere.enabled true && git config merge.conflictstyle zdiff3"
  ensure_git_config
}

fetch_upstream() {
  c_cyn "→ 拉取上游 $UPSTREAM ..."
  git fetch "$UPSTREAM" --tags --prune --quiet \
    || die "拉取失败，检查网络或 upstream URL"
}

# 最新版本 tag（按语义版本排序）
latest_tag() {
  git tag -l 'v*' --sort=-v:refname | head -1
}

# 上一个 tag（相对给定 tag）
prev_tag() {
  git tag -l 'v*' --sort=-v:refname | grep -A1 -x -- "$1" | tail -1
}

# 本地二开 commit 列表
local_commits() {
  git log --oneline --grep '^local:' "$@"
}

# 相对上游分叉点，我改了哪些文件
diverged_files() {
  local base
  base="$(git merge-base "$MAIN_BRANCH" "$UPSTREAM/$MAIN_BRANCH" 2>/dev/null || echo '')"
  [ -n "$base" ] || return 0
  git diff --stat "$base..$MAIN_BRANCH" -- . ':(exclude)local' 2>/dev/null || true
}

cmd_status() {
  need_repo
  hdr "仓库拓扑"
  git remote -v | sed 's/^/  /'

  hdr "与上游的关系（未 fetch，用本地已知的上游状态）"
  local counts ahead behind
  counts="$(git rev-list --left-right --count "$MAIN_BRANCH...$UPSTREAM/$MAIN_BRANCH" 2>/dev/null || echo '? ?')"
  ahead="$(echo "$counts"  | awk '{print $1}')"
  behind="$(echo "$counts" | awk '{print $2}')"
  echo "  你的二开 commit 数：$ahead"
  echo "  落后上游 commit 数：$behind"
  echo "  本地 HEAD：$(git rev-parse --short HEAD)  上游 HEAD：$(git rev-parse --short "$UPSTREAM/$MAIN_BRANCH" 2>/dev/null || echo '?')"

  hdr "你的二开 commit（local: 前缀）"
  local lc
  lc="$(local_commits "$MAIN_BRANCH" --not "$UPSTREAM/$MAIN_BRANCH" 2>/dev/null || true)"
  if [ -n "$lc" ]; then echo "$lc" | sed 's/^/  /'; else echo "  （无）"; fi

  hdr "偏离上游的文件（不含 local/）"
  local df
  df="$(diverged_files)"
  if [ -n "$df" ]; then echo "$df" | sed 's/^/  /'; else echo "  （无，与上游一致）"; fi

  hdr "工作区状态"
  git status --short | sed 's/^/  /' || true
  [ -z "$(git status --porcelain)" ] && echo "  （干净）"

  hdr "最新上游版本 tag"
  git for-each-ref --sort=-creatordate \
    --format='  %(creatordate:short)  %(refname:short)' refs/tags | head -5
}

cmd_check() {
  need_repo
  fetch_upstream

  local local_head up_head
  local_head="$(git rev-parse "$MAIN_BRANCH")"
  up_head="$(git rev-parse "$UPSTREAM/$MAIN_BRANCH")"

  hdr "上游新增 commit"
  if [ "$local_head" = "$up_head" ]; then
    c_grn "  已是最新，无需同步"
  else
    git log --oneline "$local_head..$up_head" | sed 's/^/  /'
  fi

  hdr "最新 tag"
  local lt
  lt="$(latest_tag)"
  echo "  $lt（$(git log -1 --format=%cs "$lt" 2>/dev/null || echo '?')）"

  # 侦察最近一个版本改了什么
  local prev
  prev="$(prev_tag "$lt")"
  if [ -n "$prev" ] && [ "$prev" != "$lt" ]; then
    hdr "从 $prev 到 $lt 上游改了什么（风险面）"
    git diff --stat "$prev..$lt" -- . ':(exclude)local' | tail -30 | sed 's/^/  /'
  fi

  # 冲突预测：把上游最新 tag merge 到当前 HEAD 做一次「试合并」
  hdr "冲突预测（试合并 $lt，不留痕迹）"
  if [ -n "$(git status --porcelain)" ]; then
    c_yel "  工作区不干净，先 commit 或 stash 再预测"
  else
    local cur
    cur="$(git rev-parse --abbrev-ref HEAD)"
    if git merge-tree "$(git merge-base HEAD "$lt")" HEAD "$lt" >/dev/null 2>&1; then
      # git >= 2.38 的 merge-tree 会输出冲突信息
      local probe
      probe="$(git merge-tree --write-tree HEAD "$lt" 2>&1 || true)"
      if echo "$probe" | grep -q 'CONFLICT'; then
        c_red "  预测会冲突："
        echo "$probe" | grep 'CONFLICT' | sed 's/^/    /'
      else
        c_grn "  预测可干净合并 ✓"
      fi
    else
      c_yel "  merge-tree 探测不可用，跳过（直接跑 sync 也会告诉你）"
    fi
  fi

  hdr "建议"
  echo "  同步：./local/sync-upstream.sh sync $lt"
}

cmd_sync() {
  need_repo
  local target="${1:-}"
  fetch_upstream

  if [ -z "$target" ]; then
    target="$(latest_tag)"
    [ -n "$target" ] || die "找不到任何 tag"
  fi
  git rev-parse "$target" >/dev/null 2>&1 || die "tag '$target' 不存在"

  local cur
  cur="$(git rev-parse --abbrev-ref HEAD)"
  [ "$cur" = "$MAIN_BRANCH" ] || c_yel "注意：当前在 '$cur'，不是 '$MAIN_BRANCH'"

  if [ -n "$(git status --porcelain)" ]; then
    die "工作区不干净。先 commit 或 git stash，再同步。"
  fi

  if git merge-base --is-ancestor "$target" HEAD 2>/dev/null; then
    c_grn "已包含 $target，无需同步。"
    return 0
  fi

  local branch="sync/$target"
  hdr "同步 $target 到分支 $branch"
  git branch -D "$branch" >/dev/null 2>&1 || true
  git checkout -b "$branch" "$MAIN_BRANCH"

  c_cyn "→ merge $target ..."
  if git merge --no-ff --no-edit "$target"; then
    c_grn "干净合并，无冲突 ✓"
  else
    c_red "有冲突，需要手工解决："
    echo
    git diff --name-only --diff-filter=U | sed 's/^/    /'
    echo
    c_yel "冲突块已用 zdiff3 格式标注（含共同祖先，好解）。"
    echo
    echo "  解冲突三类对策："
    echo "    1. 结构性冲突（两边改同一行）→ 手工合并，保留【语义】而非文本"
    echo "    2. 功能性重复（上游已实现你要的功能）→ 删掉自己那份，用上游的（最优解）"
    echo "    3. 接口漂移（上游改了内部签名）→ 编译会全告诉你，跟着改"
    echo
    echo "  逐文件看：git diff -- <文件>"
    echo "  标记已解决：git add <文件>"
    echo "  全部解决后：git merge --continue"
    echo "  然后跑：./local/sync-upstream.sh verify"
    echo
    c_yel "搞砸了随时：./local/sync-upstream.sh abort"
    exit 1
  fi

  finish_sync "$branch" "$target"
}

cmd_verify() {
  need_repo
  hdr "构建与测试"
  if ! command -v go >/dev/null 2>&1; then
    c_red "未找到 go。go.mod 要求 Go 1.22.5。"
    echo "  安装：brew install go   或   https://go.dev/dl/"
    echo "  未验证的合并不要推到 main。"
    exit 1
  fi
  echo "  Go: $(go version)"
  c_cyn "→ go build ./..."
  go build ./... || die "编译失败"
  c_grn "  构建通过 ✓"
  c_cyn "→ go vet ./..."
  go vet ./... || c_yel "  vet 有告警（未必阻塞）"
  c_cyn "→ go test ./..."
  go test ./... || die "测试失败 —— 别推到 main"
  c_grn "全部通过 ✓"
}

finish_sync() {
  local branch="$1" target="$2"
  hdr "合并 $branch 到 $MAIN_BRANCH"
  git checkout "$MAIN_BRANCH"
  git merge --no-ff --no-edit \
    -m "chore(sync): 同步上游 $target" "$branch" \
    || die "合并到 main 失败"
  c_grn "已合并到 $MAIN_BRANCH（同步分支 $branch 保留，便于回溯）"

  hdr "下一步"
  echo "  1. 验证：./local/sync-upstream.sh verify"
  echo "  2. 在 local/LOCAL_CHANGES.md 的「同步日志」追加一行"
  echo "  3. 推送：git push $ORIGIN $MAIN_BRANCH"
}

cmd_abort() {
  need_repo
  hdr "回退同步"

  if [ -d "$(git rev-parse --git-dir)/rebase-merge" ] \
     || [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]; then
    c_yel "→ 中止进行中的 merge"
    git merge --abort 2>/dev/null || true
  fi

  local cur
  cur="$(git rev-parse --abbrev-ref HEAD)"
  if [ "$cur" != "$MAIN_BRANCH" ]; then
    c_yel "→ 切回 $MAIN_BRANCH（当前在 $cur）"
    git checkout --force "$MAIN_BRANCH"
  fi

  echo "  现在 HEAD: $(git rev-parse --short HEAD)  分支: $MAIN_BRANCH"
  echo "  残留的 sync/* 分支："
  git branch --list 'sync/*' | sed 's/^/    /' || true
  c_yel "  如需丢弃某个同步分支：git branch -D sync/<tag>"
  c_grn "已回到同步前状态（未推送的话，origin 也没被动过）"
}

cmd_tags() {
  need_repo
  git for-each-ref --sort=-creatordate \
    --format='%(creatordate:short)  %(refname:short)  %(objectname:short)' refs/tags | head -20
}

cmd_conflicts() {
  need_repo
  hdr "当前冲突文件"
  local f
  f="$(git diff --name-only --diff-filter=U)"
  if [ -n "$f" ]; then
    echo "$f" | sed 's/^/  /'
    echo
    echo "冲突标记速查："
    echo "  <<<<<<< HEAD        你这边（改动前的本地版本 / 合并时的当前分支）"
    echo "  ||||||| base        共同祖先（zdiff3 才有）"
    echo "  ======="
    echo "  >>>>>>> <tag>       上游那边"
  else
    c_grn "  没有未解决的冲突"
  fi
}

cmd_bootstrap() {
  git rev-parse --git-dir >/dev/null 2>&1 || die "当前目录不是 git 仓库。先 clone 你的 fork。"
  hdr "配置 upstream remote"
  if git remote get-url "$UPSTREAM" >/dev/null 2>&1; then
    c_grn "  upstream 已存在：$(git remote get-url "$UPSTREAM")"
  else
    git remote add "$UPSTREAM" https://github.com/linguo2625469/workbuddy2api-panel.git
    c_grn "  已添加 upstream"
  fi
  # 防止手滑把二开推到上游
  git remote set-url --push "$UPSTREAM" no_push
  c_grn "  已禁用 upstream 的 push（no_push）"

  hdr "git 配置"
  ensure_git_config
  echo "  rerere.enabled     = $(git config --local --get rerere.enabled)"
  echo "  rerere.autoupdate  = $(git config --local --get rerere.autoupdate)"
  echo "  merge.conflictstyle= $(git config --local --get merge.conflictstyle)"
  c_grn "  完成（rerere = 解过的冲突下次自动套用；zdiff3 = 冲突块带共同祖先）"

  hdr "拉取上游 tag"
  fetch_upstream
  echo "  最新 tag：$(latest_tag)"
  c_grn "bootstrap 完成。接着跑：./local/sync-upstream.sh status"
}

case "${1:-status}" in
  status)     cmd_status ;;
  check)      cmd_check ;;
  sync)       shift; cmd_sync "${1:-}" ;;
  verify)     cmd_verify ;;
  abort)      cmd_abort ;;
  tags)       cmd_tags ;;
  conflicts)  cmd_conflicts ;;
  bootstrap)  cmd_bootstrap ;;
  -h|--help|help)
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "未知命令 '$1'。可用：status | check | sync [tag] | verify | abort | conflicts | tags | bootstrap" ;;
esac
