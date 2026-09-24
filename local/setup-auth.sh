#!/usr/bin/env bash
# local/setup-auth.sh — 在工作区内配置 GitHub 推送凭据（SSH 部署密钥）
#
# 为什么需要这个：
#   拉取上游（linguo2625469/workbuddy2api-panel）是公开仓库，**无需任何授权**。
#   只有「推送你自己的 fork」需要凭据。
#   本机 ~/.ssh 与 ~/.gitconfig 受沙箱限制不可写，所以凭据落在工作区内，
#   通过仓库级 core.sshCommand 生效 —— 不改动任何全局配置。
#
# 用法：
#   ./local/setup-auth.sh          # 生成/复用密钥并打印公钥
#   ./local/setup-auth.sh test     # 测试认证是否已生效

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SSHDIR="$ROOT/local/.ssh"
KEY="$SSHDIR/github_deploy"
KNOWN="$SSHDIR/known_hosts"
HOST_ALIAS="github-workbuddy"

if [ "${1:-}" = "test" ]; then
  echo "→ 测试 SSH 认证 ..."
  out="$(ssh -o IdentitiesOnly=yes -o UserKnownHostsFile="$KNOWN" \
             -o StrictHostKeyChecking=accept-new -i "$KEY" -T git@github.com 2>&1 || true)"
  echo "$out" | head -3
  if echo "$out" | grep -q 'successfully authenticated'; then
    echo "认证成功 ✓ 现在可以 push 了"
  else
    echo "认证未生效 —— 公钥还没加到 GitHub，或加错了仓库。"
  fi
  exit 0
fi

mkdir -p "$SSHDIR"
chmod 700 "$SSHDIR"

if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -N "" \
    -C "workbuddy2api-sync@$(hostname -s)" -f "$KEY" -q
  chmod 600 "$KEY"
  echo "已生成新密钥：$KEY"
else
  echo "复用已有密钥：$KEY"
fi

# 只影响这个仓库：所有 git 操作都用这把密钥，known_hosts 也落在工作区内
git config --local core.sshCommand \
  "ssh -i $KEY -o IdentitiesOnly=yes -o UserKnownHostsFile=$KNOWN -o StrictHostKeyChecking=accept-new"

# origin 走 SSH（origin 是 https 时改成 ssh 形式）
if git remote get-url origin >/dev/null 2>&1; then
  cur="$(git remote get-url origin)"
  if [ "${cur#https://github.com/}" != "$cur" ]; then
    slug="${cur#https://github.com/}"; slug="${slug%.git}"
    git remote set-url origin "git@github.com:${slug}.git"
    echo "origin 已从 https 切换为 SSH：git@github.com:${slug}.git"
  fi
fi

echo
echo "本仓库已配置 core.sshCommand（只影响这个仓库，不动全局配置）"
echo
echo "==================== 把下面整行复制到 GitHub ===================="
cat "$KEY.pub"
echo "==============================================================="
echo
echo "注册位置（二选一，推荐第一个 —— 权限最小）："
echo "  A. 只授权这一个仓库：你的 fork → Settings → Deploy keys → Add deploy key"
echo "     标题随意（如 dsh-agent），粘贴公钥，**勾选 Allow write access**"
echo "  B. 授权整个账号的所有仓库：github.com → Settings → SSH and GPG keys → New SSH key"
echo
echo "加完跑：./local/setup-auth.sh test"
