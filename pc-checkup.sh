#!/usr/bin/env bash
set -euo pipefail

# ---------- Options ----------
DRY_RUN=1
case "${1-}" in
  --apply) DRY_RUN=0 ;;
  ""|--dry-run) DRY_RUN=1 ;;
  *) echo "Usage: $0 [--dry-run|--apply]"; exit 2 ;;
esac

# ---------- Config ----------
MIN_SWAP_GB=4
SWAPPINESS=10
JOURNAL_RETENTION_DAYS=7
TS="$(date +%Y%m%d_%H%M%S)"
REPORT="/var/log/pc_checkup_${TS}.log"

DISABLE_SERVICES=(
  "NetworkManager-wait-online.service"
  "cups.service"
  "cups-browsed.service"
  "apache2.service"
  "ModemManager.service"
  "avahi-daemon.service"
  "openvpn.service"
)

# ---------- Helpers ----------
need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run as root."; exit 1; }; }
sec(){ echo -e "\n=== $* ===" | tee -a "$REPORT"; }
kv(){ printf "%-28s %s\n" "$1" "$2" | tee -a "$REPORT"; }
pkg(){ DEBIAN_FRONTEND=noninteractive apt-get -y install "$@" >/dev/null; }
exists(){ command -v "$1" >/dev/null 2>&1; }
is_enabled(){ systemctl is-enabled "$1" >/dev/null 2>&1; }
unit_exists(){ systemctl list-unit-files | awk '{print $1}' | grep -qx "$1"; }
line_in_file(){ local l=$1 f=$2; grep -Fqx "$l" "$f" 2>/dev/null; }

run_step(){ # run_step <desc> <cmd...>
  local desc="$1"; shift
  if (( DRY_RUN )); then kv "DRY‑RUN" "$desc"; return 0; fi
  kv "APPLY" "$desc"
  "$@" >/dev/null 2>&1 || true
}

# ---------- Start ----------
need_root
mkdir -p "$(dirname "$REPORT")"; : > "$REPORT"
kv "Mode" "$( ((DRY_RUN)) && echo dry-run || echo apply )"
kv "Report" "$REPORT"

sec "System Overview"
os_name="$(lsb_release -ds 2>/dev/null || echo 'Unknown')"
kv "OS" "$os_name"
kv "Kernel" "$(uname -r)"
kv "Hostname" "$(hostname)"
kv "Uptime" "$(uptime -p)"
kv "CPU" "$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
kv "RAM" "$(free -h | awk '/Mem:/{print $2" total, "$7" available"}')"
if exists nvidia-smi; then
  kv "GPU" "$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null)"
else
  kv "GPU" "nvidia-smi not found"
fi

sec "Health Checks"
pkg lm-sensors smartmontools nvme-cli >/dev/null 2>&1 || true
sensors 2>/dev/null | tee -a "$REPORT" >/dev/null || true
nvme list 2>/dev/null | tee -a "$REPORT" >/dev/null || true
nvme smart-log /dev/nvme0n1 2>/dev/null | tee -a "$REPORT" >/dev/null || true
smartctl -a /dev/nvme0n1 2>/dev/null | awk 'NR<80' | tee -a "$REPORT" >/dev/null || true

sec "Boot Time Snapshot"
systemd-analyze 2>/dev/null | tee -a "$REPORT" || true
systemd-analyze blame 2>/dev/null | head -n 30 | tee -a "$REPORT" || true

sec "Swap & Memory"
current_swap_bytes=$(awk '/^SwapTotal:/{print $2*1024}' /proc/meminfo)
current_swap_gb=$(( current_swap_bytes / 1024 / 1024 / 1024 ))
kv "Swap current" "${current_swap_gb}G"

ensure_swap(){
  local want_gb="$1"
  run_step "swapoff" swapoff -a
  if [ -f /swapfile ]; then run_step "remove immutable flag (if any)" chattr -i /swapfile; fi
  run_step "allocate /swapfile ${want_gb}G" fallocate -l "${want_gb}G" /swapfile
  run_step "chmod 600 /swapfile" chmod 600 /swapfile
  run_step "mkswap /swapfile" mkswap /swapfile
  run_step "swapon /swapfile" swapon /swapfile
  if ! line_in_file "/swapfile none swap sw 0 0" /etc/fstab; then
    if (( DRY_RUN )); then kv "DRY‑RUN" "append /swapfile to /etc/fstab"; else
      sed -i '/ swap /d' /etc/fstab; echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
  fi
}
if [ "$current_swap_gb" -lt "$MIN_SWAP_GB" ]; then
  kv "Swap action" "resize to ${MIN_SWAP_GB}G"
  ensure_swap "$MIN_SWAP_GB"
else
  kv "Swap action" "OK (>= ${MIN_SWAP_GB}G)"
fi

sysctl_file="/etc/sysctl.d/99-performance.conf"
if (( DRY_RUN )); then
  kv "Swappiness" "would set vm.swappiness=${SWAPPINESS} in ${sysctl_file}"
else
  echo "vm.swappiness=${SWAPPINESS}" > "$sysctl_file"
  sysctl --system >/dev/null
  kv "Swappiness" "${SWAPPINESS}"
fi

pkg zram-tools >/dev/null 2>&1 || true
if (( DRY_RUN )); then
  kv "zram" "would enable zramswap.service"
else
  systemctl enable --now zramswap.service >/dev/null 2>&1 || true
  kv "zram" "enabled"
fi

sec "Services Optimization"
for s in "${DISABLE_SERVICES[@]}"; do
  if unit_exists "$s"; then
    if is_enabled "$s"; then
      run_step "disable $s" systemctl disable --now "$s"
    else
      kv "Skip" "$s (not enabled)"
    fi
  fi
done

# Docker socket-activation
if unit_exists docker.service; then
  if is_enabled docker.service; then
    run_step "disable docker.service" systemctl disable --now docker.service
  fi
  if unit_exists docker.socket; then
    run_step "enable docker.socket" systemctl enable --now docker.socket
    kv "Docker" "$( ((DRY_RUN)) && echo 'would use socket-activation' || echo 'socket-activation enabled' )"
  fi
fi
if unit_exists containerd.service; then
  if is_enabled containerd.service; then
    run_step "disable containerd.service" systemctl disable --now containerd.service
  fi
fi

sec "Packages & Cleanup"
if (( DRY_RUN )); then
  kv "Apt" "would run update/full-upgrade/autoremove/clean"
  kv "Journal" "would vacuum to ${JOURNAL_RETENTION_DAYS}d"
else
  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null || true
  DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade >/dev/null || true
  DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge >/dev/null || true
  DEBIAN_FRONTEND=noninteractive apt-get -y clean >/dev/null || true
  journalctl --vacuum-time="${JOURNAL_RETENTION_DAYS}d" >/dev/null || true
  kv "Cleanup" "done"
fi

sec "NVIDIA Display (optional, Xorg)"
if exists nvidia-settings; then
  if (( DRY_RUN )); then
    kv "nvidia" "would set FullCompositionPipeline on HDMI-1"
  else
    nvidia-settings --assign 'CurrentMetaMode=HDMI-1: nvidia-auto-select +0+0 { ForceFullCompositionPipeline=On }' >/dev/null 2>&1 || true
    kv "nvidia" "FullCompositionPipeline applied (HDMI-1)"
  fi
else
  kv "nvidia-settings" "not found"
fi

sec "Final Boot Snapshot"
systemd-analyze 2>/dev/null | tee -a "$REPORT" || true
systemd-analyze blame 2>/dev/null | head -n 30 | tee -a "$REPORT" || true

sec "Done"
kv "Report" "$REPORT"
echo "OK"

