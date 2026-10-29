#!/bin/bash
# 在 Linux 开发机上用：把源码同步到测试 Mac 并编译。
# 登录信息读项目根目录的 .testmac.env（MAC_HOST、MAC_PASSWORD，已被 git 忽略）。
# 用法：scripts/remote-build.sh [--install]   参数原样传给测试机上的 scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f .testmac.env ]]; then
    echo "缺少 .testmac.env（MAC_HOST=user@host、MAC_PASSWORD=...）" >&2
    exit 1
fi
set -a
. ./.testmac.env
set +a
export SSHPASS="$MAC_PASSWORD"
REMOTE_DIR=${MAC_DIR:-screenboard}
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

echo "==> 同步到 $MAC_HOST:$REMOTE_DIR"
rsync -az --delete -e "sshpass -e ssh ${SSH_OPTS[*]}" \
    --exclude .git --exclude build --exclude .testmac.env \
    ./ "$MAC_HOST:$REMOTE_DIR/"

echo "==> 在测试机上编译"
sshpass -e ssh "${SSH_OPTS[@]}" "$MAC_HOST" "cd $REMOTE_DIR && scripts/build-app.sh $*"
