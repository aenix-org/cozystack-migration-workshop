# Воркшоп: миграция VMware-VM в Cozystack

Берём старое приложение, которое крутилось на виртуалке в VMware, и переезжаем с
ним в Cozystack. Всё делаете сами: конвертируете образ, поднимаете свою VM,
подключаете managed Postgres и Kafka. В репе лежат манифесты, скрипты и шпаргалка.

## Как выглядит маршрут

Заходите в свой тенант, создаёте бакет под образ. Поднимаете conversion-VM, и
прямо в ней `virt-v2v` конвертит VMware-OVA в qcow2, а скрипт заливает результат
в ваш бакет. Из этого образа поднимаете app-VM. Рядом из каталога поднимаете
managed Postgres и Kafka. Остаётся подключить приложение: переключить сеть VM на
pod-NIC и переписать конфиг на managed-адреса. После этого заказы, которые
создаёт приложение, пишутся в Postgres и улетают в Kafka.

## Доступы

Их выдаёт ведущий:

* дашборд https://dashboard.workshop.aenix.io
* логин `pXX`, пароль скажут на месте
* kubeconfig берётся в дашборде: Info, вкладка Secrets, секрет `kubeconfig-tenant-pXX`

Дальше везде `tenant-pXX` меняйте на свой namespace.

## Инструменты

Нужны `kubectl`, `virtctl` и `kubelogin`. Все три есть под Linux, macOS и Windows.

`kubectl` ставится по официальной инструкции https://kubernetes.io/docs/tasks/tools/
(на Linux это curl бинарника, на маке `brew install kubectl`, на винде
`winget install -e --id Kubernetes.kubectl`).

`virtctl` и `kubelogin` проще всего поставить плагинами через krew
(https://krew.sigs.k8s.io/docs/user-guide/setup/install/):

```bash
kubectl krew install virt
kubectl krew install oidc-login
```

Если с krew возиться не хочется, обе утилиты лежат бинарниками под все ОС:
virtctl на релизах KubeVirt https://github.com/kubevirt/kubevirt/releases,
kubelogin на https://github.com/int128/kubelogin/releases (на маке ещё
`brew install int128/kubelogin/kubelogin`, на винде `choco install kubelogin`).

kubelogin нужен, потому что kubeconfig ходит в кластер через Keycloak: при первом
`kubectl` откроется браузер, залогиньтесь как `pXX`.

Место, где легко споткнуться: `KUBECONFIG` должен указывать ровно на тот файл,
куда вы вставили kubeconfig. Проверьте:

```bash
export KUBECONFIG=~/.kube/workshop-pXX
kubectl config current-context
kubectl get vminstance -n tenant-pXX
```

Кстати, `kubectl get vmi` или `vm` под тенантом не сработают, `kubevirt.io`
напрямую закрыт. Смотрите `vminstance`.

## Что где лежит и как применять

Склонируйте репу:

```bash
git clone git@github.com:aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop
```

Дальше важный момент. Во всех файлах вместо вашего namespace стоит заглушка
`tenant-pXX`. Если применить манифест как есть, он уедет не туда или вернёт
ошибку. Поэтому первым делом подставьте свой номер во все файлы разом. Допустим,
ваш логин `p03`, тогда:

```bash
# Linux
find manifests scripts -type f -exec sed -i 's/tenant-pXX/tenant-p03/g' {} +
# macOS (там sed чуть другой)
find manifests scripts -type f -exec sed -i '' 's/tenant-pXX/tenant-p03/g' {} +
```

Проверьте, что подставилось (не должно остаться ни одного `tenant-pXX`):

```bash
grep -rn tenant-pXX manifests scripts || echo "чисто, можно продолжать"
```

Одну вещь эта команда не тронет: в `manifests/03-app-vm.yaml` есть строка
`url: "ВСТАВЬТЕ_PRESIGNED_URL"`. Эту ссылку вы получите позже, когда сконвертируете
образ (её напечатает `convert.sh`), и впишете руками перед третьей фазой. Пока
просто помните, что она там ждёт.

Теперь про два типа файлов, они работают по-разному.

Манифесты из `manifests/` вы применяете со своей машины через `kubectl apply`. Это
описания того, что создать в кластере (бакет, виртуалки, базы).

Скрипты из `scripts/` вы запускаете не у себя, а внутри виртуалки. Порядок такой:
открываете скрипт в редакторе, вписываете свои значения вместо `ВСТАВЬТЕ_...`
(их берёте в дашборде), заходите в нужную VM через `virtctl console` или `ssh`,
переносите туда текст скрипта (проще всего открыть `nano имя.sh`, вставить,
сохранить) и запускаете `bash имя.sh`.

## Фазы

Фаза 1, бакет:

```bash
kubectl apply -f manifests/01-bucket.yaml
```

Креды бакета потом возьмёте в дашборде (Bucket, ваш бакет, Secrets) и впишете в
`convert.sh`.

Фаза 2, conversion-VM:

```bash
kubectl apply -f manifests/02-conversion-vm.yaml
```

Дождитесь Running, зайдите внутрь (`virtctl ssh ubuntu@vm-instance-convert`,
пароль `ubuntu`), впишите креды в `convert.sh` и запустите. virt-v2v сконвертит
OVA в qcow2 и зальёт в ваш бакет, а в конце напечатает presigned-ссылку.

Фаза 3, app-VM. Вставьте presigned-ссылку в `03-app-vm.yaml` (поле `url`) и
примените:

```bash
kubectl apply -f manifests/03-app-vm.yaml
```

Внутрь заходите под `root`/`cozydemo`.

Фаза 4, managed Postgres и Kafka:

```bash
kubectl apply -f manifests/04-managed.yaml
```

Фаза 5, подключение. Зайдите в app-VM (`virtctl console vm-instance-app-1`) и по
порядку: сперва `netfix-dhcp.sh` переключает eth0 на DHCP (после этого VM надо
перезапустить), потом `connect-managed.sh` переписывает конфиг на managed-адреса,
потом накатываете `orders-schema.sql` в Postgres. Порядок важен: пока сеть на
статичном VMware-IP, managed не резолвится.

## Шпаргалка

```bash
# зайти в app-VM (root/cozydemo)
virtctl console --namespace=tenant-pXX vm-instance-app-1

# зайти в conversion-VM (ubuntu/ubuntu)
virtctl ssh --namespace=tenant-pXX ubuntu@vm-instance-convert

# пробросить приложение на localhost
virtctl port-forward --namespace=tenant-pXX vmi/vm-instance-app-1 8088:8080

# health, 200 значит Postgres и Kafka на месте
curl -s http://localhost:8088/actuator/health

# создать заказ (пишется в Postgres, событие уходит в Kafka)
curl -s -X POST http://localhost:8088/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'
```

## На чём легко застрять

Для conversion-VM берите только `ubuntu-20.04`. На 24.04 ядро паникует, на 22.04
virt-v2v не разбирает старую RPM-базу CentOS 7.

VMDisk под каталожный образ должен быть больше самого образа, иначе клон не
пройдёт, а диск потом зависает в Terminating. Для ubuntu-20.04 хватает 25Gi.

На свежей app-VM сначала netfix, потом connect, именно в таком порядке. Иначе
приложение не увидит managed.

Схема в базе это два действия, а не одно. Сперва под superuser выдаётся GRANT на
схему public, и только потом создаётся таблица (`orders-schema.sql`). Если таблицы
нет, приложение отвечает 500 на создание заказа, хотя health при этом честные 200:
он проверяет только коннект к базе.

Если приложение не видно снаружи или через port-forward, в мигрированном CentOS
обычно виноват firewalld, он закрывает 8080. Гасится через `systemctl stop firewalld`.
