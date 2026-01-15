#!/usr/bin/env bash
set -euo pipefail

# SRV setup for ALT Linux (DHCP on LAN, optional RAID+NFS, optional Samba AD DC provisioning)
# v2: adds Samba AD DC block from your guide + sudo suid fix for sshuser

need_root() { [[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }; }

fix_sudoers_permissions() {
  local f="/etc/sudoers.d/99-sudopw"
  if [[ -e "$f" ]]; then
    chown root:root "$f" || true
    chmod 0400 "$f" || true
  fi
}

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

    chown root:root /usr/bin/sudo || true
    chmod 4755 /usr/bin/sudo || true

    visudo -c
    sudo -l -U sshuser || true
  fi
}

raid_devices_hint() {
  echo "Доступные диски (проверь, что это НЕ системный диск!):"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | sed 's/^/  /'
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

  echo "NFS"
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

setup_samba_ad_dc() {
  local realm="$1" workgroup="$2" adminpass="$3" lan_if="$4" dns_forwarder="$5"
  local dc_hostname="$6"
  local variant="$7"

  apt-get install -y task-samba-dc

  # Stop conflicting services (from guide)
  systemctl disable --now bind krb5kdc nmb smb slapd 2>/dev/null || true

  rm -f /etc/samba/smb.conf || true
  rm -rf /var/lib/samba /var/cache/samba || true
  mkdir -p /var/lib/samba/sysvol

  hostnamectl hostname "$dc_hostname"

  echo "Provision Samba AD DC (realm=$realm, workgroup=$workgroup)"
  samba-tool domain provision \
    --realm="$realm" \
    --domain="$workgroup" \
    --adminpass="$adminpass" \
    --dns-backend=SAMBA_INTERNAL \
    --server-role=dc \
    --option="dns forwarder=$dns_forwarder"

  systemctl enable --now samba

  # Make local DNS resolver point to Samba internal DNS
  mkdir -p "/etc/net/ifaces/$lan_if"
  echo "nameserver 127.0.0.1" > "/etc/net/ifaces/$lan_if/resolv.conf"
  systemctl restart network

  echo "Проверки:"
  samba-tool domain info 127.0.0.1 || true
  smbclient -L localhost -U administrator || true
  host "$realm" || true

  # Create users + group (from guide)
  samba-tool user create "${variant}_1" "$adminpass"
  samba-tool user create "${variant}_2" "$adminpass"
  samba-tool user create "${variant}_3" "$adminpass"

  samba-tool group create "${variant}_group"
  samba-tool group addmembers "${variant}_group" "${variant}_1,${variant}_2,${variant}_3"

  echo
  echo "Samba AD DC готов. По гайду после этого делается reboot."
}

main() {
  need_root
  fix_sudoers_permissions
  echo "=== SRV setup ==="

  local variant lan_if ssh_port do_user raid_level do_raid net_cidr mount_dir
  local do_samba realm workgroup adminpass dns_forwarder dc_hostname

  variant="$(ask "Variant (используется в именах, напр. ssa)" "ssa")"
  variant_num="$(echo "$variant" | tr -cd '0-9')"
  lan_if="$(ask "LAN интерфейс (получает IP по DHCP от ISP)" "ens18")"
  net_cidr="$(ask "Подсеть LAN (для exports/NFS и др.)" "10.0.128.0/24")"

  ssh_port="$(ask "SSH порт для SRV (пусто = не менять)" "2223")"
  do_user="$(ask "Создать sshuser + sudo(POWER,HTOP)? (y/n)" "y")"

  do_raid="$(ask "Настраивать RAID+FS+NFS? (y/n)" "y")"
  raid_level="$(ask "Какой RAID? (0/1/5)" "5")"
  mount_dir="/mnt/raid_${variant_num}"

  do_samba="$(ask "Поднимать Samba AD DC на SRV? (y/n)" "n")"
  realm="$(ask "Samba realm (FQDN), например ${variant}.sa" "${variant}.sa")"
  workgroup="$(ask "Workgroup/NETBIOS domain (короткое), например ${variant}" "${variant}")"
  adminpass="$(ask "Пароль администратора домена (и пароль для ${variant}_1..3)" "P@ssw0rd")"
  dns_forwarder="$(ask "DNS forwarder" "8.8.8.8")"
  dc_hostname="$(ask "Hostname для DC (должен быть НЕ равен домену)" "SRV-DC")"

  hostnamectl hostname Server

  write_alt_iface_dhcp "$lan_if"
  systemctl restart network

  setup_ssh_port_and_user "$ssh_port" "$do_user"

  if [[ "$do_raid" == "y" ]]; then
    setup_raid_and_nfs "$raid_level" "$mount_dir" "$net_cidr"
  else
    echo "RAID/NFS пропущены."
  fi

  if [[ "$do_samba" == "y" ]]; then
    setup_samba_ad_dc "$realm" "$workgroup" "$adminpass" "$lan_if" "$dns_forwarder" "$dc_hostname" "$variant"
    echo "Если хочешь — сейчас сделай: reboot"
  fi

  echo
  echo "DONE."
}

main "$@"
