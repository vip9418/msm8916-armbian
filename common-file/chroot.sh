#!/bin/bash
set -euo pipefail

readonly PKGS_DIR="/tmp/local_packages"
readonly LOG_FILE="/tmp/chroot-build.log"

append_log() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}

log_info() { printf '🚀 %s\n' "$*"; append_log INFO "$*"; }
log_ok()   { printf '✅ %s\n' "$*"; append_log OK "$*"; }
log_warn() { printf '⚠️  %s\n' "$*"; append_log WARN "$*"; }
log_err()  { printf '❌ %s\n' "$*" >&2; append_log ERROR "$*"; }

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_err "请以 root 身份运行"
        exit 1
    fi
}

setup_dns() {
    log_info "配置 DNS..."
    mkdir -p /run/systemd/resolve
    printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 8.8.8.8\n' > /run/systemd/resolve/stub-resolv.conf
    rm -f /etc/resolv.conf
    printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 8.8.8.8\n' > /etc/resolv.conf
    log_ok "DNS 已配置"
}

check_network() {
    log_info "检查 chroot 网络环境..."
    setup_dns

    if [[ -f /proc/net/dev ]]; then
        log_info "网络接口:"
        grep -E 'eth|wlan|usb|enp' /proc/net/dev | sed 's/^/  /' || log_warn "无常见网络接口"
    fi

    log_info "当前 DNS 配置:"
    sed 's/^/  /' /etc/resolv.conf

    if ping -c 1 -W 3 223.5.5.5 >/dev/null 2>&1; then
        log_ok "网络连通（IP层）"
    else
        log_warn "IP层无法连通，继续尝试..."
    fi

    if getent hosts mirrors.aliyun.com >/dev/null 2>&1; then
        log_ok "DNS 解析正常"
    else
        log_warn "DNS 解析失败，已使用备用 DNS，继续..."
    fi
}

fix_tmp_permissions() {
    log_info "修复 /tmp 权限..."
    chmod 1777 /tmp
    if ! touch /tmp/.apt-test 2>/dev/null; then
        log_err "/tmp 不可写"
        exit 1
    fi
    rm -f /tmp/.apt-test
    log_ok "/tmp 权限正常"
}

write_apt_sources() {
    local distro_id="debian"
    local codename="trixie"

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        distro_id="${ID:-debian}"
        codename="${VERSION_CODENAME:-trixie}"
        log_info "发行版: ${distro_id} | 代号: ${codename}"
    else
        log_warn "/etc/os-release 丢失，使用 Debian Trixie 默认源"
    fi

    if [[ "${distro_id}" == "ubuntu" ]]; then
        cat > /etc/apt/sources.list <<APT_EOF
deb http://mirrors.aliyun.com/ubuntu-ports/ ${codename} main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu-ports/ ${codename}-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu-ports/ ${codename}-backports main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu-ports/ ${codename}-security main restricted universe multiverse
APT_EOF
    else
        cat > /etc/apt/sources.list <<APT_EOF
deb http://mirrors.aliyun.com/debian ${codename} main contrib non-free non-free-firmware
deb http://mirrors.aliyun.com/debian ${codename}-updates main contrib non-free non-free-firmware
deb http://mirrors.aliyun.com/debian-security ${codename}-security main contrib non-free non-free-firmware
APT_EOF
    fi
}

install_local_debs() {
    local debs=()

    shopt -s nullglob
    debs=("${PKGS_DIR}"/*.deb)
    shopt -u nullglob

    if ((${#debs[@]})); then
        if dpkg -i "${debs[@]}"; then
            log_ok "本地 deb 包安装完成"
        else
            log_warn "本地 deb 包安装存在问题，后续尝试修复依赖"
        fi
    else
        log_warn "未在 ${PKGS_DIR} 找到任何 deb 包"
        [[ -d "${PKGS_DIR}" ]] && ls -la "${PKGS_DIR}/" || true
    fi
}

install_openstick_utils() {
    local debs=()

    shopt -s nullglob
    debs=("${PKGS_DIR}"/openstick-utils*.deb)
    shopt -u nullglob

    if ((${#debs[@]})); then
        if dpkg -i "${debs[@]}"; then
            log_ok "openstick-utils 安装完成"
        else
            log_warn "openstick-utils 安装存在问题，后续尝试修复依赖"
        fi
        DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y
        setup_dns
    else
        log_info "未找到 openstick-utils 本地包"
    fi
}

install_package() {
    log_info "配置软件源..."
    write_apt_sources

    log_info "更新软件源..."
    if ! apt-get update; then
        log_warn "apt update 失败，重新修复 DNS 后重试..."
        setup_dns
        apt-get update || {
            log_err "apt update 仍然失败"
            exit 1
        }
    fi

    log_info "安装本地 deb 包（路径: ${PKGS_DIR}）..."
    install_local_debs
    setup_dns

    log_info "联网修复本地包依赖（第一轮）..."
    DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y
    setup_dns

    log_info "安装核心网络组件..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        coreutils \
        network-manager \
        modemmanager \
        bc \
        bsdextrautils \
        gawk \
        locales \
        libqmi-utils \
        dnsmasq-base \
        iptables-persistent
    setup_dns

    log_info "安装 openstick-utils（如果存在）..."
    install_openstick_utils

    log_info "最终依赖修复确认（第二轮）..."
    DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y

    log_ok "全部包安装完成"
}

remove_package() {
    log_info "移除冲突包..."
    local pkgs=()

    while IFS= read -r pkg; do
        [[ -n "${pkg}" ]] && pkgs+=("${pkg}")
    done < <(
        dpkg-query -W -f='${Package} ${db:Status-Status}\n' 2>/dev/null | \
        awk '$2=="installed" && ($1=="meson" || $1 ~ /^linux-image/){print $1}'
    )

    if ((${#pkgs[@]})); then
        dpkg -P "${pkgs[@]}"
        log_ok "已移除: ${pkgs[*]}"
    else
        log_info "无冲突包需要移除"
    fi
}

set_language() {
    log_info "配置中文环境..."
    sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
    sed -i 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
    sed -i 's/^# *zh_CN GB2312/zh_CN GB2312/' /etc/locale.gen 2>/dev/null || true
    locale-gen || true
    unset LANGUAGE LC_ALL LC_MESSAGES LANG
    update-locale --reset LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 LANGUAGE=zh_CN:zh || true
    export LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 LANGUAGE=zh_CN:zh
    log_ok "语言配置完成"
}

enable_service() {
    local unit="$1"
    local success_msg="$2"

    if ! command -v systemctl >/dev/null 2>&1; then
        log_warn "systemctl 不存在，无法启用 ${unit}"
        return 0
    fi

    if systemctl enable "${unit}"; then
        log_ok "${success_msg}"
    else
        log_warn "enable ${unit} 失败"
    fi
}

common_set() {
    log_info "应用系统配置..."

    rm -f /usr/sbin/openstick-startup-diagnose.sh || true
    rm -f /usr/lib/systemd/system/openstick-startup-diagnose.service || true
    rm -f /usr/lib/systemd/system/openstick-startup-diagnose.timer || true

    local files=(
        "${PKGS_DIR}/mobian-setup-usb-network:/usr/sbin/mobian-setup-usb-network"
        "${PKGS_DIR}/mobian-setup-usb-network.service:/usr/lib/systemd/system/mobian-setup-usb-network.service"
        "${PKGS_DIR}/openstick-expanddisk-startup.sh:/usr/sbin/openstick-expanddisk-startup.sh"
        "${PKGS_DIR}/rules.v4:/etc/iptables/rules.v4"
        "${PKGS_DIR}/btrfs-compress.service:/usr/lib/systemd/system/btrfs-compress.service"
    )

    local pair src dst
    for pair in "${files[@]}"; do
        src="${pair%%:*}"
        dst="${pair##*:}"

        if [[ -f "${src}" ]]; then
            mkdir -p "$(dirname "${dst}")"
            cp "${src}" "${dst}"
            case "${dst}" in
                /usr/sbin/*|*.sh) chmod 0755 "${dst}" ;;
                *) chmod 0644 "${dst}" ;;
            esac
            log_ok "已注入: ${dst}"
        else
            log_warn "源文件不存在，跳过: ${src}"
        fi
    done

    log_info "启用开机自启服务..."

    if [[ -f /usr/lib/systemd/system/mobian-setup-usb-network.service ]]; then
        enable_service "mobian-setup-usb-network.service" \
            "mobian-setup-usb-network.service 已启用（USB RNDIS 网络）"
    else
        log_warn "mobian-setup-usb-network.service 不存在，USB 网络将无法工作"
    fi

    if [[ -f /usr/lib/systemd/system/btrfs-compress.service ]]; then
        enable_service "btrfs-compress.service" "btrfs-compress.service 已启用"
    fi

    # ── 时区 ──
    log_info "设置时区为 Asia/Chongqing..."
    rm -f /etc/localtime || true
    ln -sf /usr/share/zoneinfo/Asia/Chongqing /etc/localtime || true
    log_ok "时区已设置为 Asia/Chongqing"

    # ── fstab ──
    printf 'LABEL=aarch64 / btrfs defaults,noatime,compress=zstd,commit=30 0 0\n' > /etc/fstab

    # ── rc.local ──
    if [[ -f /etc/rc.local ]]; then
        log_info "修改 rc.local..."
        sed -i '1s/ -e//' /etc/rc.local || true
        python3 - << 'PYEOF'
try:
    with open('/etc/rc.local', 'r') as f:
        lines = f.readlines()
    insert_line = 'mcli c u USB\n'
    pos = min(12, len(lines))
    if insert_line not in lines:
        lines.insert(pos, insert_line)
        with open('/etc/rc.local', 'w') as f:
            f.writelines(lines)
        print('✅ mcli 命令已插入 rc.local')
    else:
        print('✅ mcli 命令已存在，跳过')
except Exception as e:
    print(f'⚠️  rc.local 处理异常（非致命）: {e}')
PYEOF
    fi

    [[ -f /usr/lib/systemd/system/rc-local.service ]] && \
        sed -i 's/forking/idle/g' /usr/lib/systemd/system/rc-local.service || true

    # ── Armbian 板级信息 ──
    if [[ -f /etc/armbian-release ]]; then
        sed -i 's/BOARD=odroidn2/BOARD=msm8916/g' /etc/armbian-release || true
        sed -i 's/BOARD_NAME="Odroid N2"/BOARD_NAME="MSM8916"/g' /etc/armbian-release || true
        log_ok "Armbian 板级信息已修改"
    fi

    # ── ZRAM ──
    if [[ -f /etc/default/armbian-zram-config ]]; then
        sed -i 's/# ZRAM_PERCENTAGE=50/ZRAM_PERCENTAGE=300/g' \
            /etc/default/armbian-zram-config || true
        sed -i 's/# MEM_LIMIT_PERCENTAGE=50/MEM_LIMIT_PERCENTAGE=300/g' \
            /etc/default/armbian-zram-config || true
        log_ok "ZRAM 配置已优化"
    fi

    # ── SIM 切换器 ──
    if [[ -f /usr/sbin/openstick-sim-changer.sh ]]; then
        sed -i '21s/$sim/sim:sel/' /usr/sbin/openstick-sim-changer.sh || true
    fi

    log_ok "系统配置完成"
}

# ================================================================
# BBR 拥塞控制算法配置
# 依赖内核编译时启用：
#   CONFIG_TCP_CONG_BBR=m
#   CONFIG_TCP_CONG_ADVANCED=y
#   CONFIG_NET_SCH_FQ=m
#   CONFIG_NET_SCH_FQ_CODEL=m
# ================================================================
setup_bbr() {
    log_info "配置 BBR 拥塞控制算法..."

    # ── 尝试加载内核模块（chroot 内可能失败，无妨）──
    modprobe tcp_bbr 2>/dev/null \
        && log_ok "tcp_bbr 模块加载成功" \
        || log_warn "tcp_bbr 模块暂未加载（首次启动后自动生效）"

    modprobe sch_fq 2>/dev/null \
        && log_ok "sch_fq 模块加载成功" \
        || log_warn "sch_fq 模块暂未加载（首次启动后自动生效）"

    # ── 设置开机自动加载模块 ──
    mkdir -p /etc/modules-load.d
    cat > /etc/modules-load.d/bbr.conf << 'EOF'
# BBR 拥塞控制 - 开机自动加载
tcp_bbr
sch_fq
EOF
    chmod 0644 /etc/modules-load.d/bbr.conf
    log_ok "开机自动加载模块已配置: /etc/modules-load.d/bbr.conf"

    # ── 写入 sysctl 持久化配置 ──
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-bbr.conf << 'EOF'
# BBR 拥塞控制算法 + FQ 调度器
# 依赖内核模块: tcp_bbr / sch_fq
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    chmod 0644 /etc/sysctl.d/99-bbr.conf
    log_ok "BBR sysctl 配置已写入: /etc/sysctl.d/99-bbr.conf"

    # ── chroot 内尝试立即生效（失败无妨，重启后必定生效）──
    sysctl -w net.core.default_qdisc=fq 2>/dev/null \
        && log_ok "net.core.default_qdisc=fq 已生效" || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null \
        && log_ok "net.ipv4.tcp_congestion_control=bbr 已生效" || true

    log_ok "BBR 配置完成，重启后自动生效"
}

clean_file() {
    log_info "清理 /boot..."
    mkdir -p /boot
    find /boot -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    log_ok "/boot 已清理"
}

enable_motd() {
    if [[ -d /etc/update-motd.d ]]; then
        find /etc/update-motd.d -maxdepth 1 -type f -exec chmod +x {} + 2>/dev/null || true
        log_ok "MOTD 已启用"
    fi
}

clean_apt_cache() {
    log_info "清理 APT 缓存..."
    rm -rf /var/lib/apt/lists/*
    apt-get clean
    log_ok "缓存已清理"
}

main() {
    require_root

    log_info "开始 chroot 构建（$(date '+%Y-%m-%d %H:%M:%S')）"
    log_info "包目录: ${PKGS_DIR}"
    ls -la "${PKGS_DIR}/" 2>/dev/null || log_warn "包目录不存在或为空"

    check_network       # 检查网络 + 修复 resolv.conf
    fix_tmp_permissions # 修复 /tmp 权限
    remove_package      # 移除冲突旧内核
    clean_file          # 清理 /boot
    install_package     # 安装内核 + 系统组件

    log_info "设置 iptables 后端..."
    update-alternatives --set iptables /usr/sbin/iptables-legacy \
        || log_warn "iptables 设置失败"

    set_language        # 配置中文 + UTF-8
    common_set          # 系统配置、SSH、时区、服务启用
    setup_bbr           # ★ BBR 拥塞控制算法
    enable_motd         # 启用 MOTD
    clean_apt_cache     # 清理 APT 缓存

    log_ok "chroot 构建全部完成！"
    log_info "════════════════════════════════════"
    log_info "时区: Asia/Chongqing (UTC+8)"
    log_info "BBR: 重启后自动生效"
    log_info "════════════════════════════════════"
}

main "$@"
