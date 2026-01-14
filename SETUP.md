# ISP / SRV / CLI: сеть, DHCP, NAT, RAID5, NFS, SSH, Samba AD DC

> Конспект/шпаргалка для лабораторной: настройка маршрутизатора (ISP), сервера (SRV) и клиента (CLI).

## Топология и интерфейсы

- **ISP**  
  - WAN: `enp0s3`  
  - LAN: `enp0s8` (статический адрес `10.0.128.1/24`)
- **SRV**: `enp0s3` (получает адрес по DHCP, фиксированный `10.0.128.2`)
- **CLI**: `enp0s3` (получает адрес по DHCP)

---

## 1) ISP: LAN-интерфейс (static) + включить форвардинг

### 1.1 Настройка LAN (`enp0s8`)

```bash
mkdir -p /etc/net/ifaces/enp0s8

cat > /etc/net/ifaces/enp0s8/options <<'EOF'
ONBOOT=yes
BOOTPROTO=static
TYPE=eth
NM_CONTROLLED=no
EOF

echo "10.0.128.1/24" > /etc/net/ifaces/enp0s8/address

systemctl restart network
```

### 1.2 Включить маршрутизацию IPv4

Откройте `/etc/net/sysctl.conf` и поменяйте:

- `net.ipv4.ip_forward=0` → `net.ipv4.ip_forward=1`

Проверка:

```bash
sysctl net.ipv4.ip_forward
```

---

## 2) ISP: DHCP-сервер

### 2.1 Установка

```bash
apt-get update
apt-get install -y dhcp-server
```

### 2.2 Конфиг `dhcpd`

```bash
cp /etc/dhcp/dhcp.conf.sample /etc/dhcp/dhcpd.conf
vim /etc/dhcp/dhcpd.conf
```

Пример содержимого (адаптируйте под себя):

```conf
default-lease-time 600;
max-lease-time 7200;

subnet 10.0.128.0 netmask 255.255.255.0 {
  option routers 10.0.128.1;
  option domain-name "ilove.sa";
  option domain-name-servers 8.8.8.8;

  range 10.0.128.50 10.0.128.100;
}

host server {
  hardware ethernet 08:00:27:a0:85:70;  # MAC SRV
  fixed-address 10.0.128.2;
}
```

Проверка синтаксиса:

```bash
dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf
```

### 2.3 Привязать DHCP к интерфейсу LAN

```bash
vim /etc/sysconfig/dhcpd
```

Укажите:

```bash
DHCPDRAGS=enp0s8
```

---

## 3) ISP: NAT (iptables)

> Переменные интерфейсов:
> - `WAN_IF="enp0s3"`
> - `LAN_IF="enp0s8"`

### 3.1 Установка + базовый NAT

```bash
apt-get install -y iptables

WAN_IF="enp0s3"

# NAT
iptables -t nat -A POSTROUTING -o "$WAN_IF" -s 10.0.128.0/24 -j MASQUERADE

# сохранить и включить автозагрузку
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables
systemctl restart iptables
```

### 3.2 Проверка

```bash
iptables -S
iptables -t nat -S
iptables -L -v -n
```

---

## 4) SRV: сетевой интерфейс по DHCP

```bash
cat > /etc/net/ifaces/enp0s3/options <<'EOF'
ONBOOT=yes
BOOTPROTO=dhcp
TYPE=eth
NM_CONTROLLED=no
EOF

systemctl restart network
```

---

## 5) SRV: RAID5 (mdadm) + ФС + монтирование

### 5.1 Создание RAID5

```bash
mdadm --create /dev/md0 --level=5 --raid-devices=3 /dev/sdb /dev/sdc /dev/sdd
```

Проверки:

```bash
cat /proc/mdstat
mdadm --detail /dev/md0
```

### 5.2 Файловая система + mount

```bash
mkfs.ext4 -L RAID5 /dev/md0
mkdir -p /mnt/raid

UUID=$(blkid -s UUID -o value /dev/md0)
echo "UUID=$UUID /mnt/raid ext4 defaults 0 2" >> /etc/fstab

mount -a
```

### 5.3 Сохранить конфиг mdadm

```bash
mdadm --detail --scan >> /etc/mdadm.conf
```

---

## 6) SRV: NFS-сервер

### 6.1 Установка и запуск сервисов

```bash
apt-get install -y nfs-server rpcbind

systemctl enable --now rpcbind
systemctl enable --now nfs-server
```

Проверка сервисов:

```bash
systemctl status rpcbind --no-pager
systemctl status nfs-server --no-pager
```

### 6.2 Экспорт

```bash
cat > /etc/exports <<'EOF'
/mnt/raid 10.0.128.0/24(rw,sync,no_subtree_check)
EOF

exportfs -ra

chmod 777 /mnt/raid
```

Проверка экспорта (на SRV):

```bash
exportfs -v
```

---

## 7) CLI: сеть + монтирование NFS

### 7.1 Быстрая диагностика

```bash
ip -br a
```

Если IP нет — настройте `/etc/net/ifaces/enp0s3/options` аналогично SRV (DHCP) и перезапустите сеть.

### 7.2 Монтирование NFS: `10.0.128.2:/mnt/raid` → `/share`

```bash
apt-get install -y nfs-utils
mkdir -p /share

# проверить, что сервер экспортирует
showmount -e 10.0.128.2

echo "10.0.128.2:/mnt/raid /share nfs defaults,_netdev 0 0" >> /etc/fstab
mount -a
```

Проверка:

```bash
df -h | grep /share
touch /share/test_from_cli
ls -la /share | tail
```

---

## 8) SSH: доступ с CLI на ISP и SRV (алиасы, без пароля, нестандартные порты)

Цель:
- Пользователь `sshuser` на **ISP** и **SRV**
- У него sudo **только** для `shutdown/reboot/htop` и **без пароля**
- На CLI настроить ключи и `~/.ssh/config` с алиасами `ISP` и `srv`

### 8.1 ISP + SRV: создать пользователя и выдать ограниченный sudo

```bash
useradd sshuser
passwd sshuser

apt-get install -y sudo htop
```

Sudo-ограничение:

```bash
cat > /etc/sudoers.d/sshuser <<'EOF'
Cmnd_Alias POWER = /sbin/shutdown, /sbin/reboot, /usr/sbin/shutdown, /usr/sbin/reboot
Cmnd_Alias HTOP  = /usr/bin/htop
sshuser ALL=(root) NOPASSWD: POWER, HTOP
EOF

chmod 0400 /etc/sudoers.d/sshuser

# убедиться, что sudo настроен корректно
visudo -c
```

Проверка прав:

```bash
sudo -l -U sshuser
```

### 8.2 CLI: ключи + ~/.ssh/config

> Ниже пример с **ed25519**. Если вы генерируете `rsa`, то в `IdentityFile` укажите `~/.ssh/id_rsa`.

```bash
ssh-keygen -t ed25519

ssh-copy-id sshuser@10.0.128.1
ssh-copy-id sshuser@10.0.128.2

cat > ~/.ssh/config <<'EOF'
Host ISP
  HostName 10.0.128.1
  User sshuser
  Port 2222
  IdentityFile ~/.ssh/id_ed25519

Host srv
  HostName 10.0.128.2
  User sshuser
  Port 2223
  IdentityFile ~/.ssh/id_ed25519
EOF

chmod 600 ~/.ssh/config
```

Проверка:

```bash
ssh ISP
ssh srv
```

---
### 8.3 ISP + SRV: настроить sshd (порты + только ключи)

На **ISP** и **SRV** отредактируйте файл `/etc/openssh/sshd_config`:

- На **ISP** выставьте порт **2222**
- На **SRV** выставьте порт **2223**
- Включите **PubkeyAuthentication yes**
- Отключите **PasswordAuthentication no**

Пример (фрагмент):

```conf
# ISP: Port 2222
# SRV: Port 2223
Port <PORT>

PubkeyAuthentication yes
PasswordAuthentication no
```

Применить изменения:

```bash
systemctl restart sshd
systemctl status sshd --no-pager
```

> После отключения паролей убедитесь, что вы уже добавили публичный ключ на сервер (`ssh-copy-id`), иначе можете потерять доступ.

---


## 9) Samba AD DC на SRV: домен `ilove.sa` + пользователи `ssa1/ssa2/ssa3` + группа `ssa_group` + вход на CLI

### 9.1 SRV: установка и поднятие Samba DC

```bash
apt-get install task-samba-dc

systemctl disable --now bind krb5kdc nmb smb slapd

rm -f /etc/samba/smb.conf
rm -rf /var/lib/samba
rm -rf /var/cache/samba
mkdir -p /var/lib/samba/sysvol
```

Установите hostname (пример):

```bash
hostnamectl set-hostname <name>
```

> **Важно:** `hostname` и `domainname` должны быть разными.

Provision домена:

```bash
samba-tool domain provision \
  --realm=ilove.sa \
  --domain ilove \
  --adminpass='Pa$$word' \
  --dns-backend=SAMBA_INTERNAL \
  --server-role=dc
```

DNS forwarder: `8.8.8.8`.

Запуск:

```bash
systemctl enable --now samba
```

Локальный DNS на SRV:

```bash
echo "127.0.0.1" > /etc/net/ifaces/enp0s3/resolv.conf
systemctl restart network
```

Проверки:

```bash
samba-tool domain info 127.0.0.1
smbclient -L localhost -U administrator
```

### 9.2 Проверка DNS-записей

Убедитесь, что `nameserver 127.0.0.1` в `/etc/resolv.conf`, затем:

```bash
host ilove.sa
host -t SRV _kerberos._udp.ilove.sa.
host -t SRV _ldap._tcp.ilove.sa.
host -t A <hostname>.ilove.sa.
```

Если имена не находятся — проверьте, что `named` выключен:

```bash
systemctl status named
```

### 9.3 Проверка Kerberos

```bash
kinit administrator
klist
```

### 9.4 SRV: создать группу и пользователей

```bash
samba-tool user create ssa1 P@ssw0rd
samba-tool user create ssa2 P@ssw0rd
samba-tool user create ssa3 P@ssw0rd

samba-tool group addmembers ssa_group ssa1,ssa2,ssa3
```

---

## 10) CLI: вступить в домен и проверить пользователей

```bash
apt-get install task-auth-ad-sssd

echo "nameserver 10.0.128.2" > /etc/net/ifaces/enp0s3/resolv.conf
echo "search ilove.sa" >> /etc/net/ifaces/enp0s3/resolv.conf

reboot
```

Далее:

```bash
realm discover
realm join

reboot
```

Проверки:

```bash
kinit ssa1@ILOVE.SA
klist

id ssa1@ilove.sa
getent passwd ssa1@ilove.sa
```

### 10.1 Домашние директории для доменных пользователей (пример)

```bash
H="/home/ssa1@ilove.sa"
mkdir -p "$H"
chown "$(id -u 'ssa1@ilove.sa')":"$(id -g 'ssa1@ilove.sa')" "$H"
chmod 700 "$H"
```

Повторить аналогично для `ssa2@ilove.sa` и `ssa3@ilove.sa`.

---

## 11) CLI: sudo-ограничение для группы `ssa_group` (как для sshuser)

```bash
cat > /etc/sudoers.d/ssa_group <<'EOF'
Cmnd_Alias POWER = /sbin/shutdown, /sbin/reboot, /usr/sbin/shutdown, /usr/sbin/reboot
Cmnd_Alias HTOP  = /usr/bin/htop
%ssa_group@ilove.sa ALL=(root) NOPASSWD: POWER, HTOP
EOF

chmod 0400 /etc/sudoers.d/ssa_group
visudo -c
```

Проверка (после входа под `ssa1`):

```bash
sudo -l
sudo htop
```

---

## 12) Дополнительно: правила FORWARD (если нужно ограничивать трафик LAN → WAN)

```bash
LAN_IF="enp0s8"
WAN_IF="enp0s3"

# established/related
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# DNS 53 TCP/UDP
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s 10.0.128.0/24 -p udp --dport 53 -j ACCEPT
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s 10.0.128.0/24 -p tcp --dport 53 -j ACCEPT

# HTTP/HTTPS
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s 10.0.128.0/24 -p tcp --dport 80 -j ACCEPT
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s 10.0.128.0/24 -p tcp --dport 443 -j ACCEPT

# сохранить
iptables-save > /etc/sysconfig/iptables
systemctl restart iptables
```
