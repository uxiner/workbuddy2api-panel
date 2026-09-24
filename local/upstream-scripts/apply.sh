#!/usr/bin/env bash
# local/upstream-scripts/apply.sh — 把原版脚本 + 补丁部署到群晖
#
# 用途：workbuddy-manager 的「一键做任务」依赖原版镜像专有脚本（已删库，
#       本目录是唯一副本）。本脚本把它们（含 bug 修复补丁）部署到群晖的正确位置。
#
# 为什么部署到「宿主机 scripts/」而不是「data/upstream-scripts/」：
#   manager 的 taskrun._script_path() 有**两级查找，宿主机优先**：
#       ① UPSTREAM_DIR/scripts/task_runner.py   ← 优先，且是 bind mount，不受镜像重建影响
#       ② DATA_DIR/upstream-scripts/            ← 从镜像 docker cp 提取的回落
#   放 ① 后，替换/重建 workbuddy2api 镜像都不会影响补丁（见 FIX-task_runner-crash.md §7）。
#
# 用法：
#   ./apply.sh              # 部署到群晖（需 NAS 可达）
#   ./apply.sh --local      # 只在本机校验补丁能干净应用到原版
#   ./apply.sh --verify     # 只检查群晖上当前状态，不做修改

set -euo pipefail

NAS_HOST="${NAS_HOST:-192.168.50.199}"
NAS_USER="${NAS_USER:-temp-admin}"
NAS_PASS="${NAS_PASS:-123456abcD!!}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER=/var/packages/ContainerManager/target/usr/bin/docker

# 部署目标（宿主机路径）
UPSTREAM_SCRIPTS=/volume1/docker/workbuddy2api/scripts
FALLBACK_DIR=/volume1/docker/workbuddy-manager/data/upstream-scripts

c_red() { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yel() { printf '\033[33m%s\033[0m\n' "$*"; }
c_cyn() { printf '\033[36m%s\033[0m\n' "$*"; }
hdr()   { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die()   { c_red "错误：$*"; exit 1; }

# ── 本地模式：校验补丁 ──────────────────────────────────
mode="${1:-deploy}"

if [ "$mode" = "--local" ]; then
  hdr "本机校验：补丁能否干净应用到原版"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  ok=1
  for f in task_common.py task_runner.py; do
    cp "$HERE/$f" "$tmp/$f"
    if (cd "$tmp" && patch -p0 --dry-run < "$HERE/patches/$f.patch" >/dev/null 2>&1); then
      c_grn "  $f: 补丁可应用 ✓"
    else
      c_red "  $f: 补丁失败 ✗"; ok=0
    fi
  done
  [ "$ok" = 1 ] || die "补丁校验失败"
  c_grn "全部通过"
  exit 0
fi

# ── SSH 通道（沙箱无 sshpass，用 SSH_ASKPASS）────────────
ASKPASS="$(mktemp)"
KNOWN="$(mktemp)"
trap 'rm -f "$ASKPASS" "$KNOWN"' EXIT
printf '#!/bin/sh\necho "%s"\n' "$NAS_PASS" > "$ASKPASS"
chmod +x "$ASKPASS"

nas() {
  SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile="$KNOWN" \
      -o PreferredAuthentications=password -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=1 -o LogLevel=ERROR \
      "$NAS_USER@$NAS_HOST" "$@" < /dev/null 2>&1
}
nasup() {
  SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile="$KNOWN" \
      -o PreferredAuthentications=password -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=1 -o LogLevel=ERROR \
      "$NAS_USER@$NAS_HOST" "$@"
}
sudo_nas() { nas "echo '$NAS_PASS' | sudo -S -p '' $*"; }

hdr "连接群晖 $NAS_HOST"
nas 'whoami' | grep -q . || die "无法连接（检查 NAS_HOST / 凭据）"
c_grn "  已连接"

# ── 仅校验模式 ─────────────────────────────────────────
if [ "$mode" = "--verify" ]; then
  hdr "群晖当前状态"
  echo "  ① 宿主机 scripts/（优先路径）:"
  sudo_nas "ls -la $UPSTREAM_SCRIPTS/ 2>/dev/null || echo '    （不存在）'" | sed 's/^/    /'
  echo "  ② 回落目录:"
  sudo_nas "sh -c 'ls -la $FALLBACK_DIR/ 2>/dev/null | grep -E "\.py$" | head -6 || true'"
  echo
  echo "  manager 实际解析到的路径:"
  sudo_nas "$DOCKER exec workbuddy-manager python3 -c \"
import sys; sys.path.insert(0,'/app')
from server.services import taskrun
print('   ', taskrun._script_path())
print('    available:', taskrun.available())
\"" | sed 's/^/  /'
  exit 0
fi

# ── 部署 ───────────────────────────────────────────────
hdr "构建补丁版脚本（原版 + patch）"
work="$(mktemp -d)"
for f in task_common.py task_runner.py school_open_day_2026.py global_region.py; do
  cp "$HERE/$f" "$work/$f"
done
for f in task_common.py task_runner.py; do
  (cd "$work" && patch -p0 --silent < "$HERE/patches/$f.patch") \
    || die "打补丁失败：$f"
  c_grn "  $f 已打补丁"
done

hdr "上传到群晖（原样传输，不用 base64）"
STAGE=/tmp/wb2api-scripts-stage
sudo_nas "rm -rf $STAGE; mkdir -p $STAGE; chmod 777 $STAGE; echo OK" >/dev/null
for f in task_common.py task_runner.py school_open_day_2026.py global_region.py; do
  cat "$work/$f" | nasup "cat > $STAGE/$f"
  c_grn "  $f 已上传"
done

hdr "部署到宿主机 scripts/（优先路径）"
sudo_nas "sh -c '
  set -e
  mkdir -p $UPSTREAM_SCRIPTS
  cp $STAGE/*.py $UPSTREAM_SCRIPTS/
  chown -R 10001:10001 $UPSTREAM_SCRIPTS
  chmod 755 $UPSTREAM_SCRIPTS/*.py
  echo DEPLOYED
'" | grep -q DEPLOYED || die "部署失败"

hdr "同步到回落目录（双保险）"
sudo_nas "sh -c '
  cp $UPSTREAM_SCRIPTS/*.py $FALLBACK_DIR/ 2>/dev/null || true
  chown 10001:10001 $FALLBACK_DIR/*.py 2>/dev/null || true
  echo OK
'" >/dev/null
c_grn "  已同步"

hdr "清理临时文件"
sudo_nas "rm -rf $STAGE; echo OK" >/dev/null
c_grn "  已清理"

hdr "验证部署"
sudo_nas "md5sum $UPSTREAM_SCRIPTS/task_common.py $UPSTREAM_SCRIPTS/task_runner.py" | sed 's/^/  /'
echo
echo "  预期（补丁版）:"
echo "    cd0365178950ea3c852ec94a29a0b7aa  task_common.py"
echo "    07a342af896308515197e49630ddec07  task_runner.py"
echo
sudo_nas "$DOCKER exec workbuddy-manager python3 -c \"
import sys; sys.path.insert(0,'/app')
from server.services import taskrun
print('  _script_path():', taskrun._script_path())
print('  available()  :', taskrun.available())
\"" | sed 's/^/  /'

echo
c_grn "完成。运行 ./apply.sh --verify 可随时复查。"
