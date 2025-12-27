#!/usr/bin/env bash
set -euo pipefail

MARKER="/root/.vt_onekey.marker"
CGROUP_MARKER="/root/.vt_cgroup_fixed.marker"
DEB_CGROUP_MARKER="/root/.vt_deb_cgroup_fixed.marker"


DEFAULT_IMG="/lxcdisk.img"
DEFAULT_SIZE_GB="50"
DEFAULT_VG="lxcDisk01"
DEFAULT_PESIZE="32M"

SUBNET="10.0.0.0/24"
GW="10.0.0.1"
NETMASK="255.255.255.0"
NETNAME="HAProxy"
BRIDGE="HAProxy"
NETXML="/etc/libvirt/qemu/networks/HAProxy.xml"

VT_SCRIPT_URL="https://raw.githubusercontent.com/uoimrun/xxos/main/virtualizor_install.sh"

GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
CYAN="\033[1;36m"
NC="\033[0m"

ok(){ echo -e "${GREEN}✔${NC} $*" >&2; }
info(){ echo -e "${CYAN}➜${NC} $*" >&2; }
warn(){ echo -e "${YELLOW}⚠${NC} $*" >&2; }
fail(){ echo -e "${RED}✘${NC} $*" >&2; }

must_root(){ [ "$(id -u)" -eq 0 ] || { fail "请先 sudo -i 或用 root 执行"; exit 1; }; }
have(){ command -v "$1" >/dev/null 2>&1; }

pm(){
  if have apt-get; then echo apt
  elif have dnf; then echo dnf
  elif have yum; then echo yum
  else echo none
  fi
}

self_fix(){ sed -i 's/\r$//' "$0" 2>/dev/null || true; }

detect_os(){
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
    OS_VER="${VERSION_ID:-}"
  else
    OS_ID="unknown"
    OS_LIKE=""
    OS_VER=""
  fi
}

ensure_repo_ready(){
  local PM="$1"
  detect_os

  if [ "$PM" = dnf ] || [ "$PM" = yum ]; then
    info "修复/准备 RHEL 系列仓库（$PM）..."

    if [ "$PM" = dnf ]; then
      dnf install -y dnf-plugins-core >/dev/null 2>&1 || true
      dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
      dnf config-manager --set-enabled powertools >/dev/null 2>&1 || true
      dnf install -y epel-release >/dev/null 2>&1 || true
    else
      yum install -y yum-utils >/dev/null 2>&1 || true
      yum install -y epel-release >/dev/null 2>&1 || true
    fi
  fi
}

sys_update(){
  local PM="$1"
  info "正在更新系统（$PM）..."

  if [ "$PM" = apt ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get upgrade -y || true
    apt-get dist-upgrade -y || true
  elif [ "$PM" = dnf ]; then
    ensure_repo_ready dnf
    dnf clean all || true
    dnf makecache || true
    dnf -y update || true
  elif [ "$PM" = yum ]; then
    ensure_repo_ready yum
    yum clean all || true
    yum -y update || true
  else
    warn "无法识别包管理器，跳过系统更新"
  fi

  ok "系统更新完成"
}

ensure_pkg(){
  local PM="$1" PKG="$2" CMD="${3:-}"
  if [ -n "$CMD" ] && have "$CMD"; then
    ok "依赖已存在：$CMD"
    return 0
  fi

  info "缺少依赖，正在安装：$PKG"
  if [ "$PM" = apt ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y "$PKG"
  elif [ "$PM" = dnf ]; then
    dnf install -y "$PKG"
  elif [ "$PM" = yum ]; then
    yum install -y "$PKG"
  else
    fail "未知包管理器，无法安装：$PKG"
    exit 1
  fi
}

install(){
  local PM="$1" PKG="$2" CMD="${3:-}"
  ensure_pkg "$PM" "$PKG" "$CMD"
}

ensure_utf8_locale(){
  local PM; PM=$(pm)
  if [ "$PM" = apt ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y locales >/dev/null 2>&1 || true
    if ! locale -a 2>/dev/null | grep -qiE "c\.utf-?8|en_US\.utf-?8"; then
      sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
      sed -i 's/^# *C.UTF-8 UTF-8/C.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
      locale-gen >/dev/null 2>&1 || true
    fi
    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8
  elif [ "$PM" = dnf ]; then
    dnf install -y glibc-langpack-en >/dev/null 2>&1 || true
    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8
  elif [ "$PM" = yum ]; then
    yum install -y glibc-langpack-en >/dev/null 2>&1 || true
    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8
  fi
}

fix_debian_cgroup_silent(){
  detect_os

  [ -f /etc/debian_version ] || return 0

  # 防重复
  [ -f "$DEB_CGROUP_MARKER" ] && return 0

  local cg
  cg=$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo "")
  local mem_enabled
  mem_enabled=$(cat /proc/cgroups 2>/dev/null | awk '$1=="memory"{print $4}' || echo "0")

  if [ "$cg" = "cgroup2fs" ] || [ "$mem_enabled" != "1" ]; then
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
    echo "fixed" > "$DEB_CGROUP_MARKER"
  fi
}


fix_el9_cgroup_silent(){
  local PM; PM=$(pm)
  detect_os

  # 只对 EL9 生效，Debian/Ubuntu完全不动
  if [[ "$OS_ID" =~ (almalinux|rocky|rhel|centos) ]] && [[ "${OS_VER:-0}" =~ ^9 ]]; then
    local cg
    cg=$(stat -fc %T /sys/fs/cgroup 2>/dev/null || echo "")
    if [ "$cg" = "cgroup2fs" ]; then
      # 防止重复写入
      if [ -f "$CGROUP_MARKER" ]; then
        return 0
      fi

      # 确保 grubby 存在
      if [ "$PM" = dnf ]; then
        dnf install -y grubby >/dev/null 2>&1 || true
      elif [ "$PM" = yum ]; then
        yum install -y grubby >/dev/null 2>&1 || true
      fi

      # 写入参数：切 cgroup v1 + 开启 swapaccount
      grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=0 swapaccount=1" >/dev/null 2>&1 || true
      echo "fixed" > "$CGROUP_MARKER"
    fi
  fi
}

lock_hosts(){
  warn "hosts 写入授权"
  grep -Fq "api.virtualizor.com" /etc/hosts || echo "152.53.227.142 api.virtualizor.com" >> /etc/hosts
  chattr +i /etc/hosts 2>/dev/null || true
  ok "hosts 已写入并锁定"
}

fix_loop(){
  modprobe loop 2>/dev/null || true
  [ -e /dev/loop-control ] || mknod -m 0660 /dev/loop-control c 10 237 2>/dev/null || true
  for i in $(seq 0 63); do
    [ -b "/dev/loop$i" ] || mknod -m 0660 "/dev/loop$i" b 7 "$i" 2>/dev/null || true
  done
  chown root:disk /dev/loop* 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  ok "loop 设备已就绪"
}

cleanup_all_loop_mappers(){
  warn "强制清理所有 loop mapper..."
  local maps
  maps=$(dmsetup ls 2>/dev/null | awk '{print $1}' | grep -E '^loop[0-9]+p[0-9]+' || true)
  [ -n "$maps" ] && echo "$maps" | while read -r mp; do
    dmsetup remove "$mp" >/dev/null 2>&1 || true
  done
  udevadm settle 2>/dev/null || true
  ok "loop mapper 清理完成"
}

cleanup_img_loops(){
  local img="$1"
  local loops
  loops=$(losetup -j "$img" 2>/dev/null | awk -F: '{print $1}' || true)
  [ -n "$loops" ] || return 0
  warn "发现残留 loop，正在释放..."
  for L in $loops; do
    [ -b "$L" ] || continue
    umount "${L}p1" 2>/dev/null || true
    umount "${L}p2" 2>/dev/null || true

    local dmmaps
    dmmaps=$(dmsetup ls 2>/dev/null | awk '{print $1}' | grep -E "^$(basename "$L")p" || true)
    [ -n "$dmmaps" ] && echo "$dmmaps" | while read -r mp; do
      dmsetup remove "$mp" >/dev/null 2>&1 || true
    done

    losetup -d "$L" >/dev/null 2>&1 || true
  done
  udevadm settle 2>/dev/null || true
  ok "残留 loop 已清理"
}

reset_storage_force(){
  local img="$1"
  local vg="$2"
  warn "强制重装：清空旧存储..."

  cleanup_img_loops "$img" || true
  cleanup_all_loop_mappers || true

  if vgdisplay "$vg" >/dev/null 2>&1; then
    vgchange -an "$vg" >/dev/null 2>&1 || true
    vgremove -ff "$vg" >/dev/null 2>&1 || true
  fi

  local loop_pvs
  loop_pvs=$(pvs --noheadings -o pv_name 2>/dev/null | awk '{print $1}' | grep -E '^/dev/loop' || true)
  [ -n "$loop_pvs" ] && echo "$loop_pvs" | while read -r pv; do
    pvremove -ff -y "$pv" >/dev/null 2>&1 || true
  done

  [ -f "$img" ] && rm -f "$img" >/dev/null 2>&1 || true
  rm -f "$MARKER" >/dev/null 2>&1 || true
  ok "旧存储已全部删除 ✅"
}

make_img(){
  local img="$1" size="$2"
  info "创建虚拟盘：${size}G → $img"
  if have fallocate; then
    fallocate -l "${size}G" "$img"
  else
    dd if=/dev/zero of="$img" bs=1M seek=$((size*1000)) count=0
  fi
  ok "虚拟盘创建完成"
}

attach_loop(){
  local img="$1"
  fix_loop
  local loopdev
  loopdev=$(losetup -fP --show "$img" 2>/dev/null || true)
  [ -n "$loopdev" ] && [ -b "$loopdev" ] || { fail "losetup 失败"; exit 1; }
  partprobe "$loopdev" >/dev/null 2>&1 || true
  udevadm settle 2>/dev/null || true
  ok "loop 挂载：$loopdev"
  printf '%s\n' "$loopdev"
}

part_lvm(){
  local loopdev="$1"
  info "写入分区表..."
  parted -s "$loopdev" mklabel msdos >/dev/null 2>&1
  parted -s "$loopdev" mkpart primary 1MiB 100% >/dev/null 2>&1
  parted -s "$loopdev" set 1 lvm on >/dev/null 2>&1
  partprobe "$loopdev" >/dev/null 2>&1 || true
  udevadm settle >/dev/null 2>&1 || true
  local part="${loopdev}p1"
  [ -b "$part" ] || { fail "分区未生成：$part"; exit 1; }
  ok "分区完成：$part"
  printf '%s\n' "$part"
}

mk_lvm(){
  local part="$1" vg="$2" pesize="$3"
  info "初始化 LVM：$vg"
  pvcreate -ff -y "$part" >/dev/null 2>&1 || true
  vgcreate -s "$pesize" "$vg" "$part" >/dev/null 2>&1 || true
  vgscan --cache >/dev/null 2>&1 || true
  vgchange -ay "$vg" >/dev/null 2>&1 || true
  ok "LVM 已激活：/dev/$vg"
}

loop_autostart(){
  local img="$1" vg="$2"
  cat > /etc/systemd/system/lxcdisk-loop.service <<EOF
[Unit]
Description=Attach loop device for ${img} and activate LVM
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/losetup -fP ${img}
ExecStart=/sbin/vgscan --cache
ExecStart=/sbin/vgchange -ay ${vg}
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now lxcdisk-loop.service >/dev/null 2>&1 || true
  ok "开机自动挂载已启用"
}

fix_debian_lxc(){
  [ -f /etc/debian_version ] || return 0
  [ -f /usr/local/virtualizor/conf/lxc-common.conf ] && cat > /usr/local/virtualizor/conf/lxc-common.conf <<'EOF'
lxc.apparmor.profile = unconfined
lxc.mount.auto = proc:rw sys:rw cgroup:rw
lxc.autodev = 1
lxc.pty.max = 1024
EOF
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y lxcfs >/dev/null 2>&1 || true
  mkdir -p /usr/local/virtualizor-bin/share/lxcfs
  [ -f /usr/share/lxcfs/lxc.mount.hook ] && ln -sf /usr/share/lxcfs/lxc.mount.hook /usr/local/virtualizor-bin/share/lxcfs/lxc.mount.hook
  [ -f /usr/share/lxcfs/lxc.reboot.hook ] && ln -sf /usr/share/lxcfs/lxc.reboot.hook /usr/local/virtualizor-bin/share/lxcfs/lxc.reboot.hook
  systemctl enable --now lxcfs >/dev/null 2>&1 || true
  ok "Debian LXC 修复完成"
}

install_vt(){
  local email="$1"
  local PM; PM=$(pm)

  install "$PM" ca-certificates update-ca-certificates || true
  install "$PM" curl curl || true
  install "$PM" wget wget || true

  cd /root
  info "下载 Virtualizor 安装脚本..."
  curl -fsSL "$VT_SCRIPT_URL" -o /root/virtualizor_install.sh || { fail "下载安装脚本失败"; exit 1; }
  chmod +x /root/virtualizor_install.sh

  info "安装 Virtualizor（请耐心等待）..."
  /root/virtualizor_install.sh email="$email" kernel=lxc

  fix_debian_lxc
  service virtualizor restart >/dev/null 2>&1 || true
  ok "面板安装完成"
}

save_marker(){
  cat > "$MARKER" <<EOF
IMG=$1
VG=$2
EOF
}

load_marker(){
  [ -f "$MARKER" ] || { fail "找不到 marker，请先执行第一步"; exit 1; }
  source "$MARKER"
}

stage1(){
  must_root
  self_fix
  local PM; PM=$(pm); [ "$PM" != none ] || { fail "未知系统"; exit 1; }

  ensure_utf8_locale
  sys_update "$PM"

  fix_el9_cgroup_silent
  fix_debian_cgroup_silent


  install "$PM" ca-certificates update-ca-certificates || true
  install "$PM" curl curl || install "$PM" wget wget

  install "$PM" util-linux losetup
  install "$PM" kmod modprobe
  install "$PM" parted parted
  install "$PM" lvm2 vgcreate
  install "$PM" e2fsprogs chattr
  install "$PM" dmsetup dmsetup || true

  lock_hosts
  fix_loop

  echo >&2
  read -rp "虚拟盘文件（默认 $DEFAULT_IMG）： " IMG_PATH; IMG_PATH="${IMG_PATH:-$DEFAULT_IMG}"
  read -rp "虚拟盘大小GB（默认 $DEFAULT_SIZE_GB）： " SIZE_GB; SIZE_GB="${SIZE_GB:-$DEFAULT_SIZE_GB}"
  read -rp "卷组VG（默认 $DEFAULT_VG）： " VGNAME; VGNAME="${VGNAME:-$DEFAULT_VG}"
  read -rp "PE 大小（默认 $DEFAULT_PESIZE）： " PESIZE; PESIZE="${PESIZE:-$DEFAULT_PESIZE}"
  read -rp "面板邮箱： " EMAIL; [ -n "$EMAIL" ] || { fail "邮箱不能为空"; exit 1; }

  reset_storage_force "$IMG_PATH" "$VGNAME" || true
  make_img "$IMG_PATH" "$SIZE_GB"
  LOOP=$(attach_loop "$IMG_PATH")
  PART=$(part_lvm "$LOOP")
  mk_lvm "$PART" "$VGNAME" "$PESIZE"
  loop_autostart "$IMG_PATH" "$VGNAME"
  save_marker "$IMG_PATH" "$VGNAME"
  ok "存储路径：/dev/${VGNAME}"

  install_vt "$EMAIL"

  warn "安装面板 + 磁盘 + LVM 完成，即将重启..."
  sleep 3
  reboot
}

stage2(){
  must_root
  self_fix
  local PM; PM=$(pm); [ "$PM" != none ] || { fail "未知系统"; exit 1; }

  ensure_utf8_locale
  load_marker

  if [ "$PM" = apt ]; then
    install "$PM" libvirt-daemon-system libvirtd
    install "$PM" libvirt-clients virsh
    install "$PM" iptables iptables
    install "$PM" iptables-persistent netfilter-persistent || true
    install "$PM" curl curl || true
    install "$PM" wget wget || true
  else
    install "$PM" libvirt libvirtd || true
    install "$PM" libvirt-client virsh || true
    install "$PM" iptables iptables
    install "$PM" iptables-services service || true
    install "$PM" curl curl || true
    install "$PM" wget wget || true
  fi

  systemctl enable --now libvirtd >/dev/null 2>&1 || true

  mkdir -p /etc/libvirt/qemu/networks
  cat > "$NETXML" <<EOF
<network>
  <name>${NETNAME}</name>
  <forward mode='nat'/>
  <bridge name='${BRIDGE}' stp='on' delay='0' />
  <ip address='${GW}' netmask='${NETMASK}'></ip>
</network>
EOF

  virsh net-define "$NETXML" >/dev/null 2>&1 || true
  virsh net-autostart "$NETNAME" >/dev/null 2>&1 || true
  virsh net-start "$NETNAME" >/dev/null 2>&1 || true

  if [ "$PM" != apt ]; then
    systemctl enable --now iptables >/dev/null 2>&1 || true
  fi

  echo 1 > /proc/sys/net/ipv4/ip_forward
  grep -Fq "net.ipv4.ip_forward = 1" /etc/sysctl.conf || echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1 || true
  iptables -F >/dev/null 2>&1 || true
  iptables -t nat -F >/dev/null 2>&1 || true
  iptables -X >/dev/null 2>&1 || true

  iptables -P INPUT ACCEPT >/dev/null 2>&1 || true
  iptables -P FORWARD ACCEPT >/dev/null 2>&1 || true
  iptables -P OUTPUT ACCEPT >/dev/null 2>&1 || true
  iptables -t nat -A POSTROUTING -s "$SUBNET" -j MASQUERADE >/dev/null 2>&1 || true
  if have netfilter-persistent; then
    netfilter-persistent save >/dev/null 2>&1 || true
  elif have service; then
    service iptables save >/dev/null 2>&1 || true
  fi

  REAL_IP=""
  if have curl; then
    REAL_IP=$(curl -4s --max-time 3 ifconfig.me 2>/dev/null || true)
    [ -n "$REAL_IP" ] || REAL_IP=$(curl -4s --max-time 3 ip.sb 2>/dev/null || true)
  elif have wget; then
    REAL_IP=$(wget -qO- --timeout=3 --tries=1 -4 ifconfig.me 2>/dev/null || true)
    [ -n "$REAL_IP" ] || REAL_IP=$(wget -qO- --timeout=3 --tries=1 -4 ip.sb 2>/dev/null || true)
  fi
  if [ -z "$REAL_IP" ]; then
    REAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}' || true)
  fi
  [ -n "$REAL_IP" ] || REAL_IP="YOUR_SERVER_IP"

  ok "配置 NAT 网络 + 转发 完成 ✅"

  read -rp "下载 LXC 模板（debian11/12）? [Y/n]：" DL_TPL
  DL_TPL="${DL_TPL:-Y}"
  if [[ "$DL_TPL" =~ ^[Yy]$ ]]; then
    mkdir -p /var/virtualizor/lxc
    cd /var/virtualizor/lxc

    rm -rf ./* ./.??* 2>/dev/null || true

    wget -q --show-progress -O debian-11-x86_64.tar.gz \
      https://github.com/hiapb/os/releases/download/os/debian-11-x86_64.tar.gz

    wget -q --show-progress -O debian-12.0-x86_64.tar.gz \
      https://github.com/hiapb/os/releases/download/os/debian-12.0-x86_64.tar.gz

    ok "LXC 模板已自动下载：debian-11 / debian-12 ✅"
  fi

  read -rp "执行 NAT 调优脚本? [Y/n]：" DO_TUNE
  DO_TUNE="${DO_TUNE:-Y}"
  if [[ "$DO_TUNE" =~ ^[Yy]$ ]]; then
    bash <(curl -fsSL https://raw.githubusercontent.com/nuro-hia/tuning/main/install.sh) >/dev/null 2>&1 || true
    ok "NAT 调优已执行 ✅"
  fi

  # ✅ 开机自动重启无IP容器（systemd 方式，稳定）
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
  ok "已启用：宿主机重启后自动启动 所有LXC 容器 ✅"


  echo >&2
  echo -e "面板地址：${GREEN}https://${REAL_IP}:4085${NC} 或 ${GREEN}http://${REAL_IP}:4084${NC}" >&2
  echo -e "存储路径：${GREEN}/dev/${VG}${NC}" >&2
  echo -e "NAT 网段：${GREEN}$SUBNET${NC}  网关：${GREEN}$GW${NC}" >&2
  exit 0
}


menu(){
  clear
  echo -e "${GREEN}Virtualizor 一键安装脚本${NC}" >&2
  echo "----------------------------------" >&2
  echo "1) 安装面板 + 磁盘 + LVM" >&2
  echo "2) 配置 NAT 网络 + 转发" >&2
  echo "0) 退出" >&2
  echo "----------------------------------" >&2
  read -rp "请选择 [0-2]：" c
  case "$c" in
    1) stage1 ;;
    2) stage2 ;;
    0) exit 0 ;;
    *) warn "输入无效"; sleep 1 ;;
  esac
}

while true; do menu; done
