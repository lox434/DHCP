#!/usr/bin/env bash
set -euo pipefail

# CLI setup for ALT Linux (DHCP, NFS mount, optional SSH aliases, optional AD client prep)
# v2: adds AD client prep + sudoers for domain group (from guide)

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

setup_ad_client_prep() {
  local lan_if="$1" srv_ip="$2" realm="$3" group="$4"
  local do_realm_join="$5"

  # From guide: remove alterator-datetime + install task-auth-ad-sssd
  apt-get remove -y alterator-datetime 2>/dev/null || true
  apt-get install -y task-auth-ad-sssd

  mkdir -p "/etc/net/ifaces/$lan_if"
  {
    echo "nameserver $srv_ip"
    echo "search $realm"
  } > "/etc/net/ifaces/$lan_if/resolv.conf"

  systemctl restart network || true

  echo "DNS проверка:"
  host "$realm" || true

  if [[ "$do_realm_join" == "y" ]]; then
    if command -v realm >/dev/null 2>&1; then
      echo "Попробуем realm discover / realm join (может попросить пароль administrator):"
      realm discover "$realm" || true
      realm join "$realm" -U administrator || true
    else
      echo "Команды realm нет в системе. По гайду можно присоединиться через GUI (System Management Center)."
    fi
  else
    echo "Присоединение к домену пропущено. По гайду можно через GUI: SMC -> Authentication -> AD."
  fi

  # Sudo restrictions for domain group (from guide)
  cat > "/etc/sudoers.d/${group}" <<EOF
Cmnd_Alias POWER = /sbin/shutdown, /sbin/reboot, /usr/sbin/shutdown, /usr/sbin/reboot
Cmnd_Alias HTOP  = /usr/bin/htop
%${group}@${realm} ALL=(root) NOPASSWD: POWER, HTOP
EOF
  chmod 0400 "/etc/sudoers.d/${group}"
  visudo -c || true

  echo "После входа доменным пользователем: sudo -l ; sudo htop"
}

main() {
  need_root
  fix_sudoers_permissions
  echo "=== CLI setup ==="

  local variant lan_if srv_ip isp_ip mount_point do_ssh isp_port srv_port do_keys export_dir
  local do_ad realm group do_realm_join

  variant="$(ask "Variant (совпадает с SRV для /mnt/raid_<variant>)" "ssa")"
  variant_num="$(echo "$variant" | tr -cd '0-9')"
  lan_if="$(ask "LAN интерфейс (DHCP)" "ens18")"
  isp_ip="$(ask "IP ISP в LAN" "10.0.128.1")"
  srv_ip="$(ask "IP SRV в LAN" "10.0.128.2")"

  mount_point="$(ask "Куда монтировать NFS" "/share")"
  export_dir="/mnt/raid_${variant_num}"

  isp_port="$(ask "SSH port ISP" "2222")"
  srv_port="$(ask "SSH port SRV" "2223")"

  do_ssh="$(ask "Настроить SSH алиасы/ключи? (y/n)" "y")"
  do_keys="n"
  [[ "$do_ssh" == "y" ]] && do_keys="$(ask "Сгенерить ключ и сделать ssh-copy-id? (y/n)" "y")"

  do_ad="$(ask "Подготовить CLI как клиент Samba AD? (y/n)" "n")"
  realm="$(ask "Realm (FQDN), например ${variant}.sa" "${variant}.sa")"
  group="$(ask "Группа домена для sudo (например ${variant}_group)" "${variant}_group")"
  do_realm_join="$(ask "Пробовать realm join автоматически? (y/n)" "n")"

  hostnamectl hostname cli

  write_alt_iface_dhcp "$lan_if"
  systemctl restart network

  setup_nfs_mount "$srv_ip" "$export_dir" "$mount_point"

  if [[ "$do_ssh" == "y" ]]; then
    setup_ssh_client_aliases "$isp_ip" "$isp_port" "$srv_ip" "$srv_port" "$do_keys"
  fi

  if [[ "$do_ad" == "y" ]]; then
    setup_ad_client_prep "$lan_if" "$srv_ip" "$realm" "$group" "$do_realm_join"
    echo "По гайду после настроек клиента обычно делают reboot."
  fi

  echo
  echo "DONE."
}

main "$@"
