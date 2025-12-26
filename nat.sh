#!/usr/bin/env bash
set -euo pipefail

CGROUP_MARKER="/root/.nat_cgroup_fixed.marker"
AUTORESTART_MARKER="/root/.nat_autorestart_installed.marker"

TPL_DIR="/var/virtualizor/lxc"
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

ensure_pkg(){
  local PM="$1" PKG="$2" CMD="${3:-}"
  if [ -n "$CMD" ] && have "$CMD"; then
    ok "依赖已存在：$CMD"
    return 0
  fi
  info "安装依赖：$PKG"
  if [ "$PM" = apt ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "$PKG" >/dev/null 2>&1 || true
  elif [ "$PM" = dnf ]; then
    dnf install -y "$PKG" >/dev/null 2>&1 || true
  elif [ "$PM" = yum ]; then
    yum install -y "$PKG" >/dev/null 2>&1 || true
  else
    fail "未知包管理器"
    exit 1
  fi
}

# ========== 菜单1：修复 NAT 内存限制 ==========
fix_nat_memory(){
  must_root
  detect_os
  local PM; PM=$(pm)

  local cg
  cg=$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo "")

  info "系统: $OS_ID $OS_VER"
  info "cgroup: $cg"

  if [ -f "$CGROUP_MARKER" ] && [ "$cg" != "cgroup2fs" ]; then
    ok "已修复且已生效 ✅ ($cg)"
    return 0
  fi

  # ---- Debian ----
  if [ -f /etc/debian_version ]; then
    local mem_enabled
    mem_enabled=$(awk '$1=="memory"{print $4}' /proc/cgroups 2>/dev/null || echo "0")

    if [ "$cg" = "cgroup2fs" ] || [ "$mem_enabled" != "1" ]; then
      info "写 grub 参数：systemd.unified_cgroup_hierarchy=0 cgroup_enable=memory swapaccount=1"

      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null 2>&1 || true
      apt-get install -y grub2-common grub-pc >/dev/null 2>&1 || true

      if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
        if ! grep -q "systemd.unified_cgroup_hierarchy=0" /etc/default/grub; then
          sed -i 's/^GRUB_CMDLINE_LINUX="\([^"]*\)"/GRUB_CMDLINE_LINUX="\1 systemd.unified_cgroup_hierarchy=0 cgroup_enable=memory swapaccount=1"/' /etc/default/grub
        fi
      else
        echo 'GRUB_CMDLINE_LINUX="systemd.unified_cgroup_hierarchy=0 cgroup_enable=memory swapaccount=1"' >> /etc/default/grub
      fi

      update-grub >/dev/null 2>&1 || true
      echo fixed > "$CGROUP_MARKER"
      ok "修复完成 ✅ 必须 reboot 生效"
    else
      ok "memory cgroup 已启用 ✅"
      echo fixed > "$CGROUP_MARKER"
    fi
    return 0
  fi

  # ---- EL9 ----
  if [[ "$OS_ID" =~ (almalinux|rocky|rhel|centos) ]] && [[ "${OS_VER:-0}" =~ ^9 ]]; then
    if [ "$cg" = "cgroup2fs" ]; then
      info "写 grubby 参数：systemd.unified_cgroup_hierarchy=0 cgroup_enable=memory swapaccount=1"

      ensure_pkg "$PM" grubby grubby
      grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=0 cgroup_enable=memory swapaccount=1" >/dev/null 2>&1 || true

      echo fixed > "$CGROUP_MARKER"
      ok "修复完成 ✅ 必须 reboot 生效"
    else
      ok "当前不是 cgroup2fs，可能已是 v1 ✅"
      echo fixed > "$CGROUP_MARKER"
    fi
    return 0
  fi

  warn "不支持系统：$OS_ID"
}


# ========== 菜单2：自动重启容器（子菜单） ==========
install_autorestart_service(){
  must_root
  local PM; PM=$(pm)

  ensure_pkg "$PM" lxc lxc-ls
  ensure_pkg "$PM" lxc lxc-info
  ensure_pkg "$PM" lxc lxc-start
  ensure_pkg "$PM" lxc lxc-stop

  info "安装 systemd 自动重启服务（未运行则重启）..."

  cat > /usr/local/bin/lxc-autostart-onboot.sh <<'EOF'
#!/usr/bin/env bash
set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# 等网络、网桥起来
sleep 8

# 只看 IPV4：没IP就 stop/start
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

  o ok "安装完成 ✅ 已设置开机自启"

  # 可选：立刻跑一次
  read -rp "是否立刻执行一次检测并重启未运行容器? [Y/n]：" RUNNOW
  RUNNOW="${RUNNOW:-Y}"
  if [[ "$RUNNOW" =~ ^[Yy]$ ]]; then
    systemctl start lxc-autostart-onboot.service || true
    ok "已执行一次 ✅"
  fi
}

run_autorestart_once(){
  must_root
  if ! systemctl list-unit-files | grep -q '^lxc-autostart-onboot.service'; then
    warn "未检测到 systemd 服务，请先选 1 安装服务"
    return 0
  fi
  systemctl start lxc-autostart-onboot.service || true
  ok "已执行一次 ✅"
}


show_nat_status(){
  must_root
  echo -e "${CYAN}NAT 容器状态${NC}"
  echo "------------------------------------------"
  printf "%-10s %-18s %-10s\n" "NAME" "IPV4" "STATE"
  echo "------------------------------------------"

  lxc-ls -f 2>/dev/null | awk 'NR>1 {print $1, $5}' | while read -r name ipv4; do
    [ -n "$name" ] || continue

    if [[ -z "${ipv4:-}" || "$ipv4" == "-" ]]; then
      # 没IP
      printf "%-10s %-18s ${RED}%-10s${NC}\n" "$name" "-" "未运行"
    else
      # 有IP
      printf "%-10s %-18s ${GREEN}%-10s${NC}\n" "$name" "$ipv4" "运行中"
    fi
  done

  echo "------------------------------------------"
}



menu_autorestart(){
  while true; do
    clear
    echo -e "${GREEN}自动重启NAT容器${NC}" >&2
    echo "------------------------" >&2
    echo "1) 安装服务" >&2
    echo "2) 立即执行" >&2
    echo "3) 查看容器状态" >&2
    echo "0) 返回" >&2
    echo "------------------------" >&2
    read -rp "请选择 [0-3]：" c

    case "$c" in
      1)
        install_autorestart_service
        read -rp "回车继续..." _
        ;;
      2)
        run_autorestart_once
        read -rp "回车继续..." _
        ;;
      3)
        show_nat_status
        read -rp "回车继续..." _
        ;;
      0)
        return 0
        ;;
      *)
        warn "输入无效"
        sleep 1
        ;;
    esac
  done
}


# ========== 菜单3：执行 NAT 调优 ==========
nat_tuning(){
  must_root
  local PM; PM=$(pm)
  ensure_pkg "$PM" curl curl || true
  bash <(curl -fsSL https://raw.githubusercontent.com/nuro-hia/tuning/main/install.sh)
  ok "NAT 调优执行完成 ✅"
}

# ========== 菜单4：下载模板 ==========
download_tpl(){
  must_root
  local PM; PM=$(pm)
  ensure_pkg "$PM" wget wget || ensure_pkg "$PM" curl curl || true

  mkdir -p "$TPL_DIR"
  cd "$TPL_DIR"

  read -rp "清空旧模板目录并重新下载? [Y/n]：" CLR
  CLR="${CLR:-Y}"
  if [[ "$CLR" =~ ^[Yy]$ ]]; then
    rm -rf ./* ./.??* 2>/dev/null || true
  fi

  info "下载 Debian 11..."
  wget -q --show-progress -O debian-11-x86_64.tar.gz "$TPL1_URL"

  info "下载 Debian 12..."
  wget -q --show-progress -O debian-12.0-x86_64.tar.gz "$TPL2_URL"

  ok "模板下载完成 ✅"
}

# ========== 菜单5：NAT 映射管理 ==========
nat_manage(){
  must_root
  ensure_pkg "$(pm)" curl curl || true
  bash <(curl -fsSL https://raw.githubusercontent.com/nixore-run/nix-nat/refs/heads/main/nat.sh)
}

menu(){
  while true; do
    clear
    echo -e "${GREEN}NAT 工具脚本（Debian / AlmaLinux）${NC}" >&2
    echo "-------------------------------------------" >&2
    echo "1) 修复 NAT 内存限制" >&2
    echo "2) 安装 自动重启nat容器" >&2
    echo "3) 执行 NAT 调优" >&2
    echo "4) 下载 Debian 模板" >&2
    echo "5) NAT 映射管理" >&2
    echo "0) 退出" >&2
    echo "-------------------------------------------" >&2
    read -rp "请选择 [0-5]：" c
    case "$c" in
      1) fix_nat_memory ;;
      2) menu_autorestart ;;
      3) nat_tuning ;;
      4) download_tpl ;;
      5) nat_manage ;;
      0) exit 0 ;;
      *) warn "输入无效"; sleep 1 ;;
    esac
    echo
    read -rp "回车继续..." _
  done
}

menu
