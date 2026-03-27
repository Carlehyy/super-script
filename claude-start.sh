#!/usr/bin/env bash
#
# claude-start.sh
# Claude Code 启动器 + Git Worktree 管理工具
#
# 功能：
#   - 环境检查（Claude 安装、用户权限、Git 仓库）
#   - 分支路由（main / worktree 自动识别）
#   - Worktree 创建、切换、删除
#
# 用法：
#   将脚本放到任意位置，cd 到项目目录后执行：
#   bash claude-start.sh
#
#   或赋予执行权限后直接运行：
#   chmod +x claude-start.sh
#   ./claude-start.sh
#

set -euo pipefail

# ============================================================
# 颜色与样式
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # 重置

# ============================================================
# 工具函数
# ============================================================
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

separator() {
    echo -e "${DIM}──────────────────────────────────────────────${NC}"
}

# 启动 Claude Code 前的确认信息，然后启动
launch_claude() {
    local branch="$1"
    local dir="$2"

    echo ""
    separator
    echo -e "  ${GREEN}${BOLD}即将启动 Claude Code${NC}"
    echo -e "  ${CYAN}分支：${NC}${BOLD}$branch${NC}"
    echo -e "  ${CYAN}目录：${NC}$dir"
    separator
    echo ""

    cd "$dir"
    exec claude --dangerously-skip-permissions
}

# ============================================================
# 步骤 1：检查 Claude 是否已安装
# ============================================================
check_claude_installed() {
    if ! command -v claude &> /dev/null; then
        error "未检测到 claude 命令。"
        echo ""
        echo -e "  请先安装 Claude Code，参考以下文档："
        echo -e "  ${CYAN}https://claude-zh.cn/guide/getting-started${NC}"
        echo ""
        exit 1
    fi
    success "Claude Code 已安装（$(command -v claude)）"
}

# ============================================================
# 步骤 2：检查当前用户是否为 root
# ============================================================
check_not_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        error "当前用户为 root，无法使用 --dangerously-skip-permissions 参数。"
        echo ""
        echo -e "  请切换到非 root 用户后再运行此脚本。"
        echo ""

        # 列出系统中可登录的非 root 用户
        local users
        users=$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)/ {print $1}' /etc/passwd)

        if [[ -n "$users" ]]; then
            echo -e "  ${CYAN}当前系统可用的非 root 用户：${NC}"
            echo ""
            while IFS= read -r u; do
                echo -e "    - ${BOLD}$u${NC}"
            done <<< "$users"
            echo ""
            echo -e "  切换示例："
            local first_user
            first_user=$(echo "$users" | head -1)
            echo -e "    ${YELLOW}su $first_user${NC}"
            echo ""
        else
            echo -e "  ${YELLOW}未找到可用的非 root 用户，请先创建一个普通用户。${NC}"
            echo ""
        fi

        exit 1
    fi
    success "当前用户：$(whoami)"
}

# ============================================================
# 步骤 3：检查当前目录是否为 Git 仓库
# ============================================================
check_git_repo() {
    if ! git rev-parse --is-inside-work-tree &> /dev/null 2>&1; then
        warn "当前目录不是 Git 仓库，将直接启动 Claude Code。"
        launch_claude "无（非 Git 仓库）" "$(pwd)"
    fi
    success "Git 仓库已检测到"
}

# ============================================================
# 步骤 4：分支检测与路由
# ============================================================

# 获取项目基本信息
get_project_info() {
    # 当前分支名
    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")

    # 判断当前目录是否为 worktree（非主仓库）
    # git worktree 的 .git 是一个文件而不是目录
    if [[ -f "$(git rev-parse --git-dir 2>/dev/null)/../.git" ]] || \
       [[ "$(git rev-parse --git-dir 2>/dev/null)" == *".git/worktrees/"* ]]; then
        IS_WORKTREE=true
    else
        IS_WORKTREE=false
    fi

    # 主仓库的绝对路径
    MAIN_WORKTREE_DIR=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')

    # 项目文件夹名（从主仓库路径提取）
    PROJECT_NAME=$(basename "$MAIN_WORKTREE_DIR")

    # 主仓库的父目录（worktree 都创建在这个层级）
    PARENT_DIR=$(dirname "$MAIN_WORKTREE_DIR")
}

# 获取已有 worktree 列表（排除主仓库）
get_worktree_list() {
    WORKTREE_LIST=()
    WORKTREE_BRANCHES=()
    WORKTREE_DIRS=()

    while IFS= read -r line; do
        local wt_dir wt_branch
        wt_dir=$(echo "$line" | awk '{print $1}')
        wt_branch=$(echo "$line" | sed -n 's/.*\[\(.*\)\].*/\1/p')

        # 跳过主仓库自身
        if [[ "$wt_dir" == "$MAIN_WORKTREE_DIR" ]]; then
            continue
        fi

        # 跳过 detached HEAD 的 worktree
        if [[ -z "$wt_branch" ]]; then
            continue
        fi

        WORKTREE_LIST+=("$wt_dir|$wt_branch")
        WORKTREE_BRANCHES+=("$wt_branch")
        WORKTREE_DIRS+=("$wt_dir")
    done < <(git worktree list)
}

# 校验分支名格式
validate_branch_name() {
    local name="$1"

    # 不能为空
    if [[ -z "$name" ]]; then
        error "分支名不能为空。"
        return 1
    fi

    # 不能包含空格
    if [[ "$name" =~ \  ]]; then
        error "分支名不能包含空格：'$name'"
        return 1
    fi

    # 不能包含特殊字符（仅允许字母、数字、-、_、/）
    if [[ ! "$name" =~ ^[a-zA-Z0-9/_-]+$ ]]; then
        error "分支名仅允许使用字母、数字、-、_、/ 字符：'$name'"
        return 1
    fi

    # 不能以 - 开头
    if [[ "$name" == -* ]]; then
        error "分支名不能以 - 开头：'$name'"
        return 1
    fi

    # 不能与已有的本地分支重名
    if git show-ref --verify --quiet "refs/heads/$name" 2>/dev/null; then
        error "分支 '$name' 已存在，请使用其他名称。"
        return 1
    fi

    return 0
}

# 创建新的 worktree
create_new_worktree() {
    echo ""
    echo -e "${CYAN}请输入新分支的名称${NC}（例如：feat/smart-picker, dev, test）："
    echo -e "${DIM}仅允许字母、数字、-、_、/ 字符，不能有空格${NC}"
    echo ""
    read -rp "> " new_branch

    # 校验分支名
    if ! validate_branch_name "$new_branch"; then
        echo ""
        warn "请重新运行脚本并输入有效的分支名。"
        exit 1
    fi

    # 构建 worktree 目录名：将分支名中的 / 替换为 -
    local safe_branch_name
    safe_branch_name=$(echo "$new_branch" | tr '/' '-')
    local worktree_dir="${PARENT_DIR}/${PROJECT_NAME}-${safe_branch_name}"

    # 检查目录是否已存在
    if [[ -d "$worktree_dir" ]]; then
        error "目录已存在：$worktree_dir"
        echo "  请选择其他分支名，或手动删除该目录后重试。"
        exit 1
    fi

    info "正在创建 worktree..."
    echo -e "  分支：${BOLD}$new_branch${NC}"
    echo -e "  目录：$worktree_dir"
    echo ""

    if ! git worktree add -b "$new_branch" "$worktree_dir" HEAD 2>&1; then
        error "Worktree 创建失败，请检查上方错误信息。"
        exit 1
    fi

    success "Worktree 创建成功！"

    launch_claude "$new_branch" "$worktree_dir"
}

# 选择已有 worktree 并启动
select_existing_worktree() {
    local count=${#WORKTREE_BRANCHES[@]}

    echo ""
    echo -e "${CYAN}可用的 Worktree 分支：${NC}"
    echo ""

    for i in "${!WORKTREE_BRANCHES[@]}"; do
        local idx=$((i + 1))
        echo -e "  ${BOLD}[$idx]${NC} ${WORKTREE_BRANCHES[$i]}"
        echo -e "      ${DIM}${WORKTREE_DIRS[$i]}${NC}"
    done

    echo ""
    read -rp "请选择 [1-$count]（输入 0 返回主菜单）: " choice

    # 返回主菜单
    if [[ "$choice" == "0" ]]; then
        show_main_menu
        return
    fi

    # 校验输入
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt $count ]]; then
        error "无效的选择：$choice"
        exit 1
    fi

    local selected_idx=$((choice - 1))
    local selected_branch="${WORKTREE_BRANCHES[$selected_idx]}"
    local selected_dir="${WORKTREE_DIRS[$selected_idx]}"

    # 检查目录是否存在
    if [[ ! -d "$selected_dir" ]]; then
        error "Worktree 目录不存在：$selected_dir"
        echo "  该 worktree 可能已被手动删除。请运行 git worktree prune 清理。"
        exit 1
    fi

    launch_claude "$selected_branch" "$selected_dir"
}

# 删除已有 worktree
delete_existing_worktree() {
    # 只允许在 main 分支上执行删除
    if [[ "$IS_WORKTREE" == true ]]; then
        error "只能在主仓库（main 分支）目录下删除 worktree。"
        echo "  请先 cd 到 ${MAIN_WORKTREE_DIR} 后再运行脚本。"
        exit 1
    fi

    local count=${#WORKTREE_BRANCHES[@]}

    if [[ $count -eq 0 ]]; then
        warn "当前没有任何 worktree 分支可删除。"
        echo ""
        read -rp "按 Enter 返回主菜单..." _
        show_main_menu
        return
    fi

    echo ""
    echo -e "${CYAN}选择要删除的 Worktree 分支：${NC}"
    echo -e "${DIM}（仅允许每次删除一个）${NC}"
    echo ""

    for i in "${!WORKTREE_BRANCHES[@]}"; do
        local idx=$((i + 1))
        echo -e "  ${BOLD}[$idx]${NC} ${WORKTREE_BRANCHES[$i]}"
        echo -e "      ${DIM}${WORKTREE_DIRS[$i]}${NC}"
    done

    echo ""
    read -rp "请选择 [1-$count]（输入 0 返回主菜单）: " choice

    # 返回主菜单
    if [[ "$choice" == "0" ]]; then
        show_main_menu
        return
    fi

    # 校验输入
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt $count ]]; then
        error "无效的选择：$choice"
        exit 1
    fi

    local selected_idx=$((choice - 1))
    local selected_branch="${WORKTREE_BRANCHES[$selected_idx]}"
    local selected_dir="${WORKTREE_DIRS[$selected_idx]}"

    echo ""
    echo -e "${YELLOW}${BOLD}确认删除以下 Worktree？${NC}"
    echo -e "  分支：${BOLD}$selected_branch${NC}"
    echo -e "  目录：$selected_dir"
    echo ""
    echo -e "  ${RED}此操作将删除该目录下所有未提交的修改！${NC}"
    echo ""
    read -rp "输入 yes 确认删除: " confirm

    if [[ "$confirm" != "yes" ]]; then
        info "已取消删除。"
        echo ""
        read -rp "按 Enter 返回主菜单..." _
        show_main_menu
        return
    fi

    # 执行删除
    echo ""
    info "正在删除 worktree..."

    # 先尝试正常删除
    if ! git worktree remove "$selected_dir" 2>&1; then
        echo ""
        warn "正常删除失败，尝试强制删除..."

        if ! git worktree remove --force "$selected_dir" 2>&1; then
            echo ""
            error "强制删除也失败了。请手动处理："
            echo "  1. rm -rf $selected_dir"
            echo "  2. git worktree prune"
            exit 1
        fi
    fi

    # 删除对应的本地分支（如果存在）
    if git show-ref --verify --quiet "refs/heads/$selected_branch" 2>/dev/null; then
        echo ""
        read -rp "是否同时删除本地分支 '$selected_branch'？[y/N]: " del_branch
        if [[ "$del_branch" =~ ^[yY]$ ]]; then
            if ! git branch -D "$selected_branch" 2>&1; then
                warn "分支删除失败，可能需要手动处理。"
            else
                success "本地分支 '$selected_branch' 已删除。"
            fi
        fi
    fi

    echo ""
    success "Worktree 已删除：$selected_dir"
    echo ""
    read -rp "按 Enter 返回主菜单..." _
    show_main_menu
}

# 主菜单（仅在 main 分支显示）
show_main_menu() {
    # 刷新 worktree 列表
    get_worktree_list

    local has_worktrees=false
    if [[ ${#WORKTREE_BRANCHES[@]} -gt 0 ]]; then
        has_worktrees=true
    fi

    echo ""
    separator
    echo -e "  ${BOLD}Claude Code 启动器${NC}"
    echo -e "  ${DIM}项目：${PROJECT_NAME} | 分支：${CURRENT_BRANCH}${NC}"
    separator
    echo ""

    echo -e "  ${BOLD}[1]${NC} 在 ${BOLD}${CURRENT_BRANCH}${NC} 分支上启动 Claude"

    if [[ "$has_worktrees" == true ]]; then
        echo -e "  ${BOLD}[2]${NC} 切换到已有的 Worktree 分支"
    fi

    echo -e "  ${BOLD}[3]${NC} 创建新的 Worktree 分支"

    if [[ "$has_worktrees" == true ]]; then
        echo -e "  ${BOLD}[4]${NC} 删除已有的 Worktree 分支"
    fi

    echo -e "  ${BOLD}[0]${NC} 退出"
    echo ""

    read -rp "请选择: " menu_choice

    case "$menu_choice" in
        1)
            launch_claude "$CURRENT_BRANCH" "$(pwd)"
            ;;
        2)
            if [[ "$has_worktrees" == true ]]; then
                select_existing_worktree
            else
                error "无效的选择。"
                show_main_menu
            fi
            ;;
        3)
            create_new_worktree
            ;;
        4)
            if [[ "$has_worktrees" == true ]]; then
                delete_existing_worktree
            else
                error "无效的选择。"
                show_main_menu
            fi
            ;;
        0)
            info "已退出。"
            exit 0
            ;;
        *)
            error "无效的选择：$menu_choice"
            show_main_menu
            ;;
    esac
}

# ============================================================
# 主流程
# ============================================================
main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     Claude Code 启动器 v1.0         ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo ""

    # 步骤 1：检查 Claude 安装
    check_claude_installed

    # 步骤 2：检查用户权限
    check_not_root

    # 步骤 3：检查 Git 仓库（非 Git 仓库会直接启动 Claude 并退出）
    check_git_repo

    # 步骤 4：获取项目信息
    get_project_info

    info "项目：$PROJECT_NAME | 当前分支：$CURRENT_BRANCH"

    # 步骤 5：分支路由
    if [[ "$IS_WORKTREE" == true ]]; then
        # 已经在 worktree 分支上，直接启动
        success "当前处于 Worktree 分支，直接启动 Claude。"
        launch_claude "$CURRENT_BRANCH" "$(pwd)"
    else
        # 在主仓库（main 分支），显示菜单
        show_main_menu
    fi
}

# 执行主流程
main
