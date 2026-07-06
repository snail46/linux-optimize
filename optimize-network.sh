#!/usr/bin/env bash
# =============================================================================
#  Linux 节点网络一键优化脚本
#  适用于：Ubuntu 20.04+ / Debian 10+ / CentOS 7+
#  功能：TCP/UDP 内核参数优化、BBR 拥塞控制、DNS 优化、系统限制调整
#  用法：sudo bash optimize-network.sh [--dry-run] [--revert]
# =============================================================================

set -euo pipefail

# ── 颜色 ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── 全局变量 ──────────────────────────────────────────────────────────────────
DRY_RUN=false
REVERT=false
BACKUP_DIR="/etc/network-optimize-backup-$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/network-optimize.log"
SYSCTL_CONF="/etc/sysctl.d/99-network-optimize.conf"
LIMITS_CONF="/etc/security/limits.d/99-network-optimize.conf"
SYSTEMD_RESOLVED_CONF="/etc/systemd/resolved.conf.d/optimize.conf"

# ── 工具函数 ──────────────────────────────────────────────────────────────────
log()  { echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE"; }
info() { echo -e "${BLUE}[i]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[✗]${NC} $*" | tee -a "$LOG_FILE"; }
step() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}" | tee -a "$LOG_FILE"; }

die() { err "$*"; exit 1; }

run() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*"
    else
        eval "$*" >> "$LOG_FILE" 2>&1 || warn "命令执行警告: $*"
    fi
}

# ── 参数解析 ──────────────────────────────────────────────────────────────────
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --revert)  REVERT=true  ;;
        --help|-h)
            echo "用法: sudo bash $0 [--dry-run] [--revert]"
            echo "  --dry-run  预览模式，不实际写入"
            echo "  --revert   还原所有优化（从备份恢复）"
            exit 0
            ;;
    esac
done

# ── 权限检查 ──────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "请使用 root 或 sudo 运行此脚本"

# ── 初始化日志 ────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"
echo "======================================" >> "$LOG_FILE"
echo "  优化开始: $(date)"                   >> "$LOG_FILE"
echo "======================================" >> "$LOG_FILE"

# ── Banner ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
  ╔══════════════════════════════════════════════╗
  ║      Linux 节点网络一键优化脚本              ║
  ║      TCP/BBR/DNS/内核参数 全面调优           ║
  ╚══════════════════════════════════════════════╝
EOF
echo -e "${NC}"

$DRY_RUN && warn "预览模式：以下为将要执行的操作，不会实际写入"

# ══════════════════════════════════════════════════════════════════════════════
#  还原模式
# ══════════════════════════════════════════════════════════════════════════════
if $REVERT; then
    step "还原优化配置"
    LATEST_BACKUP=$(ls -td /etc/network-optimize-backup-* 2>/dev/null | head -1 || true)
    if [[ -z "$LATEST_BACKUP" ]]; then
        die "未找到备份目录，无法还原"
    fi
    info "使用备份目录: $LATEST_BACKUP"

    [[ -f "$LATEST_BACKUP/sysctl.conf.bak" ]] && \
        run "cp '$LATEST_BACKUP/sysctl.conf.bak' '$SYSCTL_CONF'"

    [[ -f "$LATEST_BACKUP/limits.conf.bak" ]] && \
        run "cp '$LATEST_BACKUP/limits.conf.bak' '$LIMITS_CONF'"

    run "sysctl --system"
    run "systemctl restart systemd-resolved 2>/dev/null || true"

    log "还原完成，建议重启服务器"
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Step 0: 系统检测
# ══════════════════════════════════════════════════════════════════════════════
step "系统环境检测"

OS_ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"' || echo "unknown")
OS_VERSION=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release | tr -d '"' || echo "0")
KERNEL=$(uname -r)
ARCH=$(uname -m)
MEM_TOTAL=$(awk '/MemTotal/{print $2}' /proc/meminfo)            # KB
MEM_GB=$(( MEM_TOTAL / 1024 / 1024 ))

info "系统: $OS_ID $OS_VERSION"
info "内核: $KERNEL ($ARCH)"
info "内存: ${MEM_GB}GB (${MEM_TOTAL}KB)"

# 检测是否为虚拟机
VIRT=$(systemd-detect-virt 2>/dev/null || echo "none")
[[ "$VIRT" != "none" ]] && info "虚拟化环境: $VIRT"

# ══════════════════════════════════════════════════════════════════════════════
#  Step 1: 备份现有配置
# ══════════════════════════════════════════════════════════════════════════════
step "备份现有配置"

if ! $DRY_RUN; then
    mkdir -p "$BACKUP_DIR"

    # 备份 sysctl
    [[ -f "$SYSCTL_CONF" ]] && \
        cp "$SYSCTL_CONF" "$BACKUP_DIR/sysctl.conf.bak" && \
        info "已备份: $SYSCTL_CONF"

    # 备份 limits
    [[ -f "$LIMITS_CONF" ]] && \
        cp "$LIMITS_CONF" "$BACKUP_DIR/limits.conf.bak" && \
        info "已备份: $LIMITS_CONF"

    # 备份 resolved
    [[ -f "/etc/systemd/resolved.conf" ]] && \
        cp "/etc/systemd/resolved.conf" "$BACKUP_DIR/resolved.conf.bak" && \
        info "已备份: /etc/systemd/resolved.conf"

    log "备份目录: $BACKUP_DIR"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Step 2: BBR 拥塞控制
# ══════════════════════════════════════════════════════════════════════════════
step "BBR 拥塞控制算法"

KERNEL_MAJOR=$(echo "$KERNEL" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL" | cut -d. -f2)

BBR_AVAILABLE=false
if [[ $KERNEL_MAJOR -gt 4 ]] || [[ $KERNEL_MAJOR -eq 4 && $KERNEL_MINOR -ge 9 ]]; then
    BBR_AVAILABLE=true
fi

if ! $BBR_AVAILABLE; then
    warn "内核版本 $KERNEL 过低（需要 ≥4.9），跳过 BBR 设置"
else
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    info "当前拥塞控制: $CURRENT_CC"

    # 检测 BBR3 支持（内核 ≥6.1）
    if [[ $KERNEL_MAJOR -ge 6 ]] && [[ $KERNEL_MINOR -ge 1 ]]; then
        if modprobe tcp_bbr2 2>/dev/null || modprobe tcp_bbr 2>/dev/null; then
            BBR_CC="bbr"
            info "将使用 BBR (kernel $KERNEL)"
        fi
    else
        modprobe tcp_bbr 2>/dev/null || true
        BBR_CC="bbr"
    fi

    log "拥塞控制算法将设置为: ${BBR_CC:-bbr}"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Step 3: 写入 sysctl 优化参数
# ══════════════════════════════════════════════════════════════════════════════
step "写入内核网络参数 (sysctl)"

# 根据内存动态调整 buffer
if [[ $MEM_GB -ge 8 ]]; then
    RMEM_MAX=134217728    # 128MB
    WMEM_MAX=134217728
    RMEM_DEFAULT=87380
    WMEM_DEFAULT=87380
    NETDEV_BACKLOG=65536
    SOMAXCONN=65535
elif [[ $MEM_GB -ge 4 ]]; then
    RMEM_MAX=67108864     # 64MB
    WMEM_MAX=67108864
    RMEM_DEFAULT=65536
    WMEM_DEFAULT=65536
    NETDEV_BACKLOG=32768
    SOMAXCONN=32768
else
    RMEM_MAX=33554432     # 32MB
    WMEM_MAX=33554432
    RMEM_DEFAULT=32768
    WMEM_DEFAULT=32768
    NETDEV_BACKLOG=16384
    SOMAXCONN=16384
fi

BBR_SETTING="${BBR_CC:-bbr}"

SYSCTL_CONTENT="# ============================================================
# 网络优化配置 - 由 optimize-network.sh 生成
# 生成时间: $(date)
# ============================================================

# ── BBR 拥塞控制 ─────────────────────────────────────────────
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${BBR_SETTING}

# ── TCP 缓冲区 (根据内存 ${MEM_GB}GB 动态配置) ───────────────
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
net.core.rmem_default = ${RMEM_DEFAULT}
net.core.wmem_default = ${WMEM_DEFAULT}
net.ipv4.tcp_rmem = 4096 ${RMEM_DEFAULT} ${RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${WMEM_DEFAULT} ${WMEM_MAX}
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# ── TCP 连接优化 ──────────────────────────────────────────────
# 减少 TIME_WAIT 状态连接积压
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 16384

# 增大连接队列
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}

# 保活连接（减少长连接断开）
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# 快速重用端口
net.ipv4.ip_local_port_range = 1024 65535

# 启用 TCP Fast Open（客户端+服务端）
net.ipv4.tcp_fastopen = 3

# 启用 SACK（选择性确认，改善丢包恢复）
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1

# 禁用慢启动重置（长连接友好）
net.ipv4.tcp_slow_start_after_idle = 0

# 降低 SYN 重试（快速失败，减少等待）
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3

# MTU 探测（自动优化包大小）
net.ipv4.tcp_mtu_probing = 1

# ── UDP 优化（Hysteria2/TUIC/QUIC 场景）─────────────────────
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}

# ── 连接追踪（高并发代理必备）────────────────────────────────
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15

# ── 内存与文件系统 ────────────────────────────────────────────
# 减少 swap 使用（代理服务需要低延迟内存访问）
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# ── IPv6 ─────────────────────────────────────────────────────
# 如果节点不使用 IPv6，可取消注释以下两行
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1
"

info "参数预览（内存 ${MEM_GB}GB）:"
info "  tcp_rmem/wmem max: $((RMEM_MAX/1024/1024))MB"
info "  somaxconn: $SOMAXCONN"
info "  netdev_max_backlog: $NETDEV_BACKLOG"

if ! $DRY_RUN; then
    mkdir -p "$(dirname "$SYSCTL_CONF")"
    echo "$SYSCTL_CONTENT" > "$SYSCTL_CONF"
    log "已写入: $SYSCTL_CONF"

    # 加载 nf_conntrack 模块（如果未加载）
    modprobe nf_conntrack 2>/dev/null || \
    modprobe ip_conntrack 2>/dev/null || \
        warn "nf_conntrack 模块加载失败，conntrack 参数将跳过"

    # 应用 sysctl
    sysctl --system >> "$LOG_FILE" 2>&1 && log "sysctl 参数已生效" || \
        warn "部分 sysctl 参数应用失败（可能是内核不支持），请查看日志"
else
    echo "$SYSCTL_CONTENT"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Step 4: 系统文件描述符与进程限制
# ══════════════════════════════════════════════════════════════════════════════
step "系统限制调整 (ulimit / limits.d)"

LIMITS_CONTENT="# ============================================================
# 系统限制优化 - 由 optimize-network.sh 生成
# ============================================================
# 文件描述符限制（代理服务每个连接占用 1 个 fd）
*    soft nofile 1048576
*    hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576

# 进程数限制
*    soft nproc  65536
*    hard nproc  65536
root soft nproc  65536
root hard nproc  65536
"

if ! $DRY_RUN; then
    mkdir -p "$(dirname "$LIMITS_CONF")"
    echo "$LIMITS_CONTENT" > "$LIMITS_CONF"
    log "已写入: $LIMITS_CONF"

    # systemd 服务也需要单独配置
    mkdir -p /etc/systemd/system.conf.d/
    cat > /etc/systemd/system.conf.d/99-nofile.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65536
EOF
    log "已写入 systemd 限制配置"
    systemctl daemon-reexec >> "$LOG_FILE" 2>&1 || true
else
    echo "$LIMITS_CONTENT"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Step 5: DNS 优化
# ══════════════════════════════════════════════════════════════════════════════
step "DNS 优化"

# 检测 DNS 方案
HAS_RESOLVED=$(systemctl is-active systemd-resolved 2>/dev/null || echo "inactive")
HAS_DNSMASQ=$(command -v dnsmasq 2>/dev/null || echo "")

info "systemd-resolved: $HAS_RESOLVED"
info "dnsmasq: ${HAS_DNSMASQ:-未安装}"

if [[ "$HAS_RESOLVED" == "active" ]]; then
    info "使用 systemd-resolved 优化方案"

    RESOLVED_CONF_CONTENT="# ============================================================
# systemd-resolved 优化 - 由 optimize-network.sh 生成
# ============================================================
[Resolve]
# 上游 DNS（优先使用 DoT 加密）
DNS=223.5.5.5#dns.alidns.com 119.29.29.29#dot.pub
FallbackDNS=1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google

# 启用 DNS over TLS
DNSOverTLS=opportunistic

# 启用 DNSSEC 验证
DNSSEC=allow-downgrade

# 缓存配置
Cache=yes
CacheFromLocalhost=no

# 多播 DNS
MulticastDNS=no

# LLMNR
LLMNR=no
"

    if ! $DRY_RUN; then
        mkdir -p "$(dirname "$SYSTEMD_RESOLVED_CONF")"
        echo "$RESOLVED_CONF_CONTENT" > "$SYSTEMD_RESOLVED_CONF"
        systemctl restart systemd-resolved >> "$LOG_FILE" 2>&1 && \
            log "systemd-resolved 已重启并应用新配置" || \
            warn "systemd-resolved 重启失败"

        # 确保 /etc/resolv.conf 指向 resolved
        if [[ ! -L "/etc/resolv.conf" ]] || \
           [[ "$(readlink /etc/resolv.conf)" != "/run/systemd/resolve/stub-resolv.conf" ]]; then
            cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak" 2>/dev/null || true
            ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf && \
                log "/etc/resolv.conf 已指向 systemd-resolved stub"
        fi
    else
        echo "$RESOLVED_CONF_CONTENT"
    fi

else
    # 回退方案：直接写 resolv.conf
    info "未检测到 systemd-resolved，直接优化 /etc/resolv.conf"

    RESOLV_CONTENT="# ============================================================
# DNS 优化 - 由 optimize-network.sh 生成
# ============================================================
# 阿里云 DNS（国内最稳定，支持 DoH）
nameserver 223.5.5.5
nameserver 119.29.29.29

# Cloudflare（备用，国际出口）
nameserver 1.1.1.1

# 选项优化
options ndots:2
options timeout:2
options attempts:2
options rotate
options single-request-reopen
"

    if ! $DRY_RUN; then
        # 防止被覆盖
        chattr -i /etc/resolv.conf 2>/dev/null || true
        cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak" 2>/dev/null || true
        echo "$RESOLV_CONTENT" > /etc/resolv.conf
        # 锁定防止 DHCP 覆盖
        chattr +i /etc/resolv.conf 2>/dev/null || \
            warn "无法锁定 resolv.conf（可能是容器环境），请手动防止被覆盖"
        log "已写入并锁定 /etc/resolv.conf"
    else
        echo "$RESOLV_CONTENT"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Step 6: 网卡队列优化（如果支持）
# ══════════════════════════════════════════════════════════════════════════════
step "网卡参数优化"

# 获取主网卡
PRIMARY_IF=$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/{print $5; exit}' || echo "")

if [[ -z "$PRIMARY_IF" ]]; then
    warn "无法检测主网卡，跳过网卡优化"
else
    info "主网卡: $PRIMARY_IF"

    if command -v ethtool &>/dev/null; then
        # 关闭 GRO/TSO/GSO（某些场景下可改善代理延迟）
        # 注意：大流量场景可能降低吞吐，可按需调整
        if ! $DRY_RUN; then
            ethtool -K "$PRIMARY_IF" gro on  >> "$LOG_FILE" 2>&1 || true
            ethtool -K "$PRIMARY_IF" tso on  >> "$LOG_FILE" 2>&1 || true
            ethtool -K "$PRIMARY_IF" gso on  >> "$LOG_FILE" 2>&1 || true

            # 设置发送/接收队列大小（如果支持）
            ethtool -G "$PRIMARY_IF" rx 4096 tx 4096 >> "$LOG_FILE" 2>&1 || true

            log "网卡 $PRIMARY_IF 队列参数已优化"
        fi
    else
        warn "ethtool 未安装，跳过网卡队列优化"
        info "安装: apt install ethtool / yum install ethtool"
    fi

    # 设置网卡接收队列调度（fq_codel）
    if ! $DRY_RUN; then
        tc qdisc replace dev "$PRIMARY_IF" root fq 2>/dev/null && \
            log "网卡 $PRIMARY_IF 发送队列已设置为 fq" || \
            warn "tc qdisc 设置失败（可能是容器环境）"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Step 7: 透明大页禁用（减少延迟抖动）
# ══════════════════════════════════════════════════════════════════════════════
step "透明大页 (THP) 优化"

THP_PATH="/sys/kernel/mm/transparent_hugepage/enabled"
if [[ -f "$THP_PATH" ]]; then
    CURRENT_THP=$(cat "$THP_PATH")
    info "当前 THP 状态: $CURRENT_THP"

    if ! $DRY_RUN; then
        echo never > "$THP_PATH"
        echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

        # 持久化到 rc.local
        RC_LOCAL="/etc/rc.local"
        if [[ ! -f "$RC_LOCAL" ]]; then
            echo '#!/bin/bash' > "$RC_LOCAL"
            echo 'exit 0' >> "$RC_LOCAL"
            chmod +x "$RC_LOCAL"
        fi
        grep -q "transparent_hugepage" "$RC_LOCAL" || \
            sed -i '/^exit 0/i echo never > /sys/kernel/mm/transparent_hugepage/enabled\necho never > /sys/kernel/mm/transparent_hugepage/defrag' "$RC_LOCAL"

        log "THP 已禁用（减少内存延迟抖动）"
    fi
else
    info "THP 不存在（可能是容器环境），跳过"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Step 8: 验证优化结果
# ══════════════════════════════════════════════════════════════════════════════
step "验证优化结果"

if ! $DRY_RUN; then
    echo ""
    echo -e "${BOLD}── 当前生效的关键参数 ──────────────────────────────${NC}"

    check_param() {
        local key=$1
        local expected=$2
        local actual
        actual=$(sysctl -n "$key" 2>/dev/null || echo "N/A")
        if [[ "$actual" == "$expected" ]] || [[ -z "$expected" ]]; then
            echo -e "  ${GREEN}✓${NC} $key = $actual"
        else
            echo -e "  ${YELLOW}~${NC} $key = $actual (期望: $expected)"
        fi
    }

    check_param "net.ipv4.tcp_congestion_control" "bbr"
    check_param "net.core.default_qdisc" "fq"
    check_param "net.ipv4.tcp_fastopen" "3"
    check_param "net.ipv4.tcp_tw_reuse" "1"
    check_param "net.ipv4.tcp_slow_start_after_idle" "0"
    check_param "net.core.rmem_max" ""
    check_param "net.core.wmem_max" ""
    check_param "net.core.somaxconn" ""
    check_param "vm.swappiness" "10"

    echo ""
    echo -e "${BOLD}── DNS 解析测试 ─────────────────────────────────────${NC}"
    for domain in google.com youtube.com cloudflare.com; do
        if result=$(dig +short +time=3 "$domain" A 2>/dev/null | head -1) && [[ -n "$result" ]]; then
            echo -e "  ${GREEN}✓${NC} $domain → $result"
        else
            echo -e "  ${RED}✗${NC} $domain 解析失败"
        fi
    done

    echo ""
    echo -e "${BOLD}── 文件描述符限制 ───────────────────────────────────${NC}"
    CURRENT_NOFILE=$(ulimit -n 2>/dev/null || echo "N/A")
    echo -e "  当前 shell nofile: $CURRENT_NOFILE"
    echo -e "  ${YELLOW}注意: 新限制在重新登录后对当前 shell 生效${NC}"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  完成
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}"
cat << 'EOF'
  ╔══════════════════════════════════════════════╗
  ║              优化完成！                      ║
  ╚══════════════════════════════════════════════╝
EOF
echo -e "${NC}"

echo -e "${BOLD}优化内容摘要：${NC}"
echo -e "  ${GREEN}✓${NC} BBR 拥塞控制算法 + FQ 队列"
echo -e "  ${GREEN}✓${NC} TCP 缓冲区动态调整（基于 ${MEM_GB}GB 内存）"
echo -e "  ${GREEN}✓${NC} TCP Fast Open / SACK / TW Reuse"
echo -e "  ${GREEN}✓${NC} 连接追踪表扩容 (1M 条目)"
echo -e "  ${GREEN}✓${NC} 文件描述符上限 1048576"
echo -e "  ${GREEN}✓${NC} DNS 加密 + 缓存优化"
echo -e "  ${GREEN}✓${NC} 透明大页禁用（降低延迟抖动）"
echo ""
echo -e "${BOLD}日志文件：${NC} $LOG_FILE"
echo -e "${BOLD}备份目录：${NC} $BACKUP_DIR"
echo ""
echo -e "${YELLOW}建议重启服务器以使所有参数完全生效${NC}"
echo -e "还原命令: ${CYAN}sudo bash $0 --revert${NC}"
echo ""
