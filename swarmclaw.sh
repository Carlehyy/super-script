#!/usr/bin/env bash
# =============================================================================
# swarmclaw.sh - SwarmClaw Docker 部署 + 每日增量备份脚本
# 环境: Ubuntu 24 + Docker (含 compose v2 插件) + tmux + rsync + git
#
# 三个关键设计决策:
#
# 1) 备份哪些数据?
#    - data/ 整个目录 (四个 SQLite 库 + plugins/ + uploads/ 等)
#      · swarmclaw.db              : 主库 (会话/智能体/任务/用量)
#      · memory.db                 : 记忆库 (FTS5 + 向量嵌入)
#      · logs.db                   : 执行审计
#      · langgraph-checkpoints.db  : 编排器检查点
#    - .env.local  (必不可少!)
#      里面的 CREDENTIAL_SECRET 是 AES-256 密钥, 负责解密 DB 里的 API keys、
#      钱包私钥等加密字段; 丢了等于 DB 里的机密全部报废。
#
# 2) 备份时要不要关 Docker?
#    要。SQLite 跑在 WAL 模式下, 运行时 .db / .db-wal / .db-shm 三个文件
#    处于不断变化状态, 活着 rsync 极易得到不一致快照, 尤其是四个库之间
#    无法保证同一时间点。最稳妥做法: stop -> rsync -> start
#    (凌晨 4 点停机 10~30 秒影响可忽略)
#
# 3) 全量还是增量?
#    用 rsync -a --delete 做 "增量传输 + 镜像同步":
#    - 只传变化的文件 (增量, 省 I/O)
#    - 目的目录永远等于源端最新状态 (--delete 清理源端已删除的文件)
#    - 想保留历史版本? 把 do_backup() 里 rsync 行改成 --link-dest 快照模式
#      (注释里给了示例)
#
# 用法:
#   chmod +x swarmclaw.sh
#   ./swarmclaw.sh start             # 首次部署: 克隆仓库 + tmux 启动 + 装 cron
#   ./swarmclaw.sh backup            # 手动触发一次备份 (调试用)
#   ./swarmclaw.sh status            # 查看容器 + tmux 状态
#   ./swarmclaw.sh stop              # 停止容器并杀掉 tmux 会话
#   ./swarmclaw.sh uninstall-cron    # 移除 cron 任务
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 配置 (按需修改, 也可以通过环境变量覆盖)
# -----------------------------------------------------------------------------
SWARMCLAW_DIR="${SWARMCLAW_DIR:-$HOME/swarmclaw}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backup/swarmclaw}"
TMUX_SESSION="${TMUX_SESSION:-swarmclaw}"
REPO_URL="https://github.com/swarmclawai/swarmclaw.git"

LOG_DIR="$HOME/.swarmclaw-ops"
LOG_FILE="$LOG_DIR/swarmclaw.log"
CRON_TAG="# swarmclaw-backup"   # 用于幂等地查找/替换 cron 条目

mkdir -p "$LOG_DIR" "$BACKUP_DIR"

# -----------------------------------------------------------------------------
# 工具函数
# -----------------------------------------------------------------------------
log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "错误: 找不到命令 '$1'" >&2; exit 1; }
}

ensure_deps() {
    require_cmd docker
    require_cmd tmux
    require_cmd rsync
    require_cmd git
    docker compose version >/dev/null 2>&1 \
        || { echo "错误: 未检测到 'docker compose' (v2 插件)" >&2; exit 1; }
    # 如果当前用户不在 docker 组里, docker ps 会 permission denied
    docker ps >/dev/null 2>&1 \
        || { echo "错误: 无权运行 docker。请执行: sudo usermod -aG docker \$USER 后重新登录" >&2; exit 1; }
}

ensure_repo() {
    if [ ! -d "$SWARMCLAW_DIR/.git" ]; then
        log "克隆 SwarmClaw 到 $SWARMCLAW_DIR ..."
        git clone "$REPO_URL" "$SWARMCLAW_DIR"
    else
        log "仓库已存在: $SWARMCLAW_DIR"
    fi
    cd "$SWARMCLAW_DIR"
    # README 要求启动前先准备好 data 目录与 .env.local
    mkdir -p data
    [ -f .env.local ] || touch .env.local
}

# 给 backup trap 用: 保证无论 rsync 成功与否都把容器拉回来
_restart_containers() {
    log "恢复 SwarmClaw 容器 ..."
    (cd "$SWARMCLAW_DIR" && docker compose start) >>"$LOG_FILE" 2>&1 \
        || log "警告: docker compose start 失败, 请手动检查!"
}

# -----------------------------------------------------------------------------
# start: 在 tmux 里起 docker compose, 并装好每日 cron
# -----------------------------------------------------------------------------
start_in_tmux() {
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        log "tmux 会话 '$TMUX_SESSION' 已存在, 跳过创建 (如需重建请先 stop)"
    else
        log "创建 tmux 会话 '$TMUX_SESSION' 并启动 SwarmClaw ..."
        tmux new-session -d -s "$TMUX_SESSION" -c "$SWARMCLAW_DIR"
        # 先 build+up -d, 再 tail 日志 - attach 上来就能看到实时日志
        tmux send-keys -t "$TMUX_SESSION" \
            "docker compose up -d --build && docker compose logs -f" Enter
    fi

    log "等待容器就绪 ..."
    sleep 8
    (cd "$SWARMCLAW_DIR" && docker compose ps) | tee -a "$LOG_FILE"
    log "启动完成 → http://localhost:3456"
    log "查看日志: tmux attach -t $TMUX_SESSION   (分离快捷键: Ctrl+B 然后 D)"
}

# -----------------------------------------------------------------------------
# backup: 停容器 -> rsync -> 起容器
# -----------------------------------------------------------------------------
do_backup() {
    log "================ 开始每日备份 ================"
    cd "$SWARMCLAW_DIR"

    log "停止容器以保证 SQLite WAL 一致性 ..."
    docker compose stop >>"$LOG_FILE" 2>&1

    # 无论下面成功失败, 脚本退出时都要把容器拉回来
    trap _restart_containers EXIT

    log "rsync: $SWARMCLAW_DIR/data/  →  $BACKUP_DIR/data/   (增量 + 镜像)"
    rsync -a --delete --human-readable --stats \
        "$SWARMCLAW_DIR/data/" "$BACKUP_DIR/data/" >>"$LOG_FILE" 2>&1

    # 想要 "每天一份带日期的历史快照 (硬链接, 近零额外空间)", 把上面那行换成:
    #
    #   SNAPSHOT="$BACKUP_DIR/snapshots/$(date +%F)"
    #   mkdir -p "$BACKUP_DIR/snapshots"
    #   rsync -a --delete --link-dest="$BACKUP_DIR/data" \
    #       "$SWARMCLAW_DIR/data/" "$SNAPSHOT/"
    #   rsync -a --delete "$SWARMCLAW_DIR/data/" "$BACKUP_DIR/data/"

    if [ -f "$SWARMCLAW_DIR/.env.local" ]; then
        log "rsync: .env.local  (含 CREDENTIAL_SECRET, 不备份就解不开 DB)"
        rsync -a "$SWARMCLAW_DIR/.env.local" "$BACKUP_DIR/.env.local" >>"$LOG_FILE" 2>&1
        chmod 600 "$BACKUP_DIR/.env.local" 2>/dev/null || true
    fi

    log "备份目录大小: $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)"
    log "================ 备份完成 ================"
    # trap 在脚本退出时自动拉起容器
}

# -----------------------------------------------------------------------------
# cron: 每天 04:00 跑一次 "$0 backup"
# -----------------------------------------------------------------------------
install_cron() {
    local self cron_line tmp
    self="$(realpath "$0")"
    cron_line="0 4 * * * /usr/bin/env bash $self backup >> $LOG_FILE 2>&1 $CRON_TAG"

    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -v "$CRON_TAG" > "$tmp" || true
    echo "$cron_line" >> "$tmp"
    crontab "$tmp"
    rm -f "$tmp"

    log "已安装 cron 任务 (每天 04:00):"
    crontab -l | grep "$CRON_TAG" | tee -a "$LOG_FILE"
}

uninstall_cron() {
    (crontab -l 2>/dev/null | grep -v "$CRON_TAG") | crontab - || crontab -r 2>/dev/null || true
    log "已移除 swarmclaw 备份 cron 任务"
}

# -----------------------------------------------------------------------------
# 其他命令
# -----------------------------------------------------------------------------
stop_all() {
    if [ -d "$SWARMCLAW_DIR" ]; then
        (cd "$SWARMCLAW_DIR" && docker compose down) || true
    fi
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    log "已停止容器并关闭 tmux 会话"
}

show_status() {
    echo "--- Docker ---"
    (cd "$SWARMCLAW_DIR" 2>/dev/null && docker compose ps) || echo "(仓库不存在)"
    echo "--- tmux ---"
    tmux ls 2>/dev/null | grep "$TMUX_SESSION" || echo "(无 swarmclaw tmux 会话)"
    echo "--- cron ---"
    crontab -l 2>/dev/null | grep "$CRON_TAG" || echo "(未安装 cron)"
    echo "--- backup ---"
    [ -d "$BACKUP_DIR" ] && du -sh "$BACKUP_DIR" || echo "(无备份目录)"
}

usage() {
    sed -n '/^# 用法:/,/^# ==========/p' "$0" | sed 's/^# \{0,1\}//;$d'
}

# -----------------------------------------------------------------------------
# 入口
# -----------------------------------------------------------------------------
main() {
    ensure_deps
    case "${1:-}" in
        start)           ensure_repo; start_in_tmux; install_cron ;;
        backup)          [ -d "$SWARMCLAW_DIR" ] || { log "错误: 请先运行 '$0 start'"; exit 1; }
                         do_backup ;;
        stop)            stop_all ;;
        status)          show_status ;;
        uninstall-cron)  uninstall_cron ;;
        ""|-h|--help)    usage ;;
        *)               usage; exit 1 ;;
    esac
}

main "$@"
