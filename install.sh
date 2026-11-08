#!/usr/bin/env bash
# FleetUp 在线安装脚本（Linux）
#
#   curl -fsSL "https://raw.githubusercontent.com/0x6666/fleetup/refs/heads/main/install.sh" | sudo bash
#
# 流程：检测架构 -> 下载最新 v3 Release -> 交互填写角色与连接参数 -> 写入配置 ->
#       缺少 supervisor 时自动安装 -> 注册为 supervisor 程序并启动。
# 已安装时可选择升级（只换程序）或重新配置（先备份原配置）。
#
# 交互通过 /dev/tty 读取，因此可以用管道执行。没有终端时，可用环境变量预填，未提供的必填项会报错：
#   FLEETUP_SERVICES_ROOT  服务根目录，默认 /opt/services
#   FLEETUP_ROLE           master 或 edge
#   FLEETUP_ACTION         已安装时的操作：upgrade / reconfigure
#   FLEETUP_NODE_NAME / FLEETUP_MASTER_URL / FLEETUP_EDGE_AUTH_TOKEN / FLEETUP_AUTH_TOKEN
#   FLEETUP_LISTEN_ADDR / FLEETUP_TELEGRAM_BOT_KEY / FLEETUP_TELEGRAM_ALLOW_UID / FLEETUP_PROXY_URL
#   FLEETUP_VERSION        指定版本（如 v3.0.26），默认最新
# 本源码仓库中的文件为 scripts/install-online.sh，发版时由 build.py 同步到 GitHub 仓库 main 分支的 install.sh。

set -euo pipefail

GITHUB_REPO="0x6666/fleetup"
RELEASE_MAJOR="3"
PROGRAM_NAME="fleetup"
DEFAULT_SERVICES_ROOT="/opt/services"

# ---------------------------------------------------------------- 输出

if [ -t 1 ]; then
    C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_BOLD=$'\033[1m' C_RESET=$'\033[0m'
else
    C_RED="" C_GREEN="" C_YELLOW="" C_BOLD="" C_RESET=""
fi

info() { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"; }
ok() { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s警告: %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
die() {
    printf '%s错误: %s%s\n' "$C_RED" "$*" "$C_RESET" >&2
    exit 1
}

# ---------------------------------------------------------------- 交互

# 管道执行时标准输入是脚本本身，交互一律从 /dev/tty 读取
HAS_TTY=0
if [ -r /dev/tty ] && { : </dev/tty; } 2>/dev/null; then
    HAS_TTY=1
fi

# ask 变量名 提示 [默认值] [环境变量值]：环境变量优先，其次交互输入，回车取默认值
ask() {
    local __var="$1" prompt="$2" default="${3:-}" preset="${4:-}" answer=""
    if [ -n "$preset" ]; then
        printf -v "$__var" '%s' "$preset"
        return
    fi
    if [ "$HAS_TTY" != 1 ]; then
        [ -n "$default" ] || die "没有可交互的终端，请通过环境变量提供：$prompt"
        printf -v "$__var" '%s' "$default"
        return
    fi
    if [ -n "$default" ]; then
        printf '%s [%s]: ' "$prompt" "$default" >/dev/tty
    else
        printf '%s: ' "$prompt" >/dev/tty
    fi
    IFS= read -r answer </dev/tty || true
    printf -v "$__var" '%s' "${answer:-$default}"
}

# ask_secret 变量名 提示 [环境变量值]：输入不回显；允许为空
ask_secret() {
    local __var="$1" prompt="$2" preset="${3:-}" answer=""
    if [ -n "$preset" ] || [ "$HAS_TTY" != 1 ]; then
        printf -v "$__var" '%s' "$preset"
        return
    fi
    printf '%s: ' "$prompt" >/dev/tty
    IFS= read -rs answer </dev/tty || true
    printf '\n' >/dev/tty
    printf -v "$__var" '%s' "$answer"
}

# ask_yes_no 提示 默认(y/n)：返回 0 表示是
ask_yes_no() {
    local prompt="$1" default="$2" answer=""
    if [ "$HAS_TTY" != 1 ]; then
        [ "$default" = y ]
        return
    fi
    while true; do
        printf '%s [%s]: ' "$prompt" "$([ "$default" = y ] && echo Y/n || echo y/N)" >/dev/tty
        IFS= read -r answer </dev/tty || true
        answer="${answer:-$default}"
        case "$answer" in
            y | Y | yes | 是) return 0 ;;
            n | N | no | 否) return 1 ;;
        esac
    done
}

# ask_choice 变量名 提示 默认 预设值 选项...：选项格式「值|说明」
ask_choice() {
    local __var="$1" prompt="$2" default="$3" preset="$4"
    shift 4
    local options=("$@") i answer="" value
    if [ -n "$preset" ]; then
        for i in "${options[@]}"; do
            [ "${i%%|*}" = "$preset" ] && { printf -v "$__var" '%s' "$preset"; return; }
        done
        die "$prompt：不支持的取值 $preset"
    fi
    if [ "$HAS_TTY" != 1 ]; then
        printf -v "$__var" '%s' "$default"
        return
    fi
    local default_no=1
    printf '%s\n' "$prompt" >/dev/tty
    for i in "${!options[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${options[$i]#*|}" >/dev/tty
        [ "${options[$i]%%|*}" = "$default" ] && default_no=$((i + 1))
    done
    while true; do
        printf '请选择 [%d]: ' "$default_no" >/dev/tty
        IFS= read -r answer </dev/tty || true
        if [ -z "$answer" ]; then
            printf -v "$__var" '%s' "$default"
            return
        fi
        if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "${#options[@]}" ]; then
            value="${options[$((answer - 1))]%%|*}"
            printf -v "$__var" '%s' "$value"
            return
        fi
    done
}

# ---------------------------------------------------------------- 环境检测

detect_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo amd64 ;;
        aarch64 | arm64) echo arm64 ;;
        *) die "暂不支持的 CPU 架构: $(uname -m)（仅支持 amd64、arm64）" ;;
    esac
}

detect_pkg_manager() {
    local pm
    for pm in apt-get dnf yum zypper apk pacman; do
        if command -v "$pm" >/dev/null 2>&1; then
            echo "$pm"
            return
        fi
    done
    echo ""
}

APT_UPDATED=0
# 包管理器的标准输入一律接 /dev/null：管道执行时标准输入是脚本本身，交互执行时是终端，都不能被子进程读走
pkg_install() {
    pkg_install_inner "$@" </dev/null
}

pkg_install_inner() {
    local pm
    pm="$(detect_pkg_manager)"
    # 只输出错误，避免包管理器的进度信息淹没交互提示
    case "$pm" in
        apt-get)
            if [ "$APT_UPDATED" = 0 ]; then
                DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null
                APT_UPDATED=1
            fi
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null
            ;;
        dnf) dnf install -y -q "$@" >/dev/null ;;
        yum) yum install -y -q "$@" >/dev/null ;;
        zypper) zypper --non-interactive --quiet install "$@" >/dev/null ;;
        apk) apk add --no-cache -q "$@" >/dev/null ;;
        pacman) pacman -Sy --noconfirm --needed "$@" >/dev/null ;;
        *) return 1 ;;
    esac
}

ensure_command() {
    local cmd="$1" pkg="$2"
    command -v "$cmd" >/dev/null 2>&1 && return
    info "缺少 $cmd，正在安装 $pkg ..."
    pkg_install "$pkg" || die "安装 $pkg 失败，请手动安装后重试"
}

# ---------------------------------------------------------------- 下载

# release_asset_url 架构 [版本]：输出资产下载地址与版本号（以制表符分隔）
release_asset_url() {
    local arch="$1" version="${2:-}" api json url
    if [ -n "$version" ]; then
        api="https://api.github.com/repos/$GITHUB_REPO/releases/tags/$version"
    else
        api="https://api.github.com/repos/$GITHUB_REPO/releases?per_page=30"
    fi
    json="$(curl -fsSL -H "Accept: application/vnd.github+json" "$api")" || die "查询 GitHub Release 失败：$api"
    # Release 按创建时间倒序，取第一个匹配当前主版本与架构的资产
    url="$(printf '%s' "$json" | grep -oE "\"browser_download_url\": *\"[^\"]*/fleetup-v${RELEASE_MAJOR}\.[0-9]+\.[0-9]+-linux-${arch}\.xz\"" |
        head -n1 | sed -E 's/.*"(https:[^"]+)"$/\1/')"
    [ -n "$url" ] || die "未找到 linux-${arch} 的 v${RELEASE_MAJOR} 版本安装包"
    version="$(printf '%s' "$url" | sed -E 's#.*/fleetup-(v[0-9.]+)-linux-.*#\1#')"
    printf '%s\t%s\n' "$url" "$version"
}

# install_binary 安装目录 架构 [版本]：下载并解压为 fleetup.<版本>，再把 fleetup 指向它（与自升级布局一致）
install_binary() {
    local dir="$1" arch="$2" want="${3:-}" url version tmp
    IFS=$'\t' read -r url version <<<"$(release_asset_url "$arch" "$want")"
    info "下载 $PROGRAM_NAME $version (linux-$arch) ..."
    tmp="$(mktemp -d)"
    local progress=-sS
    [ "$HAS_TTY" = 1 ] && progress=--progress-bar
    if ! curl -fL "$progress" --retry 3 -o "$tmp/fleetup.xz" "$url" || ! xz -d "$tmp/fleetup.xz"; then
        rm -rf "$tmp"
        die "下载或解压失败：$url"
    fi
    chmod 0755 "$tmp/fleetup"
    if ! "$tmp/fleetup" -v >/dev/null 2>&1; then
        rm -rf "$tmp"
        die "下载的程序无法运行，请确认架构是否正确"
    fi
    mkdir -p "$dir"
    mv -f "$tmp/fleetup" "$dir/$PROGRAM_NAME.${version#v}"
    rm -rf "$tmp"
    ln -sfn "$dir/$PROGRAM_NAME.${version#v}" "$dir/$PROGRAM_NAME"
    INSTALLED_VERSION="$version"
    ok "已安装 $dir/$PROGRAM_NAME -> $PROGRAM_NAME.${version#v}"
}

# ---------------------------------------------------------------- 配置

random_token() {
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# toml_string 值：输出 TOML 基本字符串（转义反斜杠与双引号）
toml_string() {
    local v="${1//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf '"%s"' "$v"
}

# toml_int_array "1, 2"：校验并输出整数数组
toml_int_array() {
    local raw="${1//[[:space:]]/}" item out=""
    [ -z "$raw" ] && { printf '[]'; return; }
    IFS=',' read -r -a items <<<"$raw"
    for item in "${items[@]}"; do
        [[ "$item" =~ ^-?[0-9]+$ ]] || die "Telegram 用户 ID 必须是整数: $item"
        out="${out:+$out, }$item"
    done
    printf '[%s]' "$out"
}

# write_master_config 路径：写入 Master 配置（令牌由 FleetUp 首次加载时加密为 AT- 密文）
write_master_config() {
    local path="$1"
    {
        echo "# 由 FleetUp 在线安装脚本生成于 $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# 令牌类字段可写明文，FleetUp 加载时会自动加密为 AT- 密文"
        [ -n "$CFG_PROXY_URL" ] && echo "proxy_url = $(toml_string "$CFG_PROXY_URL")"
        if [ -n "$CFG_TG_KEY" ]; then
            echo "telegram_bot_key = $(toml_string "$CFG_TG_KEY")"
            echo "telegram_bot_allow_uid = $(toml_int_array "$CFG_TG_UIDS")"
        fi
        echo
        echo "[master]"
        echo "listen_addr = $(toml_string "$CFG_LISTEN_ADDR")"
        echo "auth_token = $(toml_string "$CFG_AUTH_TOKEN")"
        echo "web_enabled = $CFG_WEB_ENABLED"
    } >"$path"
    chmod 0600 "$path"
}

# write_edge_config 路径：写入 Edge 配置；专用令牌写 edge_auth_token，共享令牌写 auth_token
write_edge_config() {
    local path="$1"
    {
        echo "# 由 FleetUp 在线安装脚本生成于 $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# 令牌类字段可写明文，FleetUp 加载时会自动加密为 AT- 密文"
        [ -n "$CFG_PROXY_URL" ] && echo "proxy_url = $(toml_string "$CFG_PROXY_URL")"
        echo
        echo "[edge]"
        echo "node_name = $(toml_string "$CFG_NODE_NAME")"
        echo "master_url = $(toml_string "$CFG_MASTER_URL")"
        if [ "$CFG_TOKEN_KIND" = dedicated ]; then
            echo "edge_auth_token = $(toml_string "$CFG_TOKEN")"
        else
            echo "auth_token = $(toml_string "$CFG_TOKEN")"
        fi
    } >"$path"
    chmod 0600 "$path"
}

configure_master() {
    ask CFG_LISTEN_ADDR "Master 监听地址（Edge 连接 ws://<地址>/ws，Web 控制台 /ui/）" "0.0.0.0:8080" "${FLEETUP_LISTEN_ADDR:-}"
    ask_secret CFG_AUTH_TOKEN "共享 auth_token（留空自动生成）" "${FLEETUP_AUTH_TOKEN:-}"
    CFG_AUTH_TOKEN_GENERATED=0
    if [ -z "$CFG_AUTH_TOKEN" ]; then
        CFG_AUTH_TOKEN="$(random_token)"
        CFG_AUTH_TOKEN_GENERATED=1
    fi
    ask_secret CFG_TG_KEY "Telegram Bot Token（可选，Web 控制台登录需要）" "${FLEETUP_TELEGRAM_BOT_KEY:-}"
    CFG_TG_UIDS=""
    CFG_WEB_ENABLED=false
    if [ -n "$CFG_TG_KEY" ]; then
        ask CFG_TG_UIDS "允许操作的 Telegram 用户 ID（多个用逗号分隔）" "" "${FLEETUP_TELEGRAM_ALLOW_UID:-}"
        toml_int_array "$CFG_TG_UIDS" >/dev/null
        if ask_yes_no "启用 Web 控制台（登录验证码通过 Telegram 发送）？" y; then
            CFG_WEB_ENABLED=true
        fi
    fi
    ask CFG_PROXY_URL "代理地址（可选，如 socks5://127.0.0.1:1080）" "-" "${FLEETUP_PROXY_URL:-}"
    [ "$CFG_PROXY_URL" = "-" ] && CFG_PROXY_URL=""
    return 0
}

configure_edge() {
    local default_name
    default_name="$(hostname -s 2>/dev/null || hostname)"
    while true; do
        ask CFG_NODE_NAME "节点名称 node_name" "$default_name" "${FLEETUP_NODE_NAME:-}"
        [[ "$CFG_NODE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && break
        [ -n "${FLEETUP_NODE_NAME:-}" ] && die "node_name 只能包含字母、数字、点、下划线和连字符"
        warn "node_name 只能包含字母、数字、点、下划线和连字符"
    done
    while true; do
        ask CFG_MASTER_URL "Master 地址（ws:// 或 wss:// 开头，以 /ws 结尾）" "" "${FLEETUP_MASTER_URL:-}"
        [[ "$CFG_MASTER_URL" =~ ^wss?:// ]] && break
        [ -n "${FLEETUP_MASTER_URL:-}" ] && die "master_url 必须以 ws:// 或 wss:// 开头"
        warn "master_url 必须以 ws:// 或 wss:// 开头"
    done
    local preset_kind=""
    [ -n "${FLEETUP_EDGE_AUTH_TOKEN:-}" ] && preset_kind=dedicated
    [ -z "$preset_kind" ] && [ -n "${FLEETUP_AUTH_TOKEN:-}" ] && preset_kind=shared
    ask_choice CFG_TOKEN_KIND "认证方式" dedicated "$preset_kind" \
        "dedicated|节点专用令牌 edge_auth_token（推荐；在 Master 上执行 fleetup edge-token add $CFG_NODE_NAME 生成）" \
        "shared|共享 auth_token（与 Master 相同）"
    while true; do
        if [ "$CFG_TOKEN_KIND" = dedicated ]; then
            ask_secret CFG_TOKEN "专用令牌 edge_auth_token" "${FLEETUP_EDGE_AUTH_TOKEN:-}"
        else
            ask_secret CFG_TOKEN "共享 auth_token" "${FLEETUP_AUTH_TOKEN:-}"
        fi
        [ -n "$CFG_TOKEN" ] && break
        [ "$HAS_TTY" = 1 ] || die "缺少令牌：请设置 FLEETUP_EDGE_AUTH_TOKEN 或 FLEETUP_AUTH_TOKEN"
        warn "令牌不能为空"
    done
    ask CFG_PROXY_URL "代理地址（可选，如 socks5://127.0.0.1:1080）" "-" "${FLEETUP_PROXY_URL:-}"
    [ "$CFG_PROXY_URL" = "-" ] && CFG_PROXY_URL=""
    return 0
}

# ---------------------------------------------------------------- supervisor

ensure_supervisor() {
    if command -v supervisorctl >/dev/null 2>&1 && command -v supervisord >/dev/null 2>&1; then
        return
    fi
    step "安装 supervisor"
    local pm
    pm="$(detect_pkg_manager)"
    [ -n "$pm" ] || die "未找到包管理器，请手动安装 supervisor 后重试"
    # 首次失败通常是 RHEL 系未启用 EPEL，错误信息不必输出
    if ! pkg_install supervisor 2>/dev/null; then
        # RHEL / CentOS / Rocky 等需要先启用 EPEL
        if [ "$pm" = dnf ] || [ "$pm" = yum ]; then
            pkg_install epel-release && pkg_install supervisor || die "安装 supervisor 失败，请先启用 EPEL 后重试"
        else
            die "安装 supervisor 失败，请手动安装后重试"
        fi
    fi
    ok "supervisor 已安装"
}

supervisor_main_conf() {
    local f
    for f in /etc/supervisor/supervisord.conf /etc/supervisord.conf; do
        [ -f "$f" ] && { echo "$f"; return; }
    done
    echo ""
}

# supervisor_include_target 主配置：输出程序配置文件路径（按主配置 [include] files 推导目录与扩展名）
supervisor_include_target() {
    local conf="$1" pattern dir ext
    pattern="$(awk '
        /^\[include\]/ { inc = 1; next }
        /^\[/ { inc = 0 }
        inc && /^[[:space:]]*files[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); split($0, a, /[[:space:]]+/); print a[1]; exit }
    ' "$conf")"
    if [ -z "$pattern" ]; then
        printf '\n[include]\nfiles = /etc/supervisor/conf.d/*.conf\n' >>"$conf"
        pattern="/etc/supervisor/conf.d/*.conf"
    fi
    case "$pattern" in
        /*) ;;
        *) pattern="$(dirname "$conf")/$pattern" ;;
    esac
    dir="$(dirname "$pattern")"
    ext="${pattern##*.}"
    [ "$ext" = "$pattern" ] && ext="conf"
    mkdir -p "$dir"
    echo "$dir/$PROGRAM_NAME.$ext"
}

start_supervisor_service() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        local unit
        for unit in supervisor supervisord; do
            if systemctl list-unit-files "$unit.service" >/dev/null 2>&1 &&
                systemctl list-unit-files "$unit.service" | grep -q "^$unit.service"; then
                systemctl enable --now "$unit" >/dev/null 2>&1 || warn "启用 $unit 服务失败"
                return
            fi
        done
    elif command -v rc-service >/dev/null 2>&1; then
        rc-update add supervisord default >/dev/null 2>&1 || true
        rc-service supervisord start >/dev/null 2>&1 || true
        return
    fi
    if ! supervisorctl status >/dev/null 2>&1; then
        local conf
        conf="$(supervisor_main_conf)"
        [ -n "$conf" ] && supervisord -c "$conf" || warn "无法启动 supervisord，请手动启动"
    fi
}

# write_program_conf 程序配置路径 安装目录 配置文件 角色
write_program_conf() {
    local target="$1" dir="$2" config="$3" role="$4"
    mkdir -p "$dir/log"
    cat >"$target" <<EOF
; 由 FleetUp 在线安装脚本生成；FleetUp 自升级后主动退出，由 supervisor 重新拉起
[program:$PROGRAM_NAME]
command=$dir/$PROGRAM_NAME -c $config $role
directory=$dir
user=root
autostart=true
autorestart=true
startsecs=3
startretries=100
stopsignal=TERM
stopwaitsecs=60
environment=HOME="/root"
stdout_logfile=$dir/log/$PROGRAM_NAME.out.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
stderr_logfile=$dir/log/$PROGRAM_NAME.err.log
stderr_logfile_maxbytes=10MB
stderr_logfile_backups=3
EOF
}

reload_program() {
    supervisorctl reread >/dev/null </dev/null
    supervisorctl update >/dev/null </dev/null
    supervisorctl restart "$PROGRAM_NAME" >/dev/null 2>&1 || supervisorctl start "$PROGRAM_NAME" >/dev/null 2>&1 || true
    sleep 3
    if supervisorctl status "$PROGRAM_NAME" 2>/dev/null | grep -q RUNNING; then
        ok "$PROGRAM_NAME 已在 supervisor 中运行"
    else
        warn "$PROGRAM_NAME 未处于 RUNNING 状态，请查看日志：supervisorctl status $PROGRAM_NAME"
        supervisorctl status "$PROGRAM_NAME" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------- 主流程

detect_role() {
    local config="$1"
    if grep -q '^\[master\]' "$config" 2>/dev/null; then
        echo master
    elif grep -q '^\[edge\]' "$config" 2>/dev/null; then
        echo edge
    fi
}

main() {
    [ "$(uname -s)" = Linux ] || die "此脚本仅支持 Linux"
    [ "$(id -u)" = 0 ] || die "请以 root 运行：curl -fsSL https://raw.githubusercontent.com/$GITHUB_REPO/refs/heads/main/install.sh | sudo bash"

    local arch root dir config action role
    arch="$(detect_arch)"
    info "${C_BOLD}FleetUp 安装程序${C_RESET}（Linux $arch）"

    ensure_command curl curl
    ensure_command xz "$( [ "$(detect_pkg_manager)" = apt-get ] && echo xz-utils || echo xz)"

    ask root "服务根目录（FleetUp 安装在 <根目录>/fleetup，模板添加的服务也装在这里）" "$DEFAULT_SERVICES_ROOT" "${FLEETUP_SERVICES_ROOT:-}"
    [[ "$root" = /* ]] || die "服务根目录必须是绝对路径"
    root="${root%/}"
    dir="$root/$PROGRAM_NAME"
    # 放在可执行文件目录下的 .fleetup.toml，fleetup 命令行无需 -c 也能找到
    config="$dir/.fleetup.toml"

    action=install
    if [ -e "$dir/$PROGRAM_NAME" ] || [ -f "$config" ]; then
        info "检测到已安装：$dir"
        ask_choice action "请选择操作" upgrade "${FLEETUP_ACTION:-}" \
            "upgrade|升级程序（保留配置）" \
            "reconfigure|重新配置（备份原配置后重新填写）" \
            "exit|退出"
        [ "$action" = exit ] && exit 0
    fi

    if [ "$action" = upgrade ]; then
        [ -f "$config" ] || die "未找到配置 $config，请选择重新配置"
        role="$(detect_role "$config")"
        [ -n "$role" ] || die "无法从 $config 判断角色"
        step "升级 FleetUp"
        install_binary "$dir" "$arch" "${FLEETUP_VERSION:-}"
        ensure_supervisor
        start_supervisor_service
        local conf
        conf="$(supervisor_main_conf)"
        [ -n "$conf" ] || die "未找到 supervisord 主配置"
        write_program_conf "$(supervisor_include_target "$conf")" "$dir" "$config" "$role"
        reload_program
        ok "升级完成：$INSTALLED_VERSION"
        return
    fi

    step "填写配置"
    ask_choice role "节点角色" edge "${FLEETUP_ROLE:-}" \
        "edge|Edge（执行节点，连接到 Master）" \
        "master|Master（管理节点，提供 Telegram 与 Web 控制台）"
    if [ "$role" = master ]; then
        configure_master
    else
        configure_edge
    fi

    step "安装 FleetUp"
    install_binary "$dir" "$arch" "${FLEETUP_VERSION:-}"
    if [ -f "$config" ]; then
        cp -p "$config" "$config.bak.$(date +%Y%m%d%H%M%S)"
        info "已备份原配置"
    fi
    if [ "$role" = master ]; then
        write_master_config "$config"
    else
        write_edge_config "$config"
    fi
    ok "已写入配置 $config"
    # 首次加载会把明文令牌加密写回，同时校验配置
    "$dir/$PROGRAM_NAME" -c "$config" list >/dev/null 2>&1 </dev/null || warn "配置校验未通过，请检查 $config"
    ln -sfn "$dir/$PROGRAM_NAME" /usr/local/bin/$PROGRAM_NAME 2>/dev/null || true

    step "注册 supervisor 程序"
    ensure_supervisor
    start_supervisor_service
    local conf target
    conf="$(supervisor_main_conf)"
    [ -n "$conf" ] || die "未找到 supervisord 主配置"
    target="$(supervisor_include_target "$conf")"
    write_program_conf "$target" "$dir" "$config" "$role"
    info "已写入 $target"
    reload_program

    step "完成"
    info "版本：$INSTALLED_VERSION"
    info "配置：$config"
    info "日志：$dir/log/$PROGRAM_NAME.{out,err}.log"
    info "管理：supervisorctl status|restart $PROGRAM_NAME，命令行：$PROGRAM_NAME list"
    if [ "$role" = master ]; then
        if [ "${CFG_AUTH_TOKEN_GENERATED:-0}" = 1 ]; then
            info "${C_BOLD}已生成共享 auth_token（只显示这一次）：${C_RESET}$CFG_AUTH_TOKEN"
        fi
        info "为 Edge 生成专用令牌：$PROGRAM_NAME edge-token add <node_name>"
        [ "$CFG_WEB_ENABLED" = true ] && info "Web 控制台：http://<本机地址>:${CFG_LISTEN_ADDR##*:}/ui/（公网访问请放在 HTTPS 反向代理之后）"
    else
        info "节点 $CFG_NODE_NAME 将连接 $CFG_MASTER_URL，可在 Master 的 Web 控制台或 Telegram 查看是否上线"
    fi
}

# 整个脚本下载完成后才执行 main，避免管道中断时执行半截脚本；测试时设置 FLEETUP_INSTALL_LIB=1 只加载函数
if [ "${FLEETUP_INSTALL_LIB:-}" != 1 ]; then
    main "$@"
fi
