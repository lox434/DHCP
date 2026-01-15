## ISP:
```bash
WAN = enp0s3
LAN = enp0s8

mkdir -p /etc/net/ifaces/enp0s8

vim /etc/net/ifaces/enp0s8/options
ONBOOT=yes
BOOTPROTO=static
TYPE=eth
NM_CONTROLLED=no

echo "10.0.128.1/24" > /etc/net/ifaces/enp0s8ddress

systemctl restart network

vim /etc/net/sysctl.conf

```
поменяй net.ipv4.ip_forward=0 > 1
```bash

```
sysctl net.ipv4.ip_forward <-- проверка
```bash

```
DHCP
```bash
apt-get update
apt-get install -y dhcp-server

cp /etc/dhcp/dhcp.conf.sample /etc/dhcp/dhcpd.conf
vim /etc/dhcp/dhcpd.conf

```
## Сделать примерно тоже самое:
```bash

default-lease-time 600;
max-lease-time 7200;

subnet 10.0.128.0 netmask 255.255.255.0 {
  option routers 10.0.128.1;
  option domain-name "ilove.sa";
  option domain-name-servers 8.8.8.8;

  range 10.0.128.50 10.0.128.100;
}
  host server {
    hardware ethernet 08:00:27:a0:85:70; <-- тут мак аддрес SRV
    fixed-address 10.0.128.2;
}

dhcpd -t -4 -cf /etc/dhcp/dhcpd.conf <-- проверка синтаксиса

vim /etc/sysconfig/dhcpd

DHCPDRAGS=enp0s8

apt-get install -y iptables

# NAT
iptables -t nat -A POSTROUTING -o "$WAN_IF" -s 10.0.128.0/24 -j MASQUERADE

# сохраняем и включаем автозагрузку
iptables-save > /etc/sysconfig/iptables
systemctl enable --now iptables
systemctl restart iptables

```
проверка
```bash

iptables -S
iptables -t nat -S
iptables -L -v -n


```
## SRV:
```bash

vim /etc/net/ifaces/enp0s3

ONBOOT=yes
BOOTPROTO=dhcp
TYPE=eth
NM_CONTROLLED=no

systemctl restart network

```
RAID5
```bash

mdadm --create /dev/md0 --level=5 --raid-devices=3 /dev/sdb /dev/sdc /dev/sdd

```
проверка
```bash

cat /proc/mdstat
mdadm --detail /dev/md0

```
ФС и монтирование
```bash

mkfs.ext4 -L RAID5 /dev/md0
mkdir -p /mnt/raid

UUID=$(blkid -s UUID -o value /dev/md0)
echo "UUID=$UUID /mnt/raid ext4 defaults 0 2" >> /etc/fstab
mount -a

```
сохранить конфиг
```bash

mdadm --detail --scan >> /etc/mdadm.conf

```
## NFS:
```bash

apt-get install -y nfs-server rpcbind

systemctl enable --now rpcbind
systemctl enable --now nfs-server


```
## Проверка сервисов:
```bash

systemctl status rpcbind --no-pager
systemctl status nfs-server --no-pager


```
## Экспорт:
```bash

cat > /etc/exports <<'EOF'
```
/mnt/raid 10.0.128.0/24(rw,sync,no_subtree_check)
```bash
EOF

exportfs -ra

chmod 777 /mnt/raid

```
Проверка экспорта (на Server):
```bash

exportfs -v



```
## CLI:
```bash

ip -br a

```
при отсутствии ip настроить /etc/net/ifaces/enp0s3/options как на сервере
```bash

```
3.2 Mount NFS: 10.0.128.2:/mnt/raid → /share
```bash

```
## На cli:
```bash

apt-get install -y nfs-utils
mkdir -p /share

# проверить что сервер экспортирует
showmount -e 10.0.128.2

echo "10.0.128.2:/mnt/raid /share nfs defaults,_netdev 0 0" >> /etc/fstab
mount -a


```
## Проверка:
```bash

df -h | grep /share
touch /share/test_from_cli
ls -la /share | tail




```
4) SSH доступ с cli на ISP и Server: алиасы, без пароля, нестандартные порты, пользователь sshuser
4.1 На ISP и на Server: создать sshuser + sudo только shutdown/reboot/htop (без пароля)
```bash

```
## На ISP и на Server:
```bash

useradd sshuser
passwd  sshuser

apt-get install -y sudo htop


```
## Sudo-ограничение:
```bash

cat > /etc/sudoers.d/sshuser <<'EOF'
```
Cmnd_Alias POWER = /sbin/shutdown, /sbin/reboot, /usr/sbin/shutdown, /usr/sbin/reboot
Cmnd_Alias HTOP  = /usr/bin/htop
sshuser ALL=(root) NOPASSWD: POWER, HTOP
```bash
EOF

chmod 0400/etc/sudoers.d/sshuser
chown root:root /usr/bin/sudo
chmod 4755 /usr/bin/sudo

visudo -c


```
## Проверка:
```bash

sudo -l -U sshuser



```
4.3 На cli: ключи + ~/.ssh/config (алиасы ssh ISP / ssh Server)
```bash

```
## На cli:
```bash

ssh-keygen -t rsa

ssh-copy-id sshuser@10.0.128.1
ssh-copy-id sshuser@10.0.128.2

cat > ~/.ssh/config <<'EOF'
```
Host ISP
  HostName 10.0.128.1
  User sshuser
  Port 2222
  IdentityFile ~/.ssh/id_ed25519
```bash

```
Host srv
  HostName 10.0.128.2
  User sshuser
  Port 2223
  IdentityFile ~/.ssh/id_ed25519
```bash
EOF

chmod 600 ~/.ssh/config


```
## Проверка:
```bash

```
ssh ISP
ssh srv
```bash


```
5) Samba AD DC на Server: домен ilove.sa, пользователи ssa1/ssa2/ssa3, группа ssa_group, вход на cli
5.1 Server: установка и поднятие samba-dc
```bash

```
## На Server:
```bash

apt-get install task-samba-dc

systemctl disable --now bind krb5kdc nmb smb slapd

rm -f /etc/samba/smb.conf
rm -rf /var/lib/samba
rm -rf /var/cache/samba
mkdir -p /var/lib/samba/sysvol

hostnamectl set-hostname <name>

```
hostname и domainname должны быть разными
```bash

samba-tool domain provision --realm=ilove.sa --domain ilove --adminpass='Pa$$word' --dns-backend=SAMBA_INTERNAL --server-role=dc

```
dns forwarder 8.8.8.8
```bash

systemctl enable --now samba

echo "127.0.0.1" > /etc/net/ifaces/enp0s3/resolv.conf
systemctl restart network

```
## Проверка:
```bash

samba-tool domain info 127.0.0.1
smbclient -L localhost -U administrator

```
3. Проверка конфигурации DNS
```bash

```
3.1 Убедитесь в наличии nameserver 127.0.0.1 в /etc/resolv.conf:
```bash

host ilove.sa
```
## 3.2 Проверяем имена хостов:
```bash

```
адрес _kerberos._udp.*адрес домена с точкой
```bash

# host -t SRV _kerberos._udp.ilove.sa.
```
Вывод:_kerberos._udp.ilove.sa has SRV record 0 100 88 c228.ilove.sa.
```bash

```
адрес _ldap._tcp.*адрес домена с точкой
```bash

# host -t SRV _ldap._tcp.ilove.sa.
```
Вывод:_ldap._tcp.ilove.sa has SRV record 0 100 389 c228.ilove.sa.
```bash

```
адрес хоста.*адрес домена с точкой
```bash

# host -t A c228.ilove.sa.

```
Вывод:c228.ilove.sa has address 192.168.1.1
```bash

```
Если имена не находятся, проверяйте выключение службы named.
```bash

systemctl status named

```
## 4. Проверка Kerberos:
```bash
kinit administrator
klist


```
5.2 Server: создать группу и пользователей ssa1/ssa2/ssa3
```bash

samba-tool user create ssa1 P@ssw0rd
samba-tool user create ssa2 P@ssw0rd
samba-tool user create ssa3 P@ssw0rd

samba-tool group addmembers ssa_group ssa1,ssa2,ssa3



```
## CLI:
```bash

apt-get install task-auth-ad-sssd

echo "nameserver 10.0.128.2" > /etc/net/ifaces/enp0s3/resolv.conf
echo "search ilove.sa" >> /etc/net/ifaces/enp0s3/resolv.conf

reboot

realm discover
realm join

reboot

```
## Проверки:
```bash

kinit ssa1@ILOVE.SA
klist
id ssa1@ilove.sa
getent passwd ssa1@ilove.sa

H="/home/ssa1@ilove.sa"
mkdir -p "$H"
chown $(id -u 'ssa1@ilove.sa'):$(id -g 'ssa1@ilove.sa') "$H"
chmod 700 "$H"

H="/home/ssa2@ilove.sa"
mkdir -p "$H"
chown $(id -u 'ssa2@ilove.sa'):$(id -g 'ssa2@ilove.sa') "$H"
chmod 700 "$H"

H="/home/ssa3@ilove.sa"
mkdir -p "$H"
chown $(id -u 'ssa3@ilove.sa'):$(id -g 'ssa3@ilove.sa') "$H"
chmod 700 "$H"

```
5.4 cli: sudo-ограничение для группы ssa_group (как в IV-A)
```bash

```
## На cli:
```bash

cat > /etc/sudoers.d/ssa_group <<'EOF'
```
Cmnd_Alias POWER = /sbin/shutdown, /sbin/reboot, /usr/sbin/shutdown, /usr/sbin/reboot
Cmnd_Alias HTOP  = /usr/bin/htop
%ssa_group@ilove.sa ALL=(root) NOPASSWD: POWER, HTOP
```bash
EOF

chmod 0400 etc/sudoers.d/ssa_group
visudo -c


```
## Проверка:
```bash

# после входа под ssa1:
sudo -l
sudo htop



# разрешаем established/related
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# разрешаем DNS 53 TCP/UDP
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s 10.0.128.0/24 -p udp --dport 53 -j ACCEPT
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s 10.0.128.0/24 -p tcp --dport 53 -j ACCEPT

# разрешаем HTTP/HTTPS
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s 10.0.128.0/24 -p tcp --dport 80 -j ACCEPT
iptables -A FORWARD -i "$LAN_IF" -o "$WAN_IF" -s 10.0.128.0/24 -p tcp --dport 443 -j ACCEPT


# сохраняем и включаем автозагрузку
iptables-save > /etc/sysconfig/iptables
systemctl restart iptables
```
