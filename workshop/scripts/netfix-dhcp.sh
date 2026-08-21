#!/bin/bash
# Мигрированный CentOS 7 образ несёт статичный VMware IP (ifcfg-eth0 BOOTPROTO=static,
# IPADDR=192.168.10.x, GATEWAY=192.168.10.1). Из-за этого VM не на pod-NIC и не
# резолвит managed-сервисы (CoreDNS недоступен). Переключаем eth0 на DHCP.
#
# Запускать в app-VM (CentOS 7) под root, ЗАТЕМ перезапустить VM (дашборд -> Restart).
# Правка персистентна — переживает перезапуск.
# ЭТО НЕ netplan (то Ubuntu) — у CentOS 7 сеть в ifcfg-eth0.
set -e
IFCFG=/etc/sysconfig/network-scripts/ifcfg-eth0

echo "== было =="; cat "$IFCFG"
sed -i 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/; /^IPADDR/d; /^GATEWAY/d; /^NETMASK/d; /^PREFIX/d; /^DNS/d' "$IFCFG"
grep -q '^BOOTPROTO' "$IFCFG" || echo 'BOOTPROTO=dhcp' >> "$IFCFG"
echo "== стало =="; cat "$IFCFG"
echo "== eth0 переключён на DHCP. ТЕПЕРЬ перезапустите VM: дашборд -> Restart. =="
echo "   После ребута: eth0 получит pod-NIC (10.244.x), managed-сервисы начнут резолвиться."
