#!/usr/bin/env bash
set -euo pipefail

CGROUP_MARKER="/root/.nat_cgroup_fixed.marker"
AUTORESTART_MARKER="/root/.nat_autorestart_installed.marker"
TUNING_MARKER="/root/.nat_tuning_installed.marker"
TPL_MARKER="/root/.nat_tpl_downloaded.marker"

LXC_TPL_DIR="/var/virtualizor/lxc"
TPL1_URL="https://github.com/hiapb/os/releases/download/os/debian-11-x86_64.tar.gz"
TPL2_URL="https://github.com/hiapb/os/releases/download/os/debian-12.0-x86_64.tar.gz"

GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
CYAN="\033[1;36m"
NC="\033[0m"

ok(){ echo -e "${GREEN}✔${NC} $*" >&2; }
info(){ echo -e "${CYAN}➜${NC} $*" >&2; }
warn(){ echo -e "${YELLOW}⚠${NC} $*" >&2; }
fail(){ echo -e "${RED}✘${NC} $*" >&2; }

must_root(){ [ "$(id -u)" -eq 0 ] || { fail "请用 root 执行 (sudo -i)"; exit 1; }; }
have(){ command -v "$1" >/dev/null 2>&1; }

pm(){
  if have apt-get; then echo apt
  elif have dnf; then echo dnf
  elif have yum; then echo yum
  else echo none
  fi
}

detect_os(){
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-}"
  else
    OS_ID="unknown"
    OS_VER=""
  fi
}

install_pkg(){
  local PKG="$1"
  local CMD="${2:-}"
  local PM; PM=$(pm)

  if [ -n "$CMD" ] && have "$CMD"; then
    ok "依赖已存在：$CMD"
    return 0
  fi

  info "安装依赖：$PKG"
  if [ "$PM" = "apt" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y $PKG >/dev/null 2>&1 || true
  elif [ "$PM" = "dnf" ]; then
    dnf install -y $PKG >/dev/null 2>&1 || true
  elif [ "$PM" = "yum" ]; then
    yum install -y $PKG >/dev/null 2>&1 || true
  else
    fail "未知包管理器，无法安装依赖：$PKG"
    exit 1
  fi
}

# ========== 菜单1：修复 NAT 内存限制 ==========
fix_nat_memory(){
  must_root
  detect_os
  local PM; PM=$(pm)

  if [ -f "$CGROUP_MARKER" ]; then
    ok "已修复过 (marker 存在)：$CGROUP_MARKER"
    warn "如需重新修复：rm -f $CGROUP_MARKER"
    return 0
  fi

  local cg
  cg=$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo "")

  info "系统: $OS_ID $OS_VER"
  info "cgroup 类型: $cg"

  # ---- Debian 系列 ----
  if [ -f /etc/debian_version ]; then
    info "检测到 Debian 系列，开始修复 memory cgroup..."

    local mem_enabled
    mem_enabled=$(awk '$1=="memory"{print $4}' /proc/cgroups 2>/dev/null || echo "0")

    if [ "$cg" = "cgroup2fs" ] || [ "$mem_enabled" != "1" ]; then
      info "需要写 grub 参数：systemd.unified_cgroup_hierarchy=0 cgroup_enable=memory swapaccount=1"

      install_pkg "grub2-common grub-pc" update-grub

      if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
        if ! grep -q "systemd.unified_cgroup_hierarchy=0" /etc/default/grub; then
          sed -i 's/^GRUB_CMDLINE_LINUX="\([^"]*\)"/GRUB_CMDLINE_LINUX="\1 systemd.unified_cgroup_hierarchy=0 cgroup_enable=memory swapaccount=1"/' /etc/default/grub
        fi
      else
        echo 'GRUB_CMDLINE_LINUX="systemd.unified_cgroup_hierarchy=0 cgroup_enable=memory swapaccount=1"' >> /etc/default/grub
      fi

      update-grub >/dev/null 2>&1 || true
      echo "fixed" > "$CGROUP_MARKER"

      ok "Debian 修复完成 ✅"
      warn "必须 reboot 才生效：reboot"
    else
      ok "Debian 已启用 memory cgroup，无需修改 ✅"
      echo "fixed" > "$CGROUP_MARKER"
    fi
    return 0
  fi

  # ---- AlmaLinux / EL9 ----
  if [[ "$OS_ID" =~ (almalinux|rocky|rhel|centos) ]] && [[ "${OS_VER:-0}" =~ ^9 ]]; then
    info "检测到 EL9 系列（Alma/Rocky/RHEL9），开始修复..."

    if [ "$cg" = "cgroup2fs" ]; then
      info "需要写 grubby 参数：systemd.unified_cgroup_hierarchy=0 cgroup_enable=memory swapaccount=1"

      install_pkg grubby grubby

      grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=0 cgroup_enable=memory swapaccount=1" >/dev/null 2>&1 || true

      echo "fixed" > "$CGROUP_MARKER"
      ok "EL9 修复完成 ✅"
      warn "必须 reboot 才生效：reboot"
    else
      ok "EL9 当前不是 cgroup2fs，可能已是 v1 ✅"
      echo "fixed" > "$CGROUP_MARKER"
    fi
    return 0
  fi

  warn "当前系统不在修复范围内：$OS_ID"
  warn "你可以手动检查：stat -fc %T /sys/fs/cgroup"
}

# ========== 菜单2：安装开机自动重启无IP容器 ==========
install_autorestart(){
  must_root

  install_pkg lxc lxc-ls || true
  install_pkg lxc lxc-info || true
  install_pkg lxc lxc-start || true

  info "安装 systemd 开机自动重启无IP容器服务..."

  cat > /usr/local/bin/lxc-autostart-onboot.sh <<'EOF'
#!/usr/bin/env bash
set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

sleep 8

lxc-ls -f 2>/dev/null | awk 'NR>1 {print $1, $5}' | while read -r name ipv4; do
  [ -n "$name" ] || continue
  if [ -z "${ipv4:-}" ] || [ "$ipv4" = "-" ]; then
    echo "[AUTO] $name no-ip => restart"
    lxc-stop -n "$name" -k >/dev/null 2>&1 || true
    sleep 1
    lxc-start -n "$name" -d >/dev/null 2>&1 || true
  else
    echo "[AUTO] $name ok ip=$ipv4"
  fi
done
EOF
  chmod +x /usr/local/bin/lxc-autostart-onboot.sh

  cat > /etc/systemd/system/lxc-autostart-onboot.service <<'EOF'
[Unit]
Description=Auto restart LXC containers without IPv4 on boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lxc-autostart-onboot.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable lxc-autostart-onboot.service >/dev/null 2>&1 || true

  echo "installed" > "$AUTORESTART_MARKER"
  ok "安装完成 ✅ 已设置开机自启"

  read -rp "是否立刻执行一次检测并重启无IP容器? [Y/n]：" RUNNOW
  RUNNOW="${RUNNOW:-Y}"
  if [[ "$RUNNOW" =~ ^[Yy]$ ]]; then
    systemctl start lxc-autostart-onboot.service >/dev/null 2>&1 || true
    ok "已执行一次 ✅"
    info "查看日志：journalctl -u lxc-autostart-onboot.service -n 80 --no-pager"
  fi
}

# ========== 菜单3：NAT 调优 ==========
nat_tuning(){
  must_root
  info "开始 NAT 调优..."
  install_pkg curl curl || true

  read -rp "执行 NAT 调优脚本? [Y/n]：" DO_TUNE
  DO_TUNE="${DO_TUNE:-Y}"
  if [[ "$DO_TUNE" =~ ^[Yy]$ ]]; then
    bash <(curl -fsSL https://raw.githubusercontent.com/nuro-hia/tuning/main/install.sh) || true
    echo "tuned" > "$TUNING_MARKER"
    ok "NAT 调优已执行 ✅"
  else
    warn "已跳过 NAT 调优"
  fi
}

# ========== 菜单4：下载 Debian 模板 ==========
download_tpl(){
  must_root
  info "下载 LXC Debian 模板..."

  install_pkg wget wget || true

  read -rp "下载 Debian 11/12 模板并清空目录? [Y/n]：" DL
  DL="${DL:-Y}"
  if [[ ! "$DL" =~ ^[Yy]$ ]]; then
    warn "已跳过模板下载"
    return 0
  fi

  mkdir -p "$LXC_TPL_DIR"
  cd "$LXC_TPL_DIR"

  rm -rf ./* ./.??* 2>/dev/null || true

  wget -q --show-progress -O debian-11-x86_64.tar.gz "$TPL1_URL"
  wget -q --show-progress -O debian-12.0-x86_64.tar.gz "$TPL2_URL"

  echo "downloaded" > "$TPL_MARKER"
  ok "模板下载完成 ✅ 目录：$LXC_TPL_DIR"
}

menu(){
  clear
  echo -e "${GREEN}NAT 工具脚本（Debian / AlmaLinux）${NC}" >&2
  echo "-------------------------------------------" >&2
  echo "1) 修复 NAT 内存限制" >&2
  echo "2) 安装 自动重启nat容器" >&2
  echo "3) 执行 NAT 调优脚本" >&2
  echo "4) 下载 Debian 11/12 LXC 模板" >&2
  echo "0) 退出" >&2
  echo "-------------------------------------------" >&2
  read -rp "请选择 [0-4]：" c
  case "$c" in
    1) fix_nat_memory ;;
    2) install_autorestart ;;
    3) nat_tuning ;;
    4) download_tpl ;;
    0) exit 0 ;;
    *) warn "输入无效"; sleep 1 ;;
  esac
  echo
  read -rp "回车继续..." _
}

while true; do menu; done
