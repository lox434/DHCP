#!/usr/bin/env bash
set -euo pipefail

need_root() { [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }; }

ask() {
  local prompt="$1" default="${2:-}"
  local var
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " var || true
    echo "${var:-$default}"
  else
    read -r -p "$prompt: " var || true
    echo "$var"
  fi
}

write_alt_iface_dhcp() {
  local ifname="$1"
  mkdir -p "/etc/net/ifaces/$ifname"
  cat >"/etc/net/ifaces/$ifname/options" <<EOF
ONBOOT=yes
BOOTPROTO=dhcp
TYPE=eth
NM_CONTROLLED=no
EOF
}

setup_ssh_port_and_user() {
  local ssh_port="$1"
  local do_user="$2"

  if [[ -n "$ssh_port" ]]; then
    if grep -qE '^\s*#?\s*Port\s+' /etc/openssh/sshd_config; then
      sed -i "s/^\s*#\?\s*Port\s\+.*/Port $ssh_port/" /etc/openssh/sshd_config
    else
      echo "Port $ssh_port" >> /etc/openssh/sshd_config
    fi
    systemctl restart sshd || systemctl restart ssh || true
  fi

  if [[ "$do_user" == "y" ]]; then
    id sshuser >/dev/null 2>&1 || useradd sshuser
    echo "Set password for sshuser:"
    passwd sshuser
    apt-get install -y sudo htop

    cat > /etc/sudoers.d/sshuser <<'EOF'
Cmnd_Alias POWER = /sbin/shutdown, /sbin/reboot, /usr/sbin/shutdown, /usr/sbin/reboot
Cmnd_Alias HTOP  = /usr/bin/htop
sshuser ALL=(root) NOPASSWD: POWER, HTOP
EOF
    chmod 0400 /etc/sudoers.d/sshuser
    visudo -c
  fi
}

raid_devices_hint() {
  echo "Доступные диски (проверь, что это НЕ системный диск!):"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | sed 's/^/  /'
  echo "Под RAID обычно берут /dev/vdb /dev/vdc /dev/vdd (как в гайде)"
}

setup_raid_and_nfs() {
  local raid_level="$1" md="/dev/md0" mount_dir="$2" export_net="$3"

  apt-get install -y mdadm nfs-server rpcbind

  raid_devices_hint
  local devs
  devs="$(ask "Укажи устройства под RAID через пробел (пример: /dev/vdb /dev/vdc /dev/vdd)" "/dev/vdb /dev/vdc /dev/vdd")"

  local dev_count
  dev_count="$(wc -w <<<"$devs" | tr -d ' ')"

  echo "Создаю RAID$raid_level на $md из $dev_count дисков: $devs"
  mdadm --create "$md" --level="$raid_level" --raid-devices="$dev_count" $devs

  echo "Проверка:"
  cat /proc/mdstat || true
  mdadm --detail "$md" || true

  echo "Форматирование и монтирование"
  mkfs.ext4 -L "RAID${raid_level}" "$md"
  mkdir -p "$mount_dir"

  UUID="$(blkid -s UUID -o value "$md")"
  grep -qF "UUID=$UUID" /etc/fstab || echo "UUID=$UUID $mount_dir ext4 defaults 0 2" >> /etc/fstab
  mount -a

  echo "Сохранить конфиг mdadm"
  mdadm --detail --scan >> /etc/mdadm.conf

  echo "NFS server enable"
  systemctl enable --now rpcbind
  systemctl enable --now nfs-server

  cat > /etc/exports <<EOF
$mount_dir $export_net(rw,sync,no_subtree_check)
EOF
  exportfs -ra
  chmod 777 "$mount_dir"

  echo "Проверка экспорта:"
  exportfs -v
}

main() {
  need_root
  echo "=== SRV setup ==="

  local variant lan_if ssh_port do_user raid_level do_raid net_cidr mount_dir

  variant="$(ask "Variant (используется в имени каталога RAID)" "ssa")"
  lan_if="$(ask "LAN интерфейс (получает IP по DHCP от ISP)" "ens18")"
  net_cidr="$(ask "Подсеть экспорта NFS (x.y.z.0/24)" "10.0.128.0/24")"

  ssh_port="$(ask "SSH порт для SRV (пусто = не менять)" "2223")"
  do_user="$(ask "Создать sshuser + sudo(POWER,HTOP)? (y/n)" "y")"

  do_raid="$(ask "Настраивать RAID+FS+NFS? (y/n)" "y")"
  raid_level="$(ask "Какой RAID? (0/1/5)" "5")"

  mount_dir="/mnt/raid_${variant}"

  hostnamectl hostname Server

  write_alt_iface_dhcp "$lan_if"
  systemctl restart network

  setup_ssh_port_and_user "$ssh_port" "$do_user"

  if [[ "$do_raid" == "y" ]]; then
    setup_raid_and_nfs "$raid_level" "$mount_dir" "$net_cidr"
  else
    echo "RAID/NFS пропущены."
  fi

  echo
  echo "DONE."
}

main "$@"
