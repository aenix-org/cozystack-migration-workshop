#!/bin/bash
# Конвертация VMware OVA -> qcow2 внутри conversion-VM.
# Запускать в conversion-VM (ubuntu-20.04) под root:  sudo bash convert.sh
set -euo pipefail

# =========================================================================
# ВСТАВЬТЕ СВОИ ЗНАЧЕНИЯ.
#   Креды берутся в дашборде: Bucket -> ваш бакет -> вкладка Secrets
#   (секрет bucket-<имя>-app-credentials: accessKey / secretKey / bucketName).
#   Ссылку на исходный OVA даёт оператор (общий бакет с образами).
# =========================================================================
S3_ENDPOINT="https://s3.workshop.aenix.io"   # поле endpoint из Secrets, но С ПРЕФИКСОМ https://
                                             # (в дашборде показано без схемы, добавьте https:// сами)
BUCKET="ВСТАВЬТЕ_bucketName"                 # bucketName вашего бакета
ACCESS_KEY="ВСТАВЬТЕ_accessKey"              # accessKey вашего бакета
SECRET_KEY="ВСТАВЬТЕ_secretKey"              # secretKey вашего бакета
OVA_URL="https://s3.workshop.aenix.io/bucket-a9209f83-4ac1-463e-8477-d8365bef787b/app-1.ova"  # готовый demo-OVA воркшопа (уже залит; можно заменить своим)
# =========================================================================

echo "== 1. nested-virt? (если /dev/kvm нет -> TCG, медленнее, но работает) =="
if [ -e /dev/kvm ]; then echo "  /dev/kvm есть — аппаратное ускорение"; else
  echo "  /dev/kvm НЕТ -> LIBGUESTFS_BACKEND=direct (TCG)"; export LIBGUESTFS_BACKEND=direct; fi

echo "== 2. качаю исходный OVA =="
cd /root
wget -O source.ova "$OVA_URL"

echo "== 3. virt-v2v: VMware OVA -> qcow2 (флаг -of qcow2 обязателен) =="
rm -rf /root/out && mkdir -p /root/out
time virt-v2v -i ova /root/source.ova -o local -os /root/out -of qcow2 -on app

echo "== 4. заливаю результат в СВОЙ бакет (S3) =="
mc alias set mybucket "$S3_ENDPOINT" "$ACCESS_KEY" "$SECRET_KEY"
mc cp /root/out/app-sda "mybucket/$BUCKET/app.qcow2"

echo "== 5. генерирую ссылку для VM Disk (presigned, действует 7 дней) =="
echo "   Скопируйте URL из строки 'Share:' ниже — это и есть ссылка для http-import."
echo "   (ссылка временная и подписанная — anonymous-доступ к бакету НЕ нужен)"
mc share download --expire 168h "mybucket/$BUCKET/app.qcow2"

echo ""
echo "== ГОТОВО. В дашборде: VM Disk -> Deploy new -> source = http ->"
echo "   вставьте URL из строки 'Share:' выше."
