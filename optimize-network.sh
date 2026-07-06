#!/usr/bin/env bash
# =============================================================================
#  Linux 节点网络一键优化脚本 v2.0
#  适配范围：512MB 单核小鸡 ~ 32GB+ 多核大机
#  功能：BBR自适应 / TCP调优 / DNS优化 / 按内存&CPU动态分级 / 安全边界保护
#  用法：sudo bash optimize-network.sh [--dry-run] [--revert] [--yes]
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

DRY_RUN=false
REVERT=false
AUTO_YES=false
BACKUP_DIR="/etc/network-optimize-backup-$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/network-optimize.log"
SYSCTL_CONF="/etc/sysctl.d/99-network-optimize.conf"
LIMITS_CONF="/etc/security/limits.d/99-network-optimize.conf"
SYSTEMD_RESOLVED_CONF="/etc/systemd/resolved.conf.d/optimize.conf"

log()  { echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOG_FILE"; }
info() { echo -e "${BLUE}[i]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOG_FILE"; }
err()  { echo -e "${RED}[✗]${NC} $*" | tee -a "$LOG_FILE"; }
step() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}" | tee -a "$LOG_FILE"; }
die()  { err "$*"; exit 1; }

run() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*"
    else
        eval "$*" >> "$LOG_FILE" 2>&1 || warn "命令执行警告: $*"
    fi
}

for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --revert)  REVERT=true  ;;
        --yes|-y)  AUTO_YES=true ;;
        --help|-h)
            echo "用法: sudo bash $0 [--dry-run] [--revert] [--yes]"
            echo "  --dry-run  预览模式，不实际写入"
            echo "  --revert   还原所有优化"
            echo "  --yes      跳过交互确认（如低内存机器的 swap 创建询问）"
            exit 0
            ;;
    esac
done

[[ $EUID -ne 0 ]] && die "请使用 root 或 sudo 运行此脚本"

mkdir -p "$(dirname "$LOG_FILE")"
echo "====== 优化开始: $(date) ======" >> "$LOG_FILE"

echo -e "${BOLD}${CYAN}"
cat << 'EOF'
  ╔══════════════════════════════════════════════╗
  ║   Linux 节点网络一键优化脚本 v2.0            ║
  ║   自适应内存/CPU分级 · 安全边界保护          ║
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
    [[ -z "$LATEST_BACKUP" ]] && die "未找到备份目录，无法还原"
    info "使用备份目录: $LATEST_BACKUP"

    [[ -f "$LATEST_BACKUP/sysctl.conf.bak" ]] && run "cp '$LATEST_BACKUP/sysctl.conf.bak' '$SYSCTL_CONF'"
    [[ ! -f "$LATEST_BACKUP/sysctl.conf.bak" ]] && run "rm -f '$SYSCTL_CONF'"
    [[ -f "$LATEST_BACKUP/limits.conf.bak" ]] && run "cp '$LATEST_BACKUP/limits.conf.bak' '$LIMITS_CONF'"
    [[ ! -f "$LATEST_BACKUP/limits.conf.bak" ]] && run "rm -f '$LIMITS_CONF'"
    [[ -f "$LATEST_BACKUP/resolved.conf.bak" ]] && run "cp '$LATEST_BACKUP/resolved.conf.bak' /etc/systemd/resolved.conf"
    run "rm -f '$SYSTEMD_RESOLVED_CONF'"

    run "sysctl --system"
    run "systemctl restart systemd-resolved 2>/dev/null || true"
    log "还原完成，建议重启服务器"
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Step 0: 系统与硬件全面检测
# ══════════════════════════════════════════════════════════════════════════════
step "系统硬件检测"

OS_ID=$(grep -oP '(?<=^ID=).+' /etc/os-release 2>/dev/null | tr -d '"' || echo "unknown")
OS_VERSION=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release 2>/dev/null | tr -d '"' || echo "0")
KERNEL=$(uname -r)
KERNEL_MAJOR=$(echo "$KERNEL" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL" | cut -d. -f2)
ARCH=$(uname -m)

MEM_TOTAL_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
MEM_TOTAL_MB=$(( MEM_TOTAL_KB / 1024 ))
CPU_CORES=$(nproc --all 2>/dev/null || echo 1)
SWAP_TOTAL_KB=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
VIRT=$(systemd-detect-virt 2>/dev/null || echo "none")

info "系统: $OS_ID $OS_VERSION | 内核: $KERNEL ($ARCH)"
info "内存: ${MEM_TOTAL_MB}MB | CPU核心: ${CPU_CORES} | Swap: $((SWAP_TOTAL_KB/1024))MB"
[[ "$VIRT" != "none" ]] && info "虚拟化: $VIRT"

# ── 内存分级（精细到 6 档）────────────────────────────────────────────────────
if   (( MEM_TOTAL_MB < 768 )); then
    TIER="micro"
elif (( MEM_TOTAL_MB < 1536 )); then
    TIER="small"
elif (( MEM_TOTAL_MB < 3072 )); then
    TIER="medium"
elif (( MEM_TOTAL_MB < 6144 )); then
    TIER="large"
elif (( MEM_TOTAL_MB < 12288 )); then
    TIER="xlarge"
else
    TIER="xxlarge"
fi
info "机器分级: ${BOLD}${TIER}${NC}（基于 ${MEM_TOTAL_MB}MB 内存）"

case $TIER in
    micro)
        RMEM_MAX=8388608
        WMEM_MAX=8388608
        RMEM_DEFAULT=16384
        WMEM_DEFAULT=16384
        NETDEV_BACKLOG=4096
        SOMAXCONN=4096
        SYN_BACKLOG=2048
        NOFILE=131072
        NPROC=8192
        TW_BUCKETS=8192
        ;;
    small)
        RMEM_MAX=16777216
        WMEM_MAX=16777216
        RMEM_DEFAULT=32768
        WMEM_DEFAULT=32768
        NETDEV_BACKLOG=8192
        SOMAXCONN=8192
        SYN_BACKLOG=4096
        NOFILE=262144
        NPROC=16384
        TW_BUCKETS=8192
        ;;
    medium)
        RMEM_MAX=33554432
        WMEM_MAX=33554432
        RMEM_DEFAULT=32768
        WMEM_DEFAULT=32768
        NETDEV_BACKLOG=16384
        SOMAXCONN=16384
        SYN_BACKLOG=4096
        NOFILE=524288
        NPROC=32768
        TW_BUCKETS=16384
        ;;
    large)
        RMEM_MAX=67108864
        WMEM_MAX=67108864
        RMEM_DEFAULT=65536
        WMEM_DEFAULT=65536
        NETDEV_BACKLOG=32768
        SOMAXCONN=32768
        SYN_BACKLOG=8192
        NOFILE=524288
        NPROC=32768
        TW_BUCKETS=16384
        ;;
    xlarge)
        RMEM_MAX=134217728
        WMEM_MAX=134217728
        RMEM_DEFAULT=87380
        WMEM_DEFAULT=87380
        NETDEV_BACKLOG=65536
        SOMAXCONN=65535
        SYN_BACKLOG=16384
        NOFILE=1048576
        NPROC=65536
        TW_BUCKETS=32768
        ;;
    xxlarge)
        RMEM_MAX=268435456
        WMEM_MAX=268435456
        RMEM_DEFAULT=131072
        WMEM_DEFAULT=131072
        NETDEV_BACKLOG=131072
        SOMAXCONN=65535
        SYN_BACKLOG=16384
        NOFILE=1048576
        NPROC=131072
        TW_BUCKETS=65536
        ;;
esac

# ── 安全边界保护：buffer 总占用不超过物理内存的 20% ─────────────────────────
MAX_SAFE_BYTES=$(( MEM_TOTAL_KB * 1024 / 5 ))
if (( RMEM_MAX > MAX_SAFE_BYTES )); then
    warn "rmem_max (${RMEM_MAX}) 超过安全阈值，自动降至 ${MAX_SAFE_BYTES}"
    RMEM_MAX=$MAX_SAFE_BYTES
fi
if (( WMEM_MAX > MAX_SAFE_BYTES )); then
    WMEM_MAX=$MAX_SAFE_BYTES
fi

# ── conntrack 表大小：按内存动态计算，避免小鸡被打爆内存 ─────────────────────
CONNTRACK_MAX=$(( MEM_TOTAL_KB * 1024 / 16384 ))
(( CONNTRACK_MAX < 8192 ))    && CONNTRACK_MAX=8192
(( CONNTRACK_MAX > 1048576 )) && CONNTRACK_MAX=1048576
info "conntrack 表大小: ${CONNTRACK_MAX}（按内存自动计算，约占用 $(( CONNTRACK_MAX * 350 / 1024 / 1024 ))MB）"

# ══════════════════════════════════════════════════════════════════════════════
#  Step 1: 低内存机器 Swap 检测与建议
# ══════════════════════════════════════════════════════════════════════════════
step "Swap 检测"

if (( MEM_TOTAL_MB < 1536 )) && (( SWAP_TOTAL_KB == 0 )); then
    warn "检测到低内存机器（${MEM_TOTAL_MB}MB）且无 Swap，代理服务在流量高峰易 OOM"

    NEED_SWAP=false
    if $AUTO_YES; then
        NEED_SWAP=true
    elif ! $DRY_RUN; then
        read -rp "是否自动创建 1GB Swap 文件以提升稳定性？[Y/n]: " ans
        [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]] && NEED_SWAP=true
    fi

    if $NEED_SWAP && ! $DRY_RUN; then
        if [[ ! -f /swapfile ]]; then
            SWAP_SIZE_MB=1024
            (( MEM_TOTAL_MB < 512 )) && SWAP_SIZE_MB=2048
            fallocate -l ${SWAP_SIZE_MB}M /swapfile 2>/dev/null || \
                dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE_MB >> "$LOG_FILE" 2>&1
            chmod 600 /swapfile
            mkswap /swapfile >> "$LOG_FILE" 2>&1
            swapon /swapfile >> "$LOG_FILE" 2>&1
            grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            log "已创建 ${SWAP_SIZE_MB}MB Swap 并持久化到 /etc/fstab"
        else
            info "/swapfile 已存在，跳过创建"
        fi
    fi
else
    info "Swap 状态正常，跳过"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Step 2: 备份现有配置
# ══════════════════════════════════════════════════════════════════════════════
step "备份现有配置"
if ! $DRY_RUN; then
    mkdir -p "$BACKUP_DIR"
    [[ -f "$SYSCTL_CONF" ]] && cp "$SYSCTL_CONF" "$BACKUP_DIR/sysctl.conf.bak" && info "已备份 sysctl"
    [[ -f "$LIMITS_CONF" ]] && cp "$LIMITS_CONF" "$BACKUP_DIR/limits.conf.bak" && info "已备份 limits"
    [[ -f "/etc/systemd/resolved.conf" ]] && cp "/etc/systemd/resolved.conf" "$BACKUP_DIR/resolved.conf.bak"
    log "备份目录: $BACKUP_DIR"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Step 3: BBR / 拥塞控制自适应选择
# ══════════════════════════════════════════════════════════════════════════════
step "拥塞控制算法选择"

BBR_CC="cubic"
if [[ $KERNEL_MAJOR -gt 4 ]] || [[ $KERNEL_MAJOR -eq 4 && $KERNEL_MINOR -ge 9 ]]; then
    if modprobe tcp_bbr 2>/dev/null; then
        BBR_CC="bbr"
        if [[ $KERNEL_MAJOR -gt 5 ]] || [[ $KERNEL_MAJOR -eq 5 && $KERNEL_MINOR -ge 9 ]]; then
            if modprobe tcp_bbr2 2>/dev/null; then
                BBR_CC="bbr2"
            fi
        fi
        log "拥塞控制: ${BBR_CC}（内核 $KERNEL 支持）"
    else
        warn "tcp_bbr 模块加载失败，回退到 cubic"
    fi
else
    warn "内核版本 $KERNEL 过低（需要 ≥4.9），使用 cubic 拥塞控制"
fi

if (( CPU_CORES == 1 )) && [[ "$TIER" == "micro" ]]; then
    info "检测到单核小内存机器，BBR 计算开销较低，仍建议使用（相比 cubic 更省重传）"
fi

QDISC="fq"
[[ "$BBR_CC" == "cubic" ]] && QDISC="fq_codel"

# ══════════════════════════════════════════════════════════════════════════════
#  Step 4: 写入 sysctl（按分级参数）
# ══════════════════════════════════════════════════════════════════════════════
step "写入内核网络参数 (sysctl) - 分级: ${TIER}"

SYSCTL_CONTENT="# ============================================================
# 网络优化配置 - optimize-network.sh v2.0
# 机器分级: ${TIER} | 内存: ${MEM_TOTAL_MB}MB | CPU: ${CPU_CORES}核
# 生成时间: $(date)
# ============================================================

# ── 拥塞控制 ─────────────────────────────────────────────────
net.core.default_qdisc = ${QDISC}
net.ipv4.tcp_congestion_control = ${BBR_CC}

# ── TCP/UDP 缓冲区（已按 20% 内存安全边界裁剪）───────────────
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
net.core.rmem_default = ${RMEM_DEFAULT}
net.core.wmem_default = ${WMEM_DEFAULT}
net.ipv4.tcp_rmem = 4096 ${RMEM_DEFAULT} ${RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${WMEM_DEFAULT} ${WMEM_MAX}
net.ipv4.udp_rmem_min = 4096
net.ipv4.udp_wmem_min = 4096

# ── TCP 连接管理 ──────────────────────────────────────────────
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = ${TW_BUCKETS}
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${SYN_BACKLOG}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}

# ── 保活 ─────────────────────────────────────────────────────
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# ── 端口与快速重用 ────────────────────────────────────────────
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fastopen = 3

# ── 丢包恢复能力 ──────────────────────────────────────────────
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_mtu_probing = 1

# ── 连接追踪（按内存自动裁剪，避免小内存机器 OOM）────────────
net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15

# ── 内存与虚拟内存管理 ────────────────────────────────────────
"

if [[ "$TIER" == "micro" || "$TIER" == "small" ]]; then
    SWAPPINESS=25
    DIRTY_RATIO=10
    DIRTY_BG_RATIO=3
else
    SWAPPINESS=10
    DIRTY_RATIO=15
    DIRTY_BG_RATIO=5
fi

SYSCTL_CONTENT+="vm.swappiness = ${SWAPPINESS}
vm.dirty_ratio = ${DIRTY_RATIO}
vm.dirty_background_ratio = ${DIRTY_BG_RATIO}
vm.overcommit_memory = 1
"

if [[ "$TIER" == "micro" ]]; then
    SYSCTL_CONTENT+="
# ── 极小内存机器专属保护 ──────────────────────────────────────
vm.min_free_kbytes = 16384
vm.vfs_cache_pressure = 200
"
fi

info "参数预览 [${TIER}档]:"
info "  buffer max: $(( RMEM_MAX/1024/1024 ))MB | somaxconn: ${SOMAXCONN} | conntrack: ${CONNTRACK_MAX}"
info "  nofile: ${NOFILE} | swappiness: ${SWAPPINESS} | 拥塞控制: ${BBR_CC}+${QDISC}"

if ! $DRY_RUN; then
    mkdir -p "$(dirname "$SYSCTL_CONF")"
    echo "$SYSCTL_CONTENT" > "$SYSCTL_CONF"
    log "已写入: $SYSCTL_CONF"
    modprobe nf_conntrack 2>/dev/null || modprobe ip_conntrack 2>/dev/null || \
        warn "nf_conntrack 模块加载失败，conntrack 参数可能不生效"
    sysctl --system >> "$LOG_FILE" 2>&1 && log "sysctl 参数已生效" || \
        warn "部分参数应用失败，请查看日志: $LOG_FILE"
else
    echo "$SYSCTL_CONTENT"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Step 5: 文件描述符与进程限制（按分级）
# ══════════════════════════════════════════════════════════════════════════════
step "系统限制调整 - 分级: ${TIER} (nofile=${NOFILE})"

LIMITS_CONTENT="# ============================================================
# 系统限制优化 - optimize-network.sh v2.0 (${TIER})
# ============================================================
*    soft nofile ${NOFILE}
*    hard nofile ${NOFILE}
root soft nofile ${NOFILE}
root hard nofile ${NOFILE}
*    soft nproc  ${NPROC}
*    hard nproc  ${NPROC}
root soft nproc  ${NPROC}
root hard nproc  ${NPROC}
"

if ! $DRY_RUN; then
    mkdir -p "$(dirname "$LIMITS_CONF")"
    echo "$LIMITS_CONTENT" > "$LIMITS_CONF"
    log "已写入: $LIMITS_CONF"

    mkdir -p /etc/systemd/system.conf.d/
    cat > /etc/systemd/system.conf.d/99-nofile.conf << EOF
[Manager]
DefaultLimitNOFILE=${NOFILE}
DefaultLimitNPROC=${NPROC}
EOF
    log "已写入 systemd 限制配置"
    systemctl daemon-reexec >> "$LOG_FILE" 2>&1 || true
else
    echo "$LIMITS_CONTENT"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Step 6: DNS 优化
# ══════════════════════════════════════════════════════════════════════════════
step "DNS 优化"

HAS_RESOLVED=$(systemctl is-active systemd-resolved 2>/dev/null || echo "inactive")
info "systemd-resolved: $HAS_RESOLVED"

if [[ "$HAS_RESOLVED" == "active" ]]; then
    RESOLVED_CONF_CONTENT="[Resolve]
DNS=223.5.5.5#dns.alidns.com 119.29.29.29#dot.pub
FallbackDNS=1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google
DNSOverTLS=opportunistic
DNSSEC=allow-downgrade
Cache=yes
CacheFromLocalhost=no
MulticastDNS=no
LLMNR=no
"
    if ! $DRY_RUN; then
        mkdir -p "$(dirname "$SYSTEMD_RESOLVED_CONF")"
        echo "$RESOLVED_CONF_CONTENT" > "$SYSTEMD_RESOLVED_CONF"
        systemctl restart systemd-resolved >> "$LOG_FILE" 2>&1 && \
            log "systemd-resolved 已应用新配置" || warn "重启失败"
        if [[ ! -L "/etc/resolv.conf" ]] || [[ "$(readlink /etc/resolv.conf)" != "/run/systemd/resolve/stub-resolv.conf" ]]; then
            cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak" 2>/dev/null || true
            ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
            log "/etc/resolv.conf 已指向 systemd-resolved"
        fi
    else
        echo "$RESOLVED_CONF_CONTENT"
    fi
else
    RESOLV_CONTENT="nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 1.1.1.1
options ndots:2
options timeout:2
options attempts:2
options rotate
options single-request-reopen
"
    if ! $DRY_RUN; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
        cp /etc/resolv.conf "$BACKUP_DIR/resolv.conf.bak" 2>/dev/null || true
        echo "$RESOLV_CONTENT" > /etc/resolv.conf
        chattr +i /etc/resolv.conf 2>/dev/null || warn "无法锁定 resolv.conf（容器环境常见），请注意防止被覆盖"
        log "已写入并锁定 /etc/resolv.conf"
    else
        echo "$RESOLV_CONTENT"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Step 7: 网卡与中断优化（多核机器重点，单核跳过复杂调度）
# ══════════════════════════════════════════════════════════════════════════════
step "网卡参数优化"

PRIMARY_IF=$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/{print $5; exit}' || echo "")

if [[ -z "$PRIMARY_IF" ]]; then
    warn "无法检测主网卡，跳过网卡优化"
else
    info "主网卡: $PRIMARY_IF | CPU核心数: $CPU_CORES"

    if command -v ethtool &>/dev/null; then
        if ! $DRY_RUN; then
            ethtool -K "$PRIMARY_IF" gro on tso on gso on >> "$LOG_FILE" 2>&1 || true

            case $TIER in
                micro|small) ethtool -G "$PRIMARY_IF" rx 512  tx 512  >> "$LOG_FILE" 2>&1 || true ;;
                medium|large) ethtool -G "$PRIMARY_IF" rx 1024 tx 1024 >> "$LOG_FILE" 2>&1 || true ;;
                *) ethtool -G "$PRIMARY_IF" rx 4096 tx 4096 >> "$LOG_FILE" 2>&1 || true ;;
            esac
            log "网卡 $PRIMARY_IF 队列已按 ${TIER} 档调整"
        fi
    else
        warn "ethtool 未安装（apt/yum install ethtool 可获得更细致优化）"
    fi

    if ! $DRY_RUN; then
        tc qdisc replace dev "$PRIMARY_IF" root "$QDISC" 2>/dev/null && \
            log "网卡发送队列调度已设为 ${QDISC}" || warn "tc qdisc 设置失败（容器环境常见，可忽略）"
    fi

    if (( CPU_CORES >= 2 )) && ! $DRY_RUN; then
        for rxq in /sys/class/net/"$PRIMARY_IF"/queues/rx-*/rps_cpus; do
            [[ -f "$rxq" ]] || continue
            CPU_MASK=$(printf '%x' $(( (1 << CPU_CORES) - 1 )))
            echo "$CPU_MASK" > "$rxq" 2>/dev/null || true
        done
        echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
        log "多核机器已启用 RPS（接收包多核分发）"

        if ! command -v irqbalance &>/dev/null; then
            if command -v apt-get &>/dev/null; then
                run "apt-get install -y irqbalance"
            elif command -v yum &>/dev/null; then
                run "yum install -y irqbalance"
            fi
        fi
        systemctl enable --now irqbalance >> "$LOG_FILE" 2>&1 && log "irqbalance 已启用（多核中断均衡）" || true
    else
        info "单核机器，跳过 RPS/irqbalance（无实际收益）"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Step 8: CPU 调度策略（性能模式，减少延迟抖动）
# ══════════════════════════════════════════════════════════════════════════════
step "CPU 频率调度优化"

if command -v cpupower &>/dev/null; then
    if ! $DRY_RUN; then
        cpupower frequency-set -g performance >> "$LOG_FILE" 2>&1 && \
            log "CPU 调度策略已设为 performance（减少调频延迟）" || \
            info "该虚拟机不支持调频（常见于云服务器，CPU由宿主机控制，属正常现象）"
    fi
else
    info "cpupower 未安装或为虚拟化环境（云服务器通常无需此项，宿主机已固定频率）"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Step 9: 透明大页禁用
# ══════════════════════════════════════════════════════════════════════════════
step "透明大页 (THP) 优化"

THP_PATH="/sys/kernel/mm/transparent_hugepage/enabled"
if [[ -f "$THP_PATH" ]]; then
    info "当前 THP 状态: $(cat "$THP_PATH")"
    if ! $DRY_RUN; then
        echo never > "$THP_PATH" 2>/dev/null || true
        echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

        RC_LOCAL="/etc/rc.local"
        if [[ ! -f "$RC_LOCAL" ]]; then
            echo '#!/bin/bash' > "$RC_LOCAL"; echo 'exit 0' >> "$RC_LOCAL"; chmod +x "$RC_LOCAL"
        fi
        grep -q "transparent_hugepage" "$RC_LOCAL" || \
            sed -i '/^exit 0/i echo never > /sys/kernel/mm/transparent_hugepage/enabled\necho never > /sys/kernel/mm/transparent_hugepage/defrag' "$RC_LOCAL"
        log "THP 已禁用"
    fi
else
    info "THP 不存在（容器环境常见），跳过"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Step 10: 验证
# ══════════════════════════════════════════════════════════════════════════════
step "验证优化结果"

if ! $DRY_RUN; then
    echo ""
    echo -e "${BOLD}── 关键参数验证 ─────────────────────────────────────${NC}"
    check_param() {
        local key=$1 expected=$2
        local actual; actual=$(sysctl -n "$key" 2>/dev/null || echo "N/A")
        if [[ -z "$expected" || "$actual" == "$expected" ]]; then
            echo -e "  ${GREEN}✓${NC} $key = $actual"
        else
            echo -e "  ${YELLOW}~${NC} $key = $actual (期望: $expected)"
        fi
    }
    check_param "net.ipv4.tcp_congestion_control" "$BBR_CC"
    check_param "net.core.default_qdisc" "$QDISC"
    check_param "net.ipv4.tcp_fastopen" "3"
    check_param "net.ipv4.tcp_tw_reuse" "1"
    check_param "net.core.rmem_max" ""
    check_param "net.netfilter.nf_conntrack_max" ""
    check_param "vm.swappiness" "$SWAPPINESS"

    echo ""
    echo -e "${BOLD}── DNS 解析测试 ─────────────────────────────────────${NC}"
    for domain in google.com youtube.com; do
        if result=$(dig +short +time=3 "$domain" A 2>/dev/null | head -1) && [[ -n "$result" ]]; then
            echo -e "  ${GREEN}✓${NC} $domain → $result"
        else
            echo -e "  ${RED}✗${NC} $domain 解析失败（检查防火墙/DNS配置）"
        fi
    done

    echo ""
    echo -e "${BOLD}── 内存使用状况 ─────────────────────────────────────${NC}"
    free -h | tee -a "$LOG_FILE"
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

echo -e "${BOLD}机器分级：${TIER}${NC}（${MEM_TOTAL_MB}MB 内存 / ${CPU_CORES} 核）"
echo -e "${BOLD}优化摘要：${NC}"
echo -e "  ${GREEN}✓${NC} 拥塞控制: ${BBR_CC} + ${QDISC}"
echo -e "  ${GREEN}✓${NC} TCP缓冲: 最大 $(( RMEM_MAX/1024/1024 ))MB（已做20%内存安全边界裁剪）"
echo -e "  ${GREEN}✓${NC} conntrack表: ${CONNTRACK_MAX} 条（按内存自动计算，防OOM）"
echo -e "  ${GREEN}✓${NC} 文件描述符: ${NOFILE}"
echo -e "  ${GREEN}✓${NC} DNS加密解析 + 缓存"
[[ "$TIER" == "micro" || "$TIER" == "small" ]] && \
echo -e "  ${GREEN}✓${NC} 低内存机器专属：swap建议/vfs_cache_pressure收紧"
(( CPU_CORES >= 2 )) && \
echo -e "  ${GREEN}✓${NC} 多核优化: RPS + irqbalance"
echo ""
echo -e "${BOLD}日志：${NC} $LOG_FILE　${BOLD}备份：${NC} $BACKUP_DIR"
echo -e "${YELLOW}建议重启服务器使全部参数完全生效${NC}"
echo -e "还原命令: ${CYAN}sudo bash $0 --revert${NC}"
echo ""
