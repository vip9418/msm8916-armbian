#!/bin/bash
set -euo pipefail
readonly PKGS_DIR="/tmp/local_packages"
readonly LOG_FILE="/tmp/chroot-build.log"

log_info() { echo "🚀 $*"; echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $*" >> "${LOG_FILE}"; }
log_ok()   { echo "✅ $*"; echo "$(date '+%Y-%m-%d %H:%M:%S') [OK] $*" >> "${LOG_FILE}"; }
log_warn() { echo "⚠️  $*"; echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] $*" >> "${LOG_FILE}"; }
log_err()  { echo "❌ $*" >&2; echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" >> "${LOG_FILE}"; }

setup_dns() {
    log_info "配置 DNS（修复 Bookworm 符号链接问题）..."

    # 为 systemd-resolved 预创建目标路径
    mkdir -p /run/systemd/resolve

    # 写入 stub 目标文件（符号链接的真实目标）
    printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 8.8.8.8\n' \
        > /run/systemd/resolve/stub-resolv.conf

    # 强制删除符号链接（无论是损坏的还是正常的），写入真实文件
    rm -f /etc/resolv.conf
    printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\nnameserver 8.8.8.8\n' \
        > /etc/resolv.conf

    log_ok "DNS 已配置（真实文件，非符号链接）"
}

# ==================== 网络诊断 ====================
check_network() {
    log_info "检查 chroot 网络环境..."

    setup_dns

    if [[ -f /proc/net/dev ]]; then
        log_info "网络接口:"
        grep -E "eth|wlan|usb|enp" /proc/net/dev | sed 's/^/  /' || log_warn "无常见网络接口"
    fi

    log_info "当前 DNS 配置:"
    cat /etc/resolv.conf | sed 's/^/  /'

    if ping -c 1 -W 3 223.5.5.5 >/dev/null 2>&1; then
        log_ok "网络连通（IP层）"
    else
        log_warn "IP层无法连通，继续尝试..."
    fi

    if ping -c 1 -W 3 mirrors.aliyun.com >/dev/null 2>&1; then
        log_ok "DNS 解析正常"
    else
        log_warn "DNS 解析失败，已使用备用 DNS，继续..."
    fi
}

# ==================== 权限修复 ====================
fix_tmp_permissions() {
    log_info "修复 /tmp 权限..."
    chmod 1777 /tmp
    if ! touch /tmp/.apt-test 2>/dev/null; then
        log_err "/tmp 不可写！"
        exit 1
    fi
    rm -f /tmp/.apt-test
    log_ok "/tmp 权限正常"
}

# ==================== 包管理 ====================
install_package() {
    log_info "配置软件源..."

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO_ID="${ID:-debian}"
        CODENAME="${VERSION_CODENAME:-trixie}"
        log_info "发行版: ${DISTRO_ID} | 代号: ${CODENAME}"

        if [ "${DISTRO_ID}" = "ubuntu" ]; then
            cat > /etc/apt/sources.list << APT_EOF
deb http://mirrors.aliyun.com/ubuntu-ports/ ${CODENAME} main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu-ports/ ${CODENAME}-updates main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu-ports/ ${CODENAME}-backports main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu-ports/ ${CODENAME}-security main restricted universe multiverse
APT_EOF
        else
            cat > /etc/apt/sources.list << APT_EOF
deb http://mirrors.aliyun.com/debian ${CODENAME} main contrib non-free non-free-firmware
deb http://mirrors.aliyun.com/debian ${CODENAME}-updates main contrib non-free non-free-firmware
deb http://mirrors.aliyun.com/debian-security ${CODENAME}-security main contrib non-free non-free-firmware
APT_EOF
        fi
    else
        log_warn "/etc/os-release 丢失，使用 Debian Trixie 默认源"
        cat > /etc/apt/sources.list << 'APT_EOF'
deb http://mirrors.aliyun.com/debian trixie main contrib non-free non-free-firmware
deb http://mirrors.aliyun.com/debian trixie-updates main contrib non-free non-free-firmware
deb http://mirrors.aliyun.com/debian-security trixie-security main contrib non-free non-free-firmware
APT_EOF
    fi

    log_info "更新软件源..."
    if ! apt-get update; then
        log_warn "apt update 失败，重新修复 DNS 后重试..."
        setup_dns
        apt-get update || {
            log_err "apt update 仍然失败"
            exit 1
        }
    fi

    # ★ 修复：安装本地包的路径改为 PKGS_DIR（/tmp/local_packages）
    log_info "安装本地 deb 包（路径: ${PKGS_DIR}）..."
    if ls "${PKGS_DIR}"/*.deb >/dev/null 2>&1; then
        dpkg -i "${PKGS_DIR}"/*.deb 2>/dev/null || true
        log_ok "本地 deb 包安装完成"
    else
        log_warn "未在 ${PKGS_DIR} 找到任何 deb 包"
        ls -la "${PKGS_DIR}/" || true
    fi

    # ★ 每次 apt/dpkg 操作后立即修复 resolv.conf（防止被 postinst 改回符号链接）
    setup_dns

    log_info "联网修复本地包依赖（第一轮）..."
    apt-get --fix-broken install -y
    setup_dns

    log_info "安装核心网络组件..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        coreutils \
        network-manager \
        modemmanager \
        bc \
        bsdmainutils \
        gawk \
        locales \
        libqmi-utils \
        dnsmasq-base \
        iptables-persistent
    setup_dns

    log_info "安装 openstick-utils（如果存在）..."
    if ls "${PKGS_DIR}"/openstick-utils*.deb >/dev/null 2>&1; then
        dpkg -i "${PKGS_DIR}"/openstick-utils*.deb || true
        apt-get --fix-broken install -y
        setup_dns
    fi

    log_info "最终依赖修复确认（第二轮）..."
    apt-get --fix-broken install -y

    log_ok "全部包安装完成"
}

remove_package() {
    log_info "移除冲突包..."
    local pkgs
    pkgs=$(dpkg -l 2>/dev/null | grep -E "meson|linux-image" | awk '{print $2}' || true)
    if [[ -n "${pkgs}" ]]; then
        echo "${pkgs}" | xargs -r dpkg -P
        log_ok "已移除: ${pkgs}"
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

    for pair in "${files[@]}"; do
        local src="${pair%%:*}"
        local dst="${pair##*:}"
        if [[ -f "${src}" ]]; then
            cp "${src}" "${dst}"
            chmod +x "${dst}" 2>/dev/null || true
            log_ok "已注入: ${dst}"
        else
            log_warn "源文件不存在，跳过: ${src}"
        fi
    done

    log_info "启用开机自启服务..."

    if [[ -f /usr/lib/systemd/system/mobian-setup-usb-network.service ]]; then
        systemctl enable mobian-setup-usb-network.service || log_warn "enable mobian-setup-usb-network 失败"
        log_ok "mobian-setup-usb-network.service 已启用（USB RNDIS 网络）"
    else
        log_warn "mobian-setup-usb-network.service 不存在，USB 网络将无法工作！"
    fi

    if [[ -f /usr/lib/systemd/system/btrfs-compress.service ]]; then
        systemctl enable btrfs-compress.service || log_warn "enable btrfs-compress 失败"
        log_ok "btrfs-compress.service 已启用"
    fi

clean_file() {
    log_info "清理 /boot..."
    rm -rf /boot && mkdir -p /boot
    log_ok "/boot 已重建"
}

enable_motd() {
    if [[ -d /etc/update-motd.d ]]; then
        chmod +x /etc/update-motd.d/* 2>/dev/null || true
        log_ok "MOTD 已启用"
    fi
}

clean_apt_cache() {
    log_info "清理 APT 缓存..."
    rm -rf /var/lib/apt/lists/*
    apt-get clean all
    log_ok "缓存已清理"
}

# ==================== 主流程 ====================
main() {
    log_info "开始 chroot 构建（版本: $(date '+%Y-%m-%d %H:%M:%S')）"
    log_info "包目录: ${PKGS_DIR}"
    ls -la "${PKGS_DIR}/" 2>/dev/null || log_warn "包目录不存在或为空"

    check_network       # ★ 内部已调用 setup_dns，进入即修复 resolv.conf
    fix_tmp_permissions
    remove_package
    clean_file
    install_package

    log_info "设置 iptables 后端..."
    update-alternatives --set iptables /usr/sbin/iptables-legacy || log_warn "iptables 设置失败"

    set_language
    common_set
    enable_motd
    clean_apt_cache

    log_ok "chroot 构建全部完成！"
}

main "$@"
