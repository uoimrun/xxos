#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Virtualizor NAT 工具箱
# ==============================================================================

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
    # ok "依赖已存在：$CMD"
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


# ========== 菜单2：自动重启容器 ==========
install_autorestart_service(){
  must_root
  local PM; PM=$(pm)

  ensure_pkg "$PM" lxc lxc-ls
  ensure_pkg "$PM" lxc lxc-info
  ensure_pkg "$PM" lxc lxc-start
  ensure_pkg "$PM" lxc lxc-stop

  info "正在安装/更新 systemd 自动重启服务..."

  cat > /usr/local/bin/lxc-autostart-onboot.sh <<'EOF'
#!/usr/bin/env bash
set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

echo "[AUTO] Waiting for network settlement..."
sleep 15

lxc-ls --fancy --fancy-format name,state,ipv4 | awk 'NR>1 {print $1, $2, $3}' | while read -r name state ipv4; do
  [ -n "$name" ] || continue
  
  ipv4="${ipv4%,}"

  if [ "$state" != "RUNNING" ]; then
    continue
  fi

  # 检测无 IP
  if [ -z "${ipv4:-}" ] || [ "$ipv4" = "-" ]; then
    echo "[AUTO] Container $name is RUNNING but has no IP. Restarting..."
    lxc-stop -n "$name" -k >/dev/null 2>&1 || true
    sleep 2
    lxc-start -n "$name" -d >/dev/null 2>&1 || true
    echo "[AUTO] $name restarted."
  else
    echo "[AUTO] Container $name is OK ($ipv4)."
  fi
done
EOF
  chmod +x /usr/local/bin/lxc-autostart-onboot.sh

  cat > /etc/systemd/system/lxc-autostart-onboot.service <<'EOF'
[Unit]
Description=Auto restart LXC containers without IPv4 on boot
After=network-online.target virtualizor.service lxc.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lxc-autostart-onboot.sh
StandardOutput=journal
StandardError=journal
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable lxc-autostart-onboot.service >/dev/null 2>&1 || true
  ok "自动重启服务已安装 ✅"

  read -rp "是否立刻执行一次检测? [Y/n]：" RUNNOW
  RUNNOW="${RUNNOW:-Y}"
  if [[ "$RUNNOW" =~ ^[Yy]$ ]]; then
    /usr/local/bin/lxc-autostart-onboot.sh || true
    ok "执行完毕"
  fi
}

run_autorestart_once(){
  must_root
  if [ ! -f /usr/local/bin/lxc-autostart-onboot.sh ]; then
    warn "脚本未安装，请先选择安装服务"
    return 0
  fi
  info "手动触发检测..."
  /usr/local/bin/lxc-autostart-onboot.sh || true
  ok "检测完成 ✅"
}

# ========== 状态显示==========
show_nat_status(){
  must_root
  echo -e "${CYAN}NAT 容器状态概览${NC}"
  echo "--------------------------------------------------------"
  printf "%-15s %-10s %-20s\n" "NAME" "STATE" "IPV4"
  echo "--------------------------------------------------------"

  lxc-ls --fancy --fancy-format name,state,ipv4 | awk 'NR>1 {print $1, $2, $3}' | while read -r name state ipv4; do
    [ -n "$name" ] || continue

    ipv4="${ipv4%,}"

    COLOR="$NC"
    if [ "$state" = "RUNNING" ]; then
      if [ -z "${ipv4:-}" ] || [ "$ipv4" = "-" ]; then
        COLOR="$RED"
        ipv4="NO-IP (Error)"
      else
        COLOR="$GREEN"
      fi
    else
      COLOR="$YELLOW"
      ipv4="-"
    fi

    printf "${COLOR}%-15s %-10s %-20s${NC}\n" "$name" "$state" "$ipv4"
  done
  echo "--------------------------------------------------------"
}


menu_autorestart(){
  while true; do
    clear
    echo -e "${GREEN}自动重启 NAT 无网容器${NC}" >&2
    echo "------------------------" >&2
    echo "1) 安装守护服务" >&2
    echo "2) 立即手动执行一次" >&2
    echo "3) 查看容器详细状态" >&2
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


# ========== 菜单6：NAT 端口映射审计与矫正 ==========
nat_audit_logic() {
    must_root
    local HAPROXY_CONF="/etc/haproxy/haproxy.cfg"
    local IP_PREFIX="10.0.0."
    
    [ -f "$HAPROXY_CONF" ] || { fail "未找到 HAProxy 配置文件"; return 1; }

    echo -e "${CYAN}NAT 端口逻辑审计 (精准行修复)${NC}"
    read -rp "请输入起始端口 (默认 40001): " START_PORT
    START_PORT="${START_PORT:-40001}"
    read -rp "请输入端口步长 (默认 20): " STEP
    STEP="${STEP:-20}"
    
    # 建立一个干净的临时文件进行修改
    local WORKING_CONF
    WORKING_CONF=$(mktemp)
    cp "$HAPROXY_CONF" "$WORKING_CONF"

    local CHANGES=""
    local HAS_CHANGE=false

    info "正在比对逻辑: IP 100-125 | 起始 $START_PORT | 步长 $STEP"

    for i in $(seq 100 125); do
        local TARGET_IP="${IP_PREFIX}$i"
        local P_START=$(( START_PORT + (i - 100) * STEP ))
        local P_END=$(( P_START + STEP - 1 ))
        
        for port in $(seq "$P_START" "$P_END"); do
            # 仅在包含该端口的行中查找 IP
            # 搜索包含 _port 或 :port 的行，并提取其中的 10.0.0.x
            local ACTUAL_IP
            ACTUAL_IP=$(grep -E "(_${port}\b|:${port}\b)" "$WORKING_CONF" | grep -oP "10\.0\.0\.\d{1,3}" | head -n 1 || true)
            
            if [ -n "$ACTUAL_IP" ] && [ "$ACTUAL_IP" != "$TARGET_IP" ]; then
                CHANGES+="${YELLOW}端口 $port:${NC} $ACTUAL_IP -> ${GREEN}$TARGET_IP${NC}\n"
                # 【精准修复】仅对包含该端口的行执行 IP 替换，防止误伤全局
                sed -i "/[_\b:]${port}\b/s/$ACTUAL_IP/$TARGET_IP/g" "$WORKING_CONF"
                HAS_CHANGE=true
            fi
        done
    done

    if [ "$HAS_CHANGE" = false ]; then
        ok "配置逻辑完美，未发现偏差。"
        rm -f "$WORKING_CONF"
    else
        echo -e "${YELLOW}发现以下逻辑冲突：${NC}"
        echo -e "$CHANGES" | column -t
        echo "-------------------------------------------"
        read -rp "是否应用矫正? [y/N]: " CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            local BAK_FILE="${HAPROXY_CONF}.bak_$(date +%H%M%S)"
            cp "$HAPROXY_CONF" "$BAK_FILE" # 物理备份
            
            # 覆盖原文件
            cat "$WORKING_CONF" > "$HAPROXY_CONF"
            
            # 语法检查
            if haproxy -c -f "$HAPROXY_CONF" > /dev/null 2>&1; then
                systemctl restart haproxy
                ok "矫正成功！备份见 $BAK_FILE"
            else
                fail "检测到语法错误！已自动回滚。"
                cat "$BAK_FILE" > "$HAPROXY_CONF"
                systemctl restart haproxy
            fi
        fi
        rm -f "$WORKING_CONF"
    fi
}

menu(){
  while true; do
    clear
    echo -e "${GREEN}NAT 工具脚本（Debian / AlmaLinux）${NC}" >&2
    echo "-------------------------------------------" >&2
    echo "1) 修复 NAT 内存限制" >&2
    echo "2) 自动重启无网容器" >&2
    echo "3) 执行 NAT 调优" >&2
    echo "4) 下载 Debian 模板" >&2
    echo "5) NAT 映射管理" >&2
    echo "6) NAT 端口审计与矫正" >&2
    echo "0) 退出" >&2
    echo "-------------------------------------------" >&2
    read -rp "请选择 [0-5]：" c
    case "$c" in
      1) fix_nat_memory ;;
      2) menu_autorestart ;;
      3) nat_tuning ;;
      4) download_tpl ;;
      5) nat_manage ;;
      6) nat_audit_logic ;; 
      0) exit 0 ;;
      *) warn "输入无效"; sleep 1 ;;
    esac
    echo
    read -rp "回车继续..." _
  done
}

menu
