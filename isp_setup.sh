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

mask_from_cidr() {
  local cidr="$1"
  # only common /24,/16,/8 for lab; extend if needed
  case "$cidr" in
    24) echo "255.255.255.0" ;;
    16) echo "255.255.0.0" ;;
     8) echo "255.0.0.0" ;;
    *)  echo "" ;;
  esac
}

derive_router_ip() {
  # expects x.y.z.0/24 -> x.y.z.1
  local net="$1" cidr="$2"
  if [[ "$cidr" == "24" ]]; then
    echo "${net%.*}.1"
  else
    echo ""
  fi
}

derive_srv_ip() {
  local net="$1" cidr="$2"
  if [[ "$cidr" == "24" ]]; then
    echo "${net%.*}.2"
  else
    echo ""
  fi
}

write_alt_iface_static() {
  local ifname="$1" ip_cidr="$2"
  mkdir -p "/etc/net/ifaces/$ifname"
  cat >"/etc/net/ifaces/$ifname/options" <<EOF
ONBOOT=yes
BOOTPROTO=static
TYPE=eth
NM_CONTROLLED=no
EOF
  echo "$ip_cidr" >"/etc/net/ifaces/$ifname/ipv4address"
}

enable_ip_forward() {
  local f="/etc/net/sysctl.conf"
  touch "$f"
  if grep -qE '^\s*net\.ipv4\.ip_forward=' "$f"; then
    sed -i 's/^\s*net\.ipv4\.ip_forward=.*/net.ipv4.ip_forward=1/' "$f"
  else
    echo "net.ipv4.ip_forward=1" >> "$f"
  fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

setup_dhcp() {
  local net="$1" cidr="$2" router_ip="$3" srv_mac="$4" srv_ip="$5" domain="$6"
  local mask
  mask="$(mask_from_cidr "$cidr")"
  [[ -n "$mask" ]] || { echo "CIDR /$cidr not supported in this simple script. Use /24,/16,/8."; exit 1; }

  apt-get update
  apt-get install -y dhcp-server

  # ALT sample path from your guide
  if [[ -f /etc/dhcp/dhcp.conf.sample ]]; then
    cp -f /etc/dhcp/dhcp.conf.sample /etc/dhcp/dhcpd.conf
  fi

  # simple dynamic range for /24
  local range_start range_end
  if [[ "$cidr" == "24" ]]; then
    range_start="${net%.*}.50"
    range_end="${net%.*}.100"
  else
    range_start="$router_ip"
    range_end="$router_ip"
  fi

  cat > /etc/dhcp/dhcpd.conf <<EOF
default-lease-time 21600;
max-lease-time 43200;

subnet $net netmask $mask {
  option routers $router_ip;
  option subnet-mask $mask;

  option domain-name "$domain";
  option domain-name-servers 8.8.8.8;

  range $range_start $range_end;
}

host server {
  hardware ethernet $srv_mac;
  fixed-address $srv_ip;
}
EOF

  dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf
  systemctl enable --now dhcpd || systemctl enable --now dhcpd.service || true
  systemctl restart dhcpd || systemctl restart dhcpd.service || true
}

setup_nat() {
  local lan_if="$1" wan_if="$2" src_cidr="$3"
  apt-get install -y iptables

  # NAT rule from your guide
  iptables -t nat -C POSTROUTING -o "$wan_if" -s "$src_cidr" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o "$wan_if" -s "$src_cidr" -j MASQUERADE

  iptables-save > /etc/sysconfig/iptables
  systemctl enable --now iptables
  systemctl restart iptables
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

main() {
  need_root

  echo "=== ISP setup ==="

  local variant net_cidr net cidr router_ip srv_ip srv_mac lan_if wan_if ssh_port do_user domain

  variant="$(ask "Variant (будет использоваться как domain-name в DHCP, напр. ssa)" "ssa")"
  net_cidr="$(ask "Подсеть для LAN в формате x.y.z.0/24" "10.0.128.0/24")"

  net="${net_cidr%/*}"
  cidr="${net_cidr#*/}"

  router_ip="$(derive_router_ip "$net" "$cidr")"
  [[ -n "$router_ip" ]] || router_ip="$(ask "IP роутера (ISP) внутри LAN" "10.0.128.1")"

  srv_ip="$(derive_srv_ip "$net" "$cidr")"
  [[ -n "$srv_ip" ]] || srv_ip="$(ask "IP сервера (SRV) внутри LAN" "10.0.128.2")"

  srv_mac="$(ask "MAC адрес SRV (для DHCP fixed-address)" "08:00:27:aa:bb:cc")"

  lan_if="$(ask "LAN интерфейс (внутренняя сеть, static IP)" "ens19")"
  wan_if="$(ask "WAN интерфейс (наружу, для NAT)" "ens18")"

  ssh_port="$(ask "SSH порт для ISP (пусто = не менять)" "2222")"
  do_user="$(ask "Создать sshuser + sudo(POWER,HTOP)? (y/n)" "y")"

  domain="${variant}.sa"

  hostnamectl hostname ISP

  write_alt_iface_static "$lan_if" "${router_ip}/${cidr}"
  systemctl restart network

  enable_ip_forward

  setup_dhcp "$net" "$cidr" "$router_ip" "$srv_mac" "$srv_ip" "$domain"

  setup_nat "$lan_if" "$wan_if" "$net_cidr"

  setup_ssh_port_and_user "$ssh_port" "$do_user"

  echo
  echo "DONE. Проверки:"
  echo "  sysctl net.ipv4.ip_forward"
  echo "  dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf"
  echo "  iptables -t nat -S"
}

main "$@"
