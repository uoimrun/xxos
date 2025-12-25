#!/bin/bash
clear

setenforce 0 >> /dev/null 2>&1

FILEREPO=https://files.virtualizor.com
LOG=/root/virtualizor.log
mirror_url=files.softaculous.com

for i in $@
do
        if [[ $i == mirror_url* ]]; then
        IFS='=' read -ra tmp_array <<< "$i"
        mirror_url=${tmp_array[1]}/a/softaculous/files
        fi
done

#----------------------------------
# Detecting the Architecture
#----------------------------------
if ([ `uname -i` == x86_64 ] || [ `uname -i` == amd64 ] || [ `uname -m` == x86_64 ] || [ `uname -m` == amd64 ]); then
        ARCH=64
else
        ARCH=32
fi

echo "-----------------------------------------------"
echo " Welcome to Virtualizor Installer"
echo "-----------------------------------------------"
echo "To monitor installation : tail -f /root/virtualizor.log"
echo " "

#----------------------------------
# Some checks before we proceed
#----------------------------------

# Gets Distro type.
if [ -d /etc/pve ]; then
        OS=Proxmox
        REL=$(/usr/bin/pveversion)
        PVE_VERSION=$(echo "$REL" | cut -d'/' -f2)
        IFS='.' read -r PVE_MAJOR_VERSION PVE_MINOR_VERSION PVE_PATCH_VERSION <<< "$PVE_VERSION"

elif [ -f /etc/debian_version ]; then

        # =======================
        # [MIN PATCH #1] Debian/Ubuntu ensure lsb_release + python3
        # =======================
        if ! command -v lsb_release >/dev/null 2>&1; then
                apt-get update -y >> $LOG 2>&1
                apt-get install -y lsb-release >> $LOG 2>&1
        fi
        if ! command -v python3 >/dev/null 2>&1; then
                apt-get update -y >> $LOG 2>&1
                apt-get install -y python3 >> $LOG 2>&1
        fi

        OS_ACTUAL=$(lsb_release -i | cut -f2)
        OS=Ubuntu
        REL=$(cat /etc/issue)

elif [ -f /etc/redhat-release ]; then
        OS=redhat 
        REL=$(cat /etc/redhat-release)
else
        OS=$(uname -s)
        REL=$(uname -r)
fi

if [[ "$REL" == *"CentOS release 6"* ]] || [[ "$REL" == *"CentOS Linux release 7"* ]]; then
        echo "Virtualizor only supports CentOS 8 and Centos 9, as Centos 6,7 are EOL and their repository is not available for package downloads."
        echo "Exiting installer"
        exit 1;
fi

if [ "$OS" = Ubuntu ] ; then

        # We dont need to check for Debian
        if [ "$OS_ACTUAL" = Ubuntu ] ; then

                VER=$(lsb_release -r | cut -f2)

                if  [ "$VER" != "12.04" -a "$VER" != "14.04" -a "$VER" != "16.04" -a "$VER" != "18.04" -a "$VER" != "20.04" -a "$VER" != "22.04" -a "$VER" != "24.04" ]; then
                        echo "Virtualizor only supports Ubuntu 12.04 LTS, Ubuntu 14.04 LTS, Ubuntu 16.04 LTS, Ubuntu 18.04 LTS, Ubuntu 20.04 LTS, Ubuntu 22.04 LTS and Ubuntu 24.04 LTS"
                        echo "Exiting installer"
                        exit 1;
                fi

                if ! [ -f /etc/default/grub ] ; then
                        echo "Virtualizor only supports GRUB 2 for Ubuntu based server"
                        echo "Follow the Below guide to upgrade to grub2 :-"
                        echo "https://help.ubuntu.com/community/Grub2/Upgrading"
                        echo "Exiting installer"
                        exit 1;
                fi

        fi

fi

theos="$(echo $REL | grep -E -i '(cent|Scie|Red|Ubuntu|xen|Virtuozzo|pve-manager|Debian|AlmaLinux|Rocky)' )"

if [ "$?" -ne "0" ]; then
        echo "Virtualizor can be installed only on CentOS, AlmaLinux, Rocky Linux, Redhat, Scientific Linux, Ubuntu, XenServer, Virtuozzo and Proxmox"
        echo "Exiting installer"
        exit 1;
fi

# Is Webuzo installed ?
if [ -d /usr/local/webuzo ]; then
        echo "Server has webuzo installed. Virtualizor can not be installed."
        echo "Exiting installer"
        exit 1;
fi

#----------------------------------
# Is there an existing Virtualizor
#----------------------------------
if [ -d /usr/local/virtualizor ]; then

        echo "An existing installation of Virtualizor has been detected !"
        echo "If you continue to install Virtualizor, the existing installation"
        echo "and all its Data will be lost"
        echo -n "Do you want to continue installing ? [y/N]"

        read over_ride_install

        if ([ "$over_ride_install" == "N" ] || [ "$over_ride_install" == "n" ]); then    
                echo "Exiting Installer"
                exit;
        fi

fi

#----------------------------------
# Enabling Virtualizor repo
#----------------------------------
if [ "$OS" = redhat ] ; then

        # Is yum there ?
        if ! [ -f /usr/bin/yum ] ; then
                echo "YUM wasnt found on the system. Please install YUM !"
                echo "Exiting installer"
                exit 1;
        fi

        wget --no-check-certificate https://mirror.softaculous.com/virtualizor/virtualizor.repo -O /etc/yum.repos.d/virtualizor.repo >> $LOG 2>&1

fi

#----------------------------------
# Install some LIBRARIES
#----------------------------------
echo "1) Installing Libraries and Dependencies"
echo "1) Installing Libraries and Dependencies" >> $LOG 2>&1

if [ "$OS" = redhat  ] ; then
        yum -y --enablerepo=base --skip-broken install tar >> $LOG 2>&1
        yum -y --enablerepo=updates update glibc libstdc++ tar >> $LOG 2>&1
        yum -y --enablerepo=base --skip-broken install e4fsprogs sendmail gcc gcc-c++ openssl unzip apr make vixie-cron crontabs fuse kpartx iputils >> $LOG 2>&1
        yum -y --enablerepo=base --skip-broken install postfix >> $LOG 2>&1
        yum -y --enablerepo=updates update e2fsprogs >> $LOG 2>&1
        yum -y install libxcrypt-compat >> $LOG 2>&1

elif [ "$OS" = Ubuntu  ] ; then

        apt-get update -y >> $LOG 2>&1
        apt-get install -y kpartx gcc openssl unzip sendmail make cron fuse e2fsprogs tar wget >> $LOG 2>&1

elif [ "$OS" = Proxmox  ] ; then
        apt-get update -y >> $LOG 2>&1
        apt-get install -y kpartx gcc openssl unzip make e2fsprogs tar wget >> $LOG 2>&1
fi


#----------------------------------
# Install PHP, MySQL, Web Server
#----------------------------------
echo "2) Installing PHP, MySQL and Web Server"

# Stop all the services of EMPS if they were there.
/usr/local/emps/bin/mysqlctl stop >> $LOG 2>&1
/usr/local/emps/bin/nginxctl stop >> $LOG 2>&1
/usr/local/emps/bin/fpmctl stop >> $LOG 2>&1

# Remove the EMPS package
rm -rf /usr/local/emps/ >> $LOG 2>&1

# The necessary folders
mkdir /usr/local/emps >> $LOG 2>&1
mkdir /usr/local/virtualizor >> $LOG 2>&1

echo "1) Installing PHP, MySQL and Web Server" >> $LOG 2>&1
wget --no-check-certificate  -N -O /usr/local/virtualizor/EMPS.tar.gz "https://$mirror_url/emps.php?latest=1&arch=$ARCH" >> $LOG 2>&1

# Extract EMPS
tar -xvzf /usr/local/virtualizor/EMPS.tar.gz -C /usr/local/emps >> $LOG 2>&1
rm -rf /usr/local/virtualizor/EMPS.tar.gz >> $LOG 2>&1

#----------------------------------
# Download and Install Virtualizor
#----------------------------------
echo "3) Downloading and Installing Virtualizor"
echo "3) Downloading and Installing Virtualizor" >> $LOG 2>&1

# Get our installer
wget --no-check-certificate  -O /usr/local/virtualizor/install.php $FILEREPO/install.inc >> $LOG 2>&1


# =======================
# [MIN PATCH #2] Debian only: patch ONLY the false 32bit LXC check in install.php
# =======================
if [ -f /etc/debian_version ]; then
        echo "[PATCH] Debian detected -> patching ONLY LXC 32bit check..." >> $LOG 2>&1

        python3 - <<'PY'
import re

path = "/usr/local/virtualizor/install.php"
data = open(path, "r", encoding="utf-8", errors="ignore").read()

key = "Lxc can not be installed in 32 Bit Operating System"
pos = data.find(key)
if pos == -1:
    print("[-] keyword not found, skip patch")
    raise SystemExit(0)

start = data.rfind("if", 0, pos)
if start == -1:
    print("[-] could not locate if, skip patch")
    raise SystemExit(0)

p1 = data.find("(", start)
if p1 == -1:
    print("[-] could not locate (, skip patch")
    raise SystemExit(0)

depth = 0
p2 = None
for i in range(p1, len(data)):
    if data[i] == "(":
        depth += 1
    elif data[i] == ")":
        depth -= 1
        if depth == 0:
            p2 = i
            break

if p2 is None:
    print("[-] could not match ), skip patch")
    raise SystemExit(0)

orig_cond = data[p1:p2+1]
new_cond = "(false && " + orig_cond + ")"

patched = data[:p1] + new_cond + data[p2+1:]
open(path, "w", encoding="utf-8", errors="ignore").write(patched)

print("[+] patched ONLY LXC 32bit check via if(false && (...))")
PY
fi
# =======================
# PATCH END
# =======================

# Run our installer
/usr/local/emps/bin/php -d zend_extension=/usr/local/emps/lib/php/ioncube_loader_lin_5.3.so /usr/local/virtualizor/install.php $*
phpret=$?
rm -rf /usr/local/virtualizor/install.php >> $LOG 2>&1
rm -rf /usr/local/virtualizor/upgrade.php >> $LOG 2>&1

# Was there an error
if ! [ $phpret == "8" ]; then
        echo " "
        echo "ERROR :"
        echo "There was an error while installing Virtualizor"
        echo "Please check /root/virtualizor.log for errors"
        echo "Exiting Installer"    
        exit 1;
fi

#----------------------------------
# Debian FIX after install (LXC)
#----------------------------------
if [ -f /etc/debian_version ]; then
        echo "[PATCH] Debian post-install fix: lxc-common.conf + lxcfs hooks" >> $LOG 2>&1

        # 1) Fix lxc-common.conf old keys (lxc.pts/lxc.tty)
        if [ -f /usr/local/virtualizor/conf/lxc-common.conf ]; then
                cp -a /usr/local/virtualizor/conf/lxc-common.conf /usr/local/virtualizor/conf/lxc-common.conf.bak_$(date +%s) >> $LOG 2>&1
                cat > /usr/local/virtualizor/conf/lxc-common.conf <<'EOF'
# Virtualizor LXC common config (Debian compatible)
lxc.apparmor.profile = unconfined
lxc.mount.auto = proc:rw sys:rw cgroup:rw
lxc.autodev = 1
lxc.pty.max = 1024
EOF
        fi

        # 2) Install lxcfs + provide expected hooks
        apt-get update -y >> $LOG 2>&1
        apt-get install -y lxcfs >> $LOG 2>&1

        mkdir -p /usr/local/virtualizor-bin/share/lxcfs >> $LOG 2>&1

        [ -f /usr/share/lxcfs/lxc.mount.hook ] && ln -sf /usr/share/lxcfs/lxc.mount.hook /usr/local/virtualizor-bin/share/lxcfs/lxc.mount.hook
        [ -f /usr/share/lxcfs/lxc.reboot.hook ] && ln -sf /usr/share/lxcfs/lxc.reboot.hook /usr/local/virtualizor-bin/share/lxcfs/lxc.reboot.hook

        systemctl enable --now lxcfs >> $LOG 2>&1 || true
fi

#----------------------------------
# Starting Virtualizor Services
#----------------------------------
echo "Starting Virtualizor Services" >> $LOG 2>&1
/etc/init.d/virtualizor restart >> $LOG 2>&1

wget --no-check-certificate  -O /tmp/ip.php https://softaculous.com/ip.php >> $LOG 2>&1
ip=$(cat /tmp/ip.php)
rm -rf /tmp/ip.php

echo " "
echo "-------------------------------------"
echo " Installation Completed "
echo "-------------------------------------"
clear
echo "Congratulations, Virtualizor has been successfully installed"
echo " "
/usr/local/emps/bin/php -r 'define("VIRTUALIZOR", 1); include("/usr/local/virtualizor/universal.php"); echo "API KEY : ".$globals["key"]."\nAPI Password : ".$globals["pass"];'
echo " "
echo "You can login to the Virtualizor Admin Panel"
echo "https://$ip:4085/"
echo "OR"
echo "http://$ip:4084/"
echo " "
echo -n "Do you want to reboot now ? [y/N]"
read rebBOOT

echo "Thank you for choosing Virtualizor by Softaculous !"

if ([ "$rebBOOT" == "Y" ] || [ "$rebBOOT" == "y" ]); then
        echo "The system is now being RESTARTED"
        reboot;
fi
