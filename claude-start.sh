#!/usr/bin/env bash
#
# claude-start.sh
# Claude Code 启动器 + Git Worktree 管理工具
#
# 功能：
#   - 环境检查（Claude 安装、用户权限、Git 仓库）
#   - 分支路由（main / worktree 自动识别）
#   - Worktree 创建、切换、删除
#   - 键盘上下键交互式菜单选择
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

# ============================================================
# 交互式选择器（上下键选择）
# ============================================================
# 用法：
#   select_menu RESULT_VAR "标题" "选项1" "选项2" "选项3" ...
#
# 返回：
#   将用户选中的索引（从 0 开始）写入 RESULT_VAR
#   如果用户按 ESC 或 q 取消，返回值为 255
#
# 键位：
#   ↑ / k      上移
#   ↓ / j      下移
#   Enter      确认选择
#   ESC / q    取消
#
select_menu() {
    local _result_var="$1"
    local _title="$2"
    shift 2
    local _options=("$@")
    local _count=${#_options[@]}

    # 如果没有选项，直接返回
    if [[ $_count -eq 0 ]]; then
        eval "$_result_var=255"
        return 1
    fi

    # 非交互式终端 fallback 到数字输入
    if [[ ! -t 0 ]]; then
        echo -e "$_title"
        for i in "${!_options[@]}"; do
            echo -e "  [$((i+1))] ${_options[$i]}"
        done
        read -rp "请选择 [1-$_count]: " _choice
        if [[ "$_choice" =~ ^[0-9]+$ ]] && [[ "$_choice" -ge 1 ]] && [[ "$_choice" -le $_count ]]; then
            eval "$_result_var=$((_choice - 1))"
            return 0
        else
            eval "$_result_var=255"
            return 1
        fi
    fi

    local _selected=0
    local _key=""
    local _escape_char
    _escape_char=$(printf '\033')

    # 隐藏光标
    tput civis 2>/dev/null || true

    # 捕获退出信号，确保恢复光标
    trap 'tput cnorm 2>/dev/null || true; trap - INT TERM EXIT' INT TERM EXIT

    # 打印标题
    echo ""
    echo -e "$_title"
    echo -e "  ${DIM}使用 ↑↓ 键选择，Enter 确认，ESC 取消${NC}"
    echo ""

    # 首次绘制菜单
    _draw_menu _options[@] $_selected $_count

    # 读取按键循环
    while true; do
        # 读取单个字符（静默、不回显）
        IFS= read -rsn1 _key 2>/dev/null || true

        # ESC 键处理
        if [[ "$_key" == "$_escape_char" ]]; then
            # 尝试读取后续字符（超时 0.1 秒）
            local _seq=""
            IFS= read -rsn1 -t 0.1 _seq 2>/dev/null || true

            if [[ -z "$_seq" ]]; then
                # 单独按了 ESC，取消选择
                _clear_menu $_count
                tput cnorm 2>/dev/null || true
                trap - INT TERM EXIT
                eval "$_result_var=255"
                return 1
            fi

            if [[ "$_seq" == "[" ]]; then
                # 读取方向键的最后一个字符
                local _arrow=""
                IFS= read -rsn1 -t 0.1 _arrow 2>/dev/null || true

                case "$_arrow" in
                    A) # 上箭头
                        if [[ $_selected -gt 0 ]]; then
                            _selected=$((_selected - 1))
                        else
                            _selected=$((_count - 1))  # 循环到末尾
                        fi
                        ;;
                    B) # 下箭头
                        if [[ $_selected -lt $((_count - 1)) ]]; then
                            _selected=$((_selected + 1))
                        else
                            _selected=0  # 循环到开头
                        fi
                        ;;
                    *) # 忽略其他转义序列（左右箭头等）
                        ;;
                esac
            fi
            # 忽略其他 ESC 序列

        elif [[ "$_key" == "" ]]; then
            # Enter 键 —— 确认选择
            _clear_menu $_count
            tput cnorm 2>/dev/null || true
            trap - INT TERM EXIT

            # 显示选择结果
            echo -e "  ${GREEN}●${NC} ${_options[$_selected]}"
            echo ""

            eval "$_result_var=$_selected"
            return 0

        elif [[ "$_key" == "k" || "$_key" == "K" ]]; then
            # vim 风格：k 上移
            if [[ $_selected -gt 0 ]]; then
                _selected=$((_selected - 1))
            else
                _selected=$((_count - 1))
            fi

        elif [[ "$_key" == "j" || "$_key" == "J" ]]; then
            # vim 风格：j 下移
            if [[ $_selected -lt $((_count - 1)) ]]; then
                _selected=$((_selected + 1))
            else
                _selected=0
            fi

        elif [[ "$_key" == "q" || "$_key" == "Q" ]]; then
            # q 取消
            _clear_menu $_count
            tput cnorm 2>/dev/null || true
            trap - INT TERM EXIT
            eval "$_result_var=255"
            return 1
        fi
        # 其他按键忽略

        # 重绘菜单
        _redraw_menu _options[@] $_selected $_count
    done
}

# 绘制菜单（首次）
_draw_menu() {
    local -n _dm_opts=$1
    local _dm_sel=$2
    local _dm_count=$3

    for i in "${!_dm_opts[@]}"; do
        if [[ $i -eq $_dm_sel ]]; then
            echo -e "  ${CYAN}${BOLD}● ${_dm_opts[$i]}${NC}"
        else
            echo -e "  ${DIM}○ ${_dm_opts[$i]}${NC}"
        fi
    done
}

# 重绘菜单（光标回退后重新绘制）
_redraw_menu() {
    local -n _rm_opts=$1
    local _rm_sel=$2
    local _rm_count=$3

    # 光标上移 N 行
    printf '\033[%dA' "$_rm_count"

    for i in "${!_rm_opts[@]}"; do
        # 清除当前行
        printf '\033[2K'
        if [[ $i -eq $_rm_sel ]]; then
            echo -e "  ${CYAN}${BOLD}● ${_rm_opts[$i]}${NC}"
        else
            echo -e "  ${DIM}○ ${_rm_opts[$i]}${NC}"
        fi
    done
}

# 清除菜单区域（选择完成后清理）
_clear_menu() {
    local _cm_count=$1

    # 光标上移 N 行
    printf '\033[%dA' "$_cm_count"

    for (( i = 0; i < _cm_count; i++ )); do
        printf '\033[2K\n'
    done

    # 再上移回来
    printf '\033[%dA' "$_cm_count"
}

# ============================================================
# 兼容性包装：处理 Bash 3.x（macOS）不支持 nameref 的情况
# ============================================================
# macOS 自带 Bash 3.2 不支持 declare -n（nameref），
# 因此用全局数组 + 简化的绘制函数替代。

# 检测 Bash 版本是否支持 nameref
_bash_supports_nameref() {
    [[ "${BASH_VERSINFO[0]}" -ge 4 && "${BASH_VERSINFO[1]}" -ge 3 ]] || \
    [[ "${BASH_VERSINFO[0]}" -ge 5 ]]
}

# 如果 Bash 版本过低，覆盖绘制函数为兼容版本
if ! _bash_supports_nameref; then
    # 使用全局数组传递选项
    _MENU_OPTIONS=()

    _draw_menu() {
        # 参数：忽略第一个（数组引用），用全局 _MENU_OPTIONS
        local _dm_sel=$2
        local _dm_count=$3

        for (( i = 0; i < _dm_count; i++ )); do
            if [[ $i -eq $_dm_sel ]]; then
                echo -e "  ${CYAN}${BOLD}● ${_MENU_OPTIONS[$i]}${NC}"
            else
                echo -e "  ${DIM}○ ${_MENU_OPTIONS[$i]}${NC}"
            fi
        done
    }

    _redraw_menu() {
        local _rm_sel=$2
        local _rm_count=$3

        printf '\033[%dA' "$_rm_count"

        for (( i = 0; i < _rm_count; i++ )); do
            printf '\033[2K'
            if [[ $i -eq $_rm_sel ]]; then
                echo -e "  ${CYAN}${BOLD}● ${_MENU_OPTIONS[$i]}${NC}"
            else
                echo -e "  ${DIM}○ ${_MENU_OPTIONS[$i]}${NC}"
            fi
        done
    }

    # 覆盖 select_menu，使用 _MENU_OPTIONS 全局数组
    select_menu() {
        local _result_var="$1"
        local _title="$2"
        shift 2
        _MENU_OPTIONS=("$@")
        local _count=${#_MENU_OPTIONS[@]}

        if [[ $_count -eq 0 ]]; then
            eval "$_result_var=255"
            return 1
        fi

        if [[ ! -t 0 ]]; then
            echo -e "$_title"
            for i in "${!_MENU_OPTIONS[@]}"; do
                echo -e "  [$((i+1))] ${_MENU_OPTIONS[$i]}"
            done
            read -rp "请选择 [1-$_count]: " _choice
            if [[ "$_choice" =~ ^[0-9]+$ ]] && [[ "$_choice" -ge 1 ]] && [[ "$_choice" -le $_count ]]; then
                eval "$_result_var=$((_choice - 1))"
                return 0
            else
                eval "$_result_var=255"
                return 1
            fi
        fi

        local _selected=0
        local _key=""
        local _escape_char
        _escape_char=$(printf '\033')

        tput civis 2>/dev/null || true
        trap 'tput cnorm 2>/dev/null || true; trap - INT TERM EXIT' INT TERM EXIT

        echo ""
        echo -e "$_title"
        echo -e "  ${DIM}使用 ↑↓ 键选择，Enter 确认，ESC 取消${NC}"
        echo ""

        _draw_menu "" $_selected $_count

        while true; do
            IFS= read -rsn1 _key 2>/dev/null || true

            if [[ "$_key" == "$_escape_char" ]]; then
                local _seq=""
                IFS= read -rsn1 -t 0.1 _seq 2>/dev/null || true

                if [[ -z "$_seq" ]]; then
                    _clear_menu $_count
                    tput cnorm 2>/dev/null || true
                    trap - INT TERM EXIT
                    eval "$_result_var=255"
                    return 1
                fi

                if [[ "$_seq" == "[" ]]; then
                    local _arrow=""
                    IFS= read -rsn1 -t 0.1 _arrow 2>/dev/null || true

                    case "$_arrow" in
                        A)
                            if [[ $_selected -gt 0 ]]; then
                                _selected=$((_selected - 1))
                            else
                                _selected=$((_count - 1))
                            fi
                            ;;
                        B)
                            if [[ $_selected -lt $((_count - 1)) ]]; then
                                _selected=$((_selected + 1))
                            else
                                _selected=0
                            fi
                            ;;
                    esac
                fi

            elif [[ "$_key" == "" ]]; then
                _clear_menu $_count
                tput cnorm 2>/dev/null || true
                trap - INT TERM EXIT
                echo -e "  ${GREEN}●${NC} ${_MENU_OPTIONS[$_selected]}"
                echo ""
                eval "$_result_var=$_selected"
                return 0

            elif [[ "$_key" == "k" || "$_key" == "K" ]]; then
                if [[ $_selected -gt 0 ]]; then
                    _selected=$((_selected - 1))
                else
                    _selected=$((_count - 1))
                fi

            elif [[ "$_key" == "j" || "$_key" == "J" ]]; then
                if [[ $_selected -lt $((_count - 1)) ]]; then
                    _selected=$((_selected + 1))
                else
                    _selected=0
                fi

            elif [[ "$_key" == "q" || "$_key" == "Q" ]]; then
                _clear_menu $_count
                tput cnorm 2>/dev/null || true
                trap - INT TERM EXIT
                eval "$_result_var=255"
                return 1
            fi

            _redraw_menu "" $_selected $_count
        done
    }
fi

# ============================================================
# 启动 Claude Code
# ============================================================
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

get_project_info() {
    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")

    if [[ -f "$(git rev-parse --git-dir 2>/dev/null)/../.git" ]] || \
       [[ "$(git rev-parse --git-dir 2>/dev/null)" == *".git/worktrees/"* ]]; then
        IS_WORKTREE=true
    else
        IS_WORKTREE=false
    fi

    MAIN_WORKTREE_DIR=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
    PROJECT_NAME=$(basename "$MAIN_WORKTREE_DIR")
    PARENT_DIR=$(dirname "$MAIN_WORKTREE_DIR")
}

get_worktree_list() {
    WORKTREE_LIST=()
    WORKTREE_BRANCHES=()
    WORKTREE_DIRS=()

    while IFS= read -r line; do
        local wt_dir wt_branch
        wt_dir=$(echo "$line" | awk '{print $1}')
        wt_branch=$(echo "$line" | sed -n 's/.*\[\(.*\)\].*/\1/p')

        if [[ "$wt_dir" == "$MAIN_WORKTREE_DIR" ]]; then
            continue
        fi

        if [[ -z "$wt_branch" ]]; then
            continue
        fi

        WORKTREE_LIST+=("$wt_dir|$wt_branch")
        WORKTREE_BRANCHES+=("$wt_branch")
        WORKTREE_DIRS+=("$wt_dir")
    done < <(git worktree list)
}

validate_branch_name() {
    local name="$1"

    if [[ -z "$name" ]]; then
        error "分支名不能为空。"
        return 1
    fi

    if [[ "$name" =~ \  ]]; then
        error "分支名不能包含空格：'$name'"
        return 1
    fi

    if [[ ! "$name" =~ ^[a-zA-Z0-9/_-]+$ ]]; then
        error "分支名仅允许使用字母、数字、-、_、/ 字符：'$name'"
        return 1
    fi

    if [[ "$name" == -* ]]; then
        error "分支名不能以 - 开头：'$name'"
        return 1
    fi

    if git show-ref --verify --quiet "refs/heads/$name" 2>/dev/null; then
        error "分支 '$name' 已存在，请使用其他名称。"
        return 1
    fi

    return 0
}

# ============================================================
# 创建新的 worktree
# ============================================================
create_new_worktree() {
    echo ""
    echo -e "${CYAN}${BOLD}◆ 创建新的 Worktree 分支${NC}"
    echo ""
    echo -e "  请输入新分支的名称（例如：feat/smart-picker, dev, test）"
    echo -e "  ${DIM}仅允许字母、数字、-、_、/ 字符，不能有空格${NC}"
    echo ""
    read -rp "  > " new_branch

    if ! validate_branch_name "$new_branch"; then
        echo ""
        warn "请重新运行脚本并输入有效的分支名。"
        exit 1
    fi

    local safe_branch_name
    safe_branch_name=$(echo "$new_branch" | tr '/' '-')
    local worktree_dir="${PARENT_DIR}/${PROJECT_NAME}-${safe_branch_name}"

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

# ============================================================
# 选择已有 worktree 并启动
# ============================================================
select_existing_worktree() {
    local count=${#WORKTREE_BRANCHES[@]}

    if [[ $count -eq 0 ]]; then
        warn "当前没有任何 worktree 分支。"
        echo ""
        read -rp "按 Enter 返回主菜单..." _
        show_main_menu
        return
    fi

    # 构建选项列表（分支名 + 路径）
    local options=()
    for i in "${!WORKTREE_BRANCHES[@]}"; do
        options+=("${WORKTREE_BRANCHES[$i]}  ${DIM}${WORKTREE_DIRS[$i]}${NC}")
    done

    local choice
    if select_menu choice "${CYAN}${BOLD}◆ 选择要切换的 Worktree 分支${NC}" "${options[@]}"; then
        local selected_branch="${WORKTREE_BRANCHES[$choice]}"
        local selected_dir="${WORKTREE_DIRS[$choice]}"

        if [[ ! -d "$selected_dir" ]]; then
            error "Worktree 目录不存在：$selected_dir"
            echo "  该 worktree 可能已被手动删除。请运行 git worktree prune 清理。"
            exit 1
        fi

        launch_claude "$selected_branch" "$selected_dir"
    else
        # 用户取消，返回主菜单
        show_main_menu
    fi
}

# ============================================================
# 删除已有 worktree
# ============================================================
delete_existing_worktree() {
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

    # 构建选项列表
    local options=()
    for i in "${!WORKTREE_BRANCHES[@]}"; do
        options+=("${WORKTREE_BRANCHES[$i]}  ${DIM}${WORKTREE_DIRS[$i]}${NC}")
    done

    local choice
    if select_menu choice "${CYAN}${BOLD}◆ 选择要删除的 Worktree 分支${NC}" "${options[@]}"; then
        local selected_branch="${WORKTREE_BRANCHES[$choice]}"
        local selected_dir="${WORKTREE_DIRS[$choice]}"

        # 二次确认（使用上下键选择，默认高亮在"否"上）
        echo ""
        echo -e "  ${YELLOW}${BOLD}即将删除以下 Worktree：${NC}"
        echo -e "  分支：${BOLD}$selected_branch${NC}"
        echo -e "  目录：$selected_dir"
        echo -e "  ${RED}此操作将删除该目录下所有未提交的修改！${NC}"

        local confirm
        if select_menu confirm "${YELLOW}确认删除？${NC}" "否，取消删除" "是，确认删除"; then
            if [[ $confirm -ne 1 ]]; then
                # 选了"否"
                info "已取消删除。"
                echo ""
                read -rp "按 Enter 返回主菜单..." _
                show_main_menu
                return
            fi
        else
            # ESC 取消
            info "已取消删除。"
            echo ""
            read -rp "按 Enter 返回主菜单..." _
            show_main_menu
            return
        fi

        # 执行删除
        echo ""
        info "正在删除 worktree..."

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

        # 删除对应的本地分支
        if git show-ref --verify --quiet "refs/heads/$selected_branch" 2>/dev/null; then
            local del_branch_choice
            if select_menu del_branch_choice "${CYAN}是否同时删除本地分支 '${selected_branch}'？${NC}" "否，保留分支" "是，删除分支"; then
                if [[ $del_branch_choice -eq 1 ]]; then
                    if ! git branch -D "$selected_branch" 2>&1; then
                        warn "分支删除失败，可能需要手动处理。"
                    else
                        success "本地分支 '$selected_branch' 已删除。"
                    fi
                fi
            fi
        fi

        echo ""
        success "Worktree 已删除：$selected_dir"
        echo ""
        read -rp "按 Enter 返回主菜单..." _
        show_main_menu
    else
        # 用户取消，返回主菜单
        show_main_menu
    fi
}

# ============================================================
# 主菜单
# ============================================================
show_main_menu() {
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

    # 构建菜单选项
    local menu_options=()
    local menu_actions=()

    menu_options+=("在 ${BOLD}${CURRENT_BRANCH}${NC} 分支上启动 Claude")
    menu_actions+=("launch_current")

    if [[ "$has_worktrees" == true ]]; then
        menu_options+=("切换到已有的 Worktree 分支")
        menu_actions+=("select_worktree")
    fi

    menu_options+=("创建新的 Worktree 分支")
    menu_actions+=("create_worktree")

    if [[ "$has_worktrees" == true ]]; then
        menu_options+=("删除已有的 Worktree 分支")
        menu_actions+=("delete_worktree")
    fi

    menu_options+=("退出")
    menu_actions+=("exit_app")

    local choice
    if select_menu choice "${CYAN}${BOLD}◆ 请选择操作${NC}" "${menu_options[@]}"; then
        local action="${menu_actions[$choice]}"

        case "$action" in
            launch_current)
                launch_claude "$CURRENT_BRANCH" "$(pwd)"
                ;;
            select_worktree)
                select_existing_worktree
                ;;
            create_worktree)
                create_new_worktree
                ;;
            delete_worktree)
                delete_existing_worktree
                ;;
            exit_app)
                info "已退出。"
                exit 0
                ;;
        esac
    else
        # ESC 取消 = 退出
        echo ""
        info "已退出。"
        exit 0
    fi
}

# ============================================================
# 主流程
# ============================================================
main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     Claude Code 启动器 v2.0         ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo ""

    check_claude_installed
    check_not_root
    check_git_repo
    get_project_info

    info "项目：$PROJECT_NAME | 当前分支：$CURRENT_BRANCH"

    if [[ "$IS_WORKTREE" == true ]]; then
        success "当前处于 Worktree 分支，直接启动 Claude。"
        launch_claude "$CURRENT_BRANCH" "$(pwd)"
    else
        show_main_menu
    fi
}

main
