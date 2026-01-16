#!/usr/bin/env bash
set -euo pipefail

# ISP setup for ALT Linux (static LAN, DHCP, NAT, optional forward filter rules, optional sshuser)
# v2: adds sudo suid fix + optional DHCPDRAGS + optional FORWARD allowlist (DNS/HTTP/HTTPS)

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
  case "$cidr" in
    24) echo "255.255.255.0" ;;
    16) echo "255.255.0.0" ;;
     8) echo "255.0.0.0" ;;
    *)  echo "" ;;
  esac
}

derive_router_ip() { local net="$1" cidr="$2"; [[ "$cidr" == "24" ]] && echo "${net%.*}.1" || echo ""; }
derive_srv_ip()    { local net="$1" cidr="$2"; [[ "$cidr" == "24" ]] && echo "${net%.*}.2" || echo ""; }

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
  local net="$1" cidr="$2" router_ip="$3" srv_mac="$4" srv_ip="$5" domain="$6" lan_if="$7" force_iface="$8" range_start="$9" range_end="${10}"
  local mask
  mask="$(mask_from_cidr "$cidr")"
  [[ -n "$mask" ]] || { echo "CIDR /$cidr not supported in this script. Use /24,/16,/8."; exit 1; }

  apt-get update
  apt-get install -y dhcp-server

  [[ -f /etc/dhcp/dhcp.conf.sample ]] && cp -f /etc/dhcp/dhcp.conf.sample /etc/dhcp/dhcpd.conf

  local range_start="$7"
  local range_end="$8"

  # если не задали вручную — ставим дефолт
  if [[ -z "$range_start" || -z "$range_end" ]]; then
    if [[ "$cidr" == "24" ]]; then
      range_start="${net%.*}.50"
      range_end="${net%.*}.100"
    else
      echo "Для /$cidr нужно вручную задать DHCP пул (start/end)."
      exit 1
    fi
  fi


  cat > /etc/dhcp/dhcpd.conf <<EOF
default-lease-time 21600;
max-lease-time 43200;

subnet $net netmask $mask {
  option routers $router_ip;
  option subnet-mask $mask;

  option domain-name "$domain";
  option domain-name-servers 8.8.8.8;

  range $dhcp_pool_start $dhcp_pool_end;
}

host server {
  hardware ethernet $srv_mac;
  fixed-address $srv_ip;
}
EOF

  dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf

  # Optional: pin interface in /etc/sysconfig/dhcpd (guide says only if DHCP doesn't work)
  if [[ "$force_iface" == "y" ]]; then
    mkdir -p /etc/sysconfig
    cat > /etc/sysconfig/dhcpd <<EOF
DHCPDRAGS=$lan_if
EOF
  fi

  systemctl enable --now dhcpd || systemctl enable --now dhcpd.service || true
  systemctl restart dhcpd || systemctl restart dhcpd.service || true
}

setup_nat_and_forward_rules() {
  local lan_if="$1" wan_if="$2" src_cidr="$3" do_forward_allow="$4"

  apt-get install -y iptables

  # NAT
  iptables -t nat -C POSTROUTING -o "$wan_if" -s "$src_cidr" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o "$wan_if" -s "$src_cidr" -j MASQUERADE

  if [[ "$do_forward_allow" == "y" ]]; then
    # Allow established/related
    iptables -C FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
      || iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # Allow DNS
    iptables -C FORWARD -i "$lan_if" -o "$wan_if" -s "$src_cidr" -p udp --dport 53 -j ACCEPT 2>/dev/null \
      || iptables -A FORWARD -i "$lan_if" -o "$wan_if" -s "$src_cidr" -p udp --dport 53 -j ACCEPT
    iptables -C FORWARD -i "$lan_if" -o "$wan_if" -s "$src_cidr" -p tcp --dport 53 -j ACCEPT 2>/dev/null \
      || iptables -A FORWARD -i "$lan_if" -o "$wan_if" -s "$src_cidr" -p tcp --dport 53 -j ACCEPT

    # Allow HTTP/HTTPS
    iptables -C FORWARD -i "$lan_if" -o "$wan_if" -s "$src_cidr" -p tcp --dport 80 -j ACCEPT 2>/dev/null \
      || iptables -A FORWARD -i "$lan_if" -o "$wan_if" -s "$src_cidr" -p tcp --dport 80 -j ACCEPT
    iptables -C FORWARD -i "$lan_if" -o "$wan_if" -s "$src_cidr" -p tcp --dport 443 -j ACCEPT 2>/dev/null \
      || iptables -A FORWARD -i "$lan_if" -o "$wan_if" -s "$src_cidr" -p tcp --dport 443 -j ACCEPT
  fi

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

    # Guide also enforces sudo perms:
    chown root:root /usr/bin/sudo || true
    chmod 4755 /usr/bin/sudo || true

    visudo -c
    sudo -l -U sshuser || true
  fi
}

main() {
  need_root
  echo "=== ISP setup ==="

  local variant net_cidr net cidr dhcp_pool_start dhcp_pool_end default_pool_start default_pool_end router_ip srv_ip srv_mac lan_if wan_if ssh_port do_user domain force_dhcp_iface do_forward_allow

  variant="$(ask "Variant (для domain-name/DNS, напр. ssa)" "ssa")"
  net_cidr="$(ask "Подсеть для LAN (x.y.z.0/24)" "10.0.128.0/24")"

  net="${net_cidr%/*}"
  cidr="${net_cidr#*/}"

  router_ip="$(derive_router_ip "$net" "$cidr")"
  [[ -n "$router_ip" ]] || router_ip="$(ask "IP ISP внутри LAN" "10.0.128.1")"

  srv_ip="$(derive_srv_ip "$net" "$cidr")"
  [[ -n "$srv_ip" ]] || srv_ip="$(ask "IP SRV внутри LAN" "10.0.128.2")"

  # дефолтный пул для /24
  default_pool_start=""
  default_pool_end=""
  if [[ "$cidr" == "24" ]]; then
    default_pool_start="${net%.*}.50"
    default_pool_end="${net%.*}.100"
  fi

dhcp_pool_start="$(ask "DHCP пул START (Enter = дефолт/авто)" "$default_pool_start")"
dhcp_pool_end="$(ask "DHCP пул END (Enter = дефолт/авто)" "$default_pool_end")"

  srv_mac="$(ask "MAC адрес SRV (для DHCP fixed-address)" "08:00:27:aa:bb:cc")"

  lan_if="$(ask "LAN интерфейс (static IP)" "ens19")"
  wan_if="$(ask "WAN интерфейс (наружу, NAT)" "ens18")"

  ssh_port="$(ask "SSH порт для ISP (пусто = не менять)" "2222")"
  do_user="$(ask "Создать sshuser + sudo(POWER,HTOP)? (y/n)" "y")"

  force_dhcp_iface="$(ask "Если DHCP не поднимется — прописать DHCPDRAGS=$lan_if в /etc/sysconfig/dhcpd? (y/n)" "n")"
  do_forward_allow="$(ask "Добавить allowlist FORWARD (DNS/HTTP/HTTPS + ESTABLISHED)? (y/n)" "y")"

  domain="${variant}.sa"

  hostnamectl hostname ISP

  write_alt_iface_static "$lan_if" "${router_ip}/${cidr}"
  systemctl restart network

  enable_ip_forward

  setup_dhcp "$net" "$cidr" "$router_ip" "$srv_mac" "$srv_ip" "$domain" "$lan_if" "$force_dhcp_iface" "$dhcp_pool_start" "$dhcp_pool_end"

  setup_nat_and_forward_rules "$lan_if" "$wan_if" "$net_cidr" "$do_forward_allow"

  setup_ssh_port_and_user "$ssh_port" "$do_user"

  echo
  echo "DONE. Проверки:"
  echo "  sysctl net.ipv4.ip_forward"
  echo "  dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf"
  echo "  iptables -S"
  echo "  iptables -t nat -S"
  echo "  iptables -L -v -n"
}

main "$@"
