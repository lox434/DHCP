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

setup_nfs_mount() {
  local srv_ip="$1" export_dir="$2" mount_point="$3"
  apt-get install -y nfs-utils

  mkdir -p "$mount_point"
  showmount -e "$srv_ip" || true

  local fstab_line="${srv_ip}:${export_dir} ${mount_point} nfs defaults,_netdev 0 0"
  grep -qF "$fstab_line" /etc/fstab || echo "$fstab_line" >> /etc/fstab

  mount -a

  echo "Проверка:"
  df -h | grep -E " ${mount_point}\$" || true
  touch "${mount_point}/test_from_cli" || true
  ls -la "$mount_point" | tail || true
}

setup_ssh_client_aliases() {
  local isp_ip="$1" isp_port="$2" srv_ip="$3" srv_port="$4"
  local do_keys="$5"

  if [[ "$do_keys" == "y" ]]; then
    command -v ssh-keygen >/dev/null 2>&1 || apt-get install -y openssh-clients
    [[ -f ~/.ssh/id_rsa ]] || ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa

    echo "Дальше введёшь пароль sshuser для копирования ключей:"
    ssh-copy-id -p "$isp_port" sshuser@"$isp_ip" || true
    ssh-copy-id -p "$srv_port" sshuser@"$srv_ip" || true
  fi

  mkdir -p ~/.ssh
  cat > ~/.ssh/config <<EOF
Host ISP
  HostName $isp_ip
  User sshuser
  Port $isp_port
  IdentityFile ~/.ssh/id_rsa

Host srv
  HostName $srv_ip
  User sshuser
  Port $srv_port
  IdentityFile ~/.ssh/id_rsa
EOF
  chmod 600 ~/.ssh/config

  echo "Проверка: ssh ISP ; ssh srv"
}

main() {
  need_root
  echo "=== CLI setup ==="

  local variant lan_if srv_ip isp_ip net_cidr mount_point do_ssh isp_port srv_port do_keys export_dir

  variant="$(ask "Variant (должен совпадать с SRV, чтобы путь /mnt/raid_<variant>)" "ssa")"
  lan_if="$(ask "LAN интерфейс (DHCP)" "ens18")"
  isp_ip="$(ask "IP ISP в LAN" "10.0.128.1")"
  srv_ip="$(ask "IP SRV в LAN" "10.0.128.2")"
  net_cidr="$(ask "Подсеть (для информации/проверок)" "10.0.128.0/24")"

  mount_point="$(ask "Куда монтировать NFS" "/share")"
  export_dir="/mnt/raid_${variant}"

  isp_port="$(ask "SSH port ISP (как задавал на ISP)" "2222")"
  srv_port="$(ask "SSH port SRV (как задавал на SRV)" "2223")"

  do_ssh="$(ask "Настроить SSH алиасы/ключи? (y/n)" "y")"
  do_keys="n"
  [[ "$do_ssh" == "y" ]] && do_keys="$(ask "Сгенерить ключ и сделать ssh-copy-id? (y/n)" "y")"

  hostnamectl hostname cli

  write_alt_iface_dhcp "$lan_if"
  systemctl restart network

  setup_nfs_mount "$srv_ip" "$export_dir" "$mount_point"

  if [[ "$do_ssh" == "y" ]]; then
    setup_ssh_client_aliases "$isp_ip" "$isp_port" "$srv_ip" "$srv_port" "$do_keys"
  fi

  echo
  echo "DONE."
}

main "$@"
