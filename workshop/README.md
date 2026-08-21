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
* логин `workshopXX`, пароль скажут на месте
* kubeconfig берётся в дашборде: Info, вкладка Secrets, секрет `kubeconfig-tenant-workshopXX`

Дальше везде `tenant-workshopXX` меняйте на свой namespace.

## Инструменты

Нужны `kubectl`, `virtctl` и `kubelogin`. Все три есть под Linux, macOS и Windows.

`kubectl` ставится по официальной инструкции https://kubernetes.io/docs/tasks/tools/
(на Linux это curl бинарника, на маке `brew install kubectl`, на винде
`winget install -e --id Kubernetes.kubectl`).

На macOS/Linux `virtctl` и `kubelogin` проще всего поставить плагинами через krew
(https://krew.sigs.k8s.io/docs/user-guide/setup/install/):

```bash
kubectl krew install virt
kubectl krew install oidc-login
```

**На Windows krew обычно НЕ работает** — падает с `A required privilege is not held
by the client` (krew создаёт симлинки, а это требует «Режима разработчика» или прав
администратора, на корп-ноутах закрыто). Не тратьте время: ставьте бинарники напрямую.

**Windows** (PowerShell, папка `$HOME\bin` и её добавление в PATH — см. установку kubectl):

```powershell
# virtctl
$ver = (Invoke-RestMethod https://api.github.com/repos/kubevirt/kubevirt/releases/latest).tag_name
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -Uri "https://github.com/kubevirt/kubevirt/releases/download/$ver/virtctl-$ver-windows-amd64.exe" -OutFile "$HOME\bin\virtctl.exe"
# kubelogin -> имя плагина обязательно kubectl-oidc_login.exe
Invoke-WebRequest -Uri "https://github.com/int128/kubelogin/releases/latest/download/kubelogin_windows_amd64.zip" -OutFile "$HOME\kubelogin.zip"
Expand-Archive -Force "$HOME\kubelogin.zip" "$HOME\kl"
Move-Item -Force "$HOME\kl\kubelogin.exe" "$HOME\bin\kubectl-oidc_login.exe"
Remove-Item -Recurse -Force "$HOME\kubelogin.zip","$HOME\kl"
```

Откройте новое окно PowerShell и проверьте: `virtctl version`, `kubectl oidc-login --help`.
На macOS/Linux те же бинарники лежат на релизах KubeVirt
(https://github.com/kubevirt/kubevirt/releases) и kubelogin
(https://github.com/int128/kubelogin/releases, на маке ещё
`brew install int128/kubelogin/kubelogin`).

kubelogin нужен, потому что kubeconfig ходит в кластер через Keycloak: при первом
`kubectl` откроется браузер, залогиньтесь как `workshopXX`.

Место, где легко споткнуться: `KUBECONFIG` должен указывать ровно на тот файл,
куда вы вставили kubeconfig. macOS/Linux:

```bash
export KUBECONFIG=~/.kube/workshop
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

Windows (PowerShell) — переменную задаём и на текущее окно, и на будущие:

```powershell
New-Item -ItemType Directory -Force "$HOME\.kube" | Out-Null
notepad "$HOME\.kube\workshop"    # вставьте kubeconfig; тип файла = Все файлы, иначе Блокнот добавит .txt
[Environment]::SetEnvironmentVariable("KUBECONFIG", "$HOME\.kube\workshop", "User")
$env:KUBECONFIG = "$HOME\.kube\workshop"
kubectl get vminstance -n tenant-workshopXX
```

Если kubectl отвечает `dial tcp [::1]:8080 ... refused` (или `localhost:8080`) — он не
видит kubeconfig: переменная `KUBECONFIG` не задана в этом окне или указывает не на тот
файл. На Windows `$env:KUBECONFIG` живёт только в текущем окне, поэтому его и закрепляют
через `SetEnvironmentVariable(... "User")`.

Кстати, `kubectl get vmi` или `vm` под тенантом не сработают, `kubevirt.io`
напрямую закрыт. Смотрите `vminstance`.

## Что где лежит и как применять

Склонируйте репу:

```bash
git clone git@github.com:aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop
```

Дальше важный момент. Во всех файлах вместо вашего namespace стоит заглушка
`tenant-workshopXX`. Если применить манифест как есть, он уедет не туда или вернёт
ошибку. Поэтому первым делом подставьте свой номер во все файлы разом. Допустим,
ваш логин `workshop03`, тогда:

```bash
# Linux
find manifests scripts -type f -exec sed -i 's/tenant-workshopXX/tenant-workshop03/g' {} +
# macOS (там sed чуть другой)
find manifests scripts -type f -exec sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

Проверьте, что подставилось (не должно остаться ни одного `tenant-workshopXX`):

```bash
grep -rn tenant-workshopXX manifests scripts || echo "чисто, можно продолжать"
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
(их берёте в дашборде), заходите в нужную VM через `virtctl console`,
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

Дождитесь Running, зайдите внутрь через консоль (`virtctl console vmi/vm-instance-convert`, login `ubuntu`,
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

Фаза 5, подключение. Зайдите в app-VM (`virtctl console vmi/vm-instance-app-1`) и по
порядку: сперва `netfix-dhcp.sh` переключает eth0 на DHCP (после этого VM надо
перезапустить), потом `connect-managed.sh` переписывает конфиг на managed-адреса,
потом накатываете `orders-schema.sql` в Postgres. Порядок важен: пока сеть на
статичном VMware-IP, managed не резолвится.

## Шпаргалка

> Во всех командах `virtctl` цель указывайте с префиксом `vmi/`
> (`vmi/vm-instance-app-1`), а не голым именем. Под tenant-доступом права выданы на
> subresource `virtualmachineinstances` (vmi), а не на `virtualmachines` (vm) —
> голое имя бьёт в vm-объект и вернёт `forbidden`. Для `port-forward` это ещё и
> синтаксис: без `vmi/` virtctl отвечает `target must contain type and name
> separated by '/'`.

```bash
# зайти в app-VM (root/cozydemo)
virtctl console --namespace=tenant-workshopXX vmi/vm-instance-app-1

# зайти в conversion-VM (login ubuntu / пароль ubuntu)
virtctl console --namespace=tenant-workshopXX vmi/vm-instance-convert
```

Выйти из консоли — `Ctrl+]`. Если после подключения экран пустой, нажмите Enter.
То же самое доступно мышкой: кнопка **VNC** на странице машины в дашборде.

---

## Финальная проверка: три шага строго по порядку

Здесь спотыкаются чаще всего, поэтому подробно и с указанием, где что выполнять.

### Шаг 1. Погасить firewalld

**Где:** внутри app-VM.

Мигрированный CentOS принёс правила из прошлой жизни и наружу открывает только SSH.
Порт приложения 8080 закрыт, поэтому и `port-forward`, и проверки будут выглядеть
так, будто приложение не работает. Гасим до всех остальных проверок:

```bash
systemctl stop firewalld
systemctl disable firewalld
```

Убедиться, что приложение живо изнутри самой машины:

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/actuator/health
```

`200` — база и очередь на месте. `503` — возвращайтесь к сети: `netfix-dhcp.sh`
и перезагрузка, managed-сервисы ещё не резолвятся.

### Шаг 2. Схема базы

**Где:** внутри app-VM. Она уже в сети кластера и видит базу по имени —
ставить клиент на ноутбук не нужно.

**Клиент psql.** Штатный клиент CentOS 7 — версии 9.2, он не умеет аутентификацию
SCRAM и отвечает `psql: SCRAM authentication requires libpq version 10 or above`.
Нужен клиент 10 или новее; для CentOS 7 в репозитории PGDG доступен максимум 15-й:

```bash
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm
```

Новый клиент кладётся мимо `PATH` — это вторая ловушка, та самая «psql: command not found»:

```bash
yum install -y postgresql15
command -v psql || ls /usr/bin/psql /usr/pgsql-*/bin/psql 2>/dev/null
```

Если нашёлся в `/usr/pgsql-*/bin/`, добавьте каталог в `PATH` на текущую сессию
(версию подставьте из вывода выше) и проверьте:

```bash
export PATH="$PATH:/usr/pgsql-15/bin"
psql --version
```

**Куда подключаться.** Короткое имя изнутри гостя не резолвится, нужен полный адрес
сервиса — со своим номером вместо `XX`:

```
postgres-db-rw.tenant-workshopXX.svc.cozy.local
```

**Пароль.** Роль `orders`, пароль `Orders2019!` — он прописан в
`manifests/04-managed.yaml`, искать его нигде не надо.

**Накатываем схему.** Файл `scripts/orders-schema.sql` из этого репозитория:

```bash
PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders \
  -f orders-schema.sql
```

Проверить, что таблица на месте:

```bash
PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders -c '\dt'
```

Отдельный грант под суперпользователем не нужен: роль `orders` входит в `orders_admin`,
который владеет и базой, и схемой `public`, — права на создание таблиц у неё уже есть.

Почему это отдельный шаг: проверка здоровья смотрит только на подключение к базе
и честно ответит `200` даже без таблицы. А вот создать заказ не выйдет — придёт `500`.

### Шаг 3. Проброс порта и проверка снаружи

**Где:** на ноутбуке.

```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```

Окно не закрывайте: туннель живёт, пока команда работает. Во втором окне:

```bash
# health, 200 значит Postgres и Kafka на месте
curl -s http://localhost:8080/actuator/health

# создать заказ: запись уходит в Postgres, событие — в Kafka
curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

# посмотреть список
curl -s http://localhost:8080/api/orders
```

Заказ создался — путь пройден целиком.

---

## На чём ещё легко застрять

Для conversion-VM берите только `ubuntu-20.04`. На 24.04 ядро паникует, на 22.04
virt-v2v не разбирает старую RPM-базу CentOS 7.

VMDisk под каталожный образ должен быть больше самого образа, иначе клон не
пройдёт, а диск потом зависает в Terminating. Для ubuntu-20.04 хватает 25Gi.

На свежей app-VM сначала netfix, потом connect, именно в таком порядке. Иначе
приложение не увидит managed.

Конвертер после третьей фазы не нужен и держит 8Gi из квоты тенанта. Удаляйте оба
объекта — машину и диск:

```bash
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```
