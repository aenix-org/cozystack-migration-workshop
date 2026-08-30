# Воркшоп: миграция VMware-VM в Cozystack (через виртуалку)

Берём приложение, которое годами работало на виртуальной машине в VMware, и перевозим
его в Cozystack. Всё делаете своими руками.

**Это путь через общую виртуалку (bastion).** Ставить на свой ноутбук ничего не нужно:
`kubectl`, `virtctl` и `git` уже стоят на виртуалке, ваш доступ к кластеру там уже
настроен. Вы заходите на неё по SSH и работаете прямо там, а готовое приложение
открываете в браузере по доменному имени.

> Если вы работаете со своего ноутбука (ставите инструменты сами, ходите в приложение
> через `port-forward`) — вам нужен второй набор, [`../laptop/`](../laptop/).

Этот файл — маршрут: что за чем идёт, какие команды набирать и что должно получиться.
Объяснения, почему всё устроено именно так, и разборы манифестов и скриптов построчно
лежат в папке [`chat/`](chat/) — по одному файлу на сообщение. Ссылки стоят в конце
каждого шага.

## Маршрут

Приложение живёт на трёх машинах: само приложение, база данных и очередь сообщений.
Перевозим только первую — база и очередь останутся в прошлом, вместо них возьмём
готовые из каталога Cozystack.

| Фаза | Что делаем | Где |
|---|---|---|
| 1 | Заводим хранилище под образ | на виртуалке |
| 2 | Переупаковываем диск из формата VMware в формат KVM | во временной машине |
| 3 | Поднимаем машину на новом месте | на виртуалке |
| 4 | Заказываем базу и очередь из каталога | на виртуалке |
| 5 | Чиним сеть и переключаем приложение на новые адреса | в вашей машине |

Дальше — финальная проверка: заказ, созданный в приложении, доезжает до базы и очереди.

## Что вам выдал ведущий

Один логин и один пароль — они одинаковы во всех трёх местах:

* **дашборд** https://dashboard.workshop.aenix.io — вход в браузере, namespace `tenant-workshopXX`
* **виртуалка** — вход по SSH: `ssh workshopXX@<адрес-виртуалки>`
* внутри виртуалки доступ к кластеру уже настроен, kubeconfig лежит в `~/.kube/config`

Везде дальше `workshopXX` меняйте на свой номер (его выдал ведущий).

## Заходим на виртуалку

```bash
ssh workshopXX@<адрес-виртуалки>
```

Пароль — тот же, что от дашборда. SSH-ключ не нужен: вход по паролю. Проверяем, что
доступ к кластеру на месте (браузер при этом не открывается — на виртуалке настроен
прямой доступ по токену, без Keycloak):

```bash
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

**Должны увидеть:** имя контекста `tenant-workshopXX` и (пока пусто) список машин.

## Материалы уже на виртуалке

Клонировать ничего не нужно — папка с материалами лежит в вашей домашней директории,
и ваш номер тенанта в манифестах и скриптах **уже подставлен**: заглушки
`tenant-workshopXX` заменены на ваш `tenant-workshopNN` при подготовке виртуалки.
Ничего искать и заменять не нужно — сразу применяйте файлы как есть.

```bash
cd ~/workshop
ls manifests scripts
grep -rl tenant-workshop manifests | head -1 | xargs grep -m1 namespace   # увидите свой номер
```

Одно место остаётся заглушкой намеренно: в `manifests/03-app-vm.yaml` строка
`url: "ВСТАВЬТЕ_PRESIGNED_URL"` — эту ссылку вы получите после второй фазы и впишете сами.

Подробно: [chat/10](chat/10-clone-and-set-number.md) ·
карта файлов [chat/11](chat/11-file-map.md)

---

## Фаза 1. Хранилище под образ

📍 На виртуалке.

Переупакованный диск нужно положить туда, откуда его заберёт платформа по сети.
Заводим бакет — объектное хранилище с S3-интерфейсом.

```bash
kubectl apply -f manifests/01-bucket.yaml
kubectl get buckets.apps.cozystack.io my-images -n tenant-workshopXX
```

**Должны увидеть:** `bucket.apps.cozystack.io/my-images created`, затем `READY: True`.

⚠️ **Имя типа пишем полностью, не `bucket`.** Слово занято в кластере трижды: наш тип из
каталога, тип Flux и тип стандарта объектных хранилищ. Какой из трёх подставит `kubectl`
по короткому имени — заранее не известно, и если чужой, вы получите отказ в правах на
ресурс, которого не просили: `buckets.source.toolkit.fluxcd.io is forbidden`. Это не
проблема с доступом, чинить её не надо.

⚠️ **Если `apply` падает с `SchemaError … unknown model in reference`** — спотыкается
проверка на вашей стороне, а не кластер; манифест верный. Обойти:
`kubectl apply -f manifests/01-bucket.yaml --validate=false`. Флаг снимает только местную
проверку, сервер всё равно проверит объект у себя.

**Дальше понадобятся ключи:** дашборд → `Bucket` → `my-images` → вкладка `Secrets` →
секрет `bucket-my-images-app-credentials`. Оттуда берёте `bucketName`, `accessKey`
и `secretKey` — впишете их в скрипт на следующей фазе.

Разбор манифеста: [chat/13](chat/13-bucket-manifest.md) ·
шаг целиком: [chat/14](chat/14-step-1-bucket.md)

---

## Фаза 2. Переупаковка диска

📍 Сначала на виртуалке, потом внутри временной машины.

Диск из VMware записан в формате VMDK, а KVM читает QCOW2. Переупаковкой занимается
`virt-v2v`; ставить его на виртуалку ради одного раза незачем, поэтому поднимаем
временную машину с уже готовыми инструментами.

```bash
kubectl apply -f manifests/02-conversion-vm.yaml
kubectl get vminstance convert -n tenant-workshopXX -w
```

**Должны увидеть:** две строки с `created`, затем `Running`.

⚠️ `Running` означает «включилась», а не «готова»: внутри ещё несколько минут работает
`cloudInit` — ставит пакеты и качает `mc`. Зайдёте раньше — не найдёте `virt-v2v`.

Заходим внутрь (логин `ubuntu`, пароль `ubuntu`):

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-convert
```

Внутри: `nano convert.sh`, вставить текст `scripts/convert.sh`, вписать свои
`bucketName`, `accessKey` и `secretKey` вместо `ВСТАВЬТЕ_...`.

⚠️ **Запускайте конвертацию в `screen`** — она идёт минут пять, и если SSH-сессия
до виртуалки оборвётся, обычный запуск прервётся на середине. `screen` держит процесс,
даже когда связь пропала:

```bash
screen -S convert          # войти в отдельную сессию
sudo bash convert.sh       # запустить внутри неё
#  оборвалась связь? снова ssh на виртуалку, потом:  screen -r convert
```

**Должны увидеть:** в конце вывода после слова `Share:` — подписанную ссылку на образ.
Она понадобится на следующей фазе.

Разбор манифеста: [chat/15](chat/15-conversion-vm-manifest.md) ·
разбор скрипта: [chat/17](chat/17-convert-script.md) ·
шаги целиком: [chat/16](chat/16-step-2-conversion-vm.md),
[chat/18](chat/18-step-3-convert-image.md)

---

## Фаза 3. Машина на новом месте

📍 На виртуалке.

⚠️ Сначала погасите машину-конвертер — она своё отработала и держит 8Gi вашей квоты.
Если её не убрать, новая машина повиснет в `Pending`:

```bash
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```

Впишите полученную ссылку в `manifests/03-app-vm.yaml` вместо
`url: "ВСТАВЬТЕ_PRESIGNED_URL"`, затем:

```bash
kubectl apply -f manifests/03-app-vm.yaml
kubectl get vminstance app-1 -n tenant-workshopXX -w
```

**Должны увидеть:** две строки с `created`, затем `Running`. Здесь ожидание дольше —
платформа скачивает образ по вашей ссылке.

Заходим внутрь (логин `root`, пароль `cozydemo`):

```bash
virtctl console --namespace=tenant-workshopXX vm-instance-app-1
```

⚠️ **Сети внутри не будет.** Это не поломка стенда — так и должно быть. Чиним
на пятой фазе.

Разбор манифеста: [chat/20](chat/20-app-vm-manifest.md) ·
шаг целиком: [chat/21](chat/21-step-4-your-vm.md)

---

## Фаза 4. База и очередь из каталога

📍 На виртуалке.

```bash
kubectl apply -f manifests/04-managed.yaml
kubectl get postgreses.apps.cozystack.io,kafkas.apps.cozystack.io -n tenant-workshopXX
```

**Должны увидеть:** `postgres.apps.cozystack.io/db created` и
`kafka.apps.cozystack.io/kafka created`. Kafka поднимается заметно дольше Postgres.

Разбор манифеста: [chat/23](chat/23-managed-manifest.md) ·
шаг целиком: [chat/24](chat/24-step-5-database-and-queue.md)

---

## Фаза 5. Подключаем приложение

📍 Внутри вашей виртуальной машины.

Три действия строго по порядку: без сети скрипт не достучится до базы, а без базы
не примет схему.

| Шаг | Что чиним | Чем |
|---|---|---|
| 5.1 | машина не в сети | `scripts/netfix-dhcp.sh` |
| 5.2 | приложение ищет старые адреса | `scripts/connect-managed.sh` |
| 5.3 | в новой базе нет таблиц | `scripts/orders-schema.sql` |

**5.1.** Скрипт меняет `BOOTPROTO=static` на `dhcp` и убирает адрес из сети VMware.
Набирается руками — сети у машины ещё нет, скачать файл не получится. После этого
машину нужно **перезагрузить**: CentOS 7 применяет настройки сети при загрузке.

**5.2.** Скрипт заменяет в `/etc/orders/application.properties` прибитые адреса
`192.168.10.30` и `192.168.10.40` на имена сервисов и перезапускает приложение.

**5.3.** Ставим клиент `psql` и накатываем схему — команды ниже, в финальной проверке.

Подробно: [chat/25](chat/25-step-6-fix-networking.md) ·
[chat/26](chat/26-first-check-fails.md) ·
[chat/27](chat/27-step-7-switch-app.md)

---

## Финальная проверка: три шага по порядку

### Шаг 1. Погасить firewalld

📍 Внутри вашей машины. Правила остались из старой сети и режут обращения к приложению.

```bash
systemctl stop firewalld && systemctl disable firewalld
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```

**Должны увидеть:** `200`. Если `503` — что-то из базы или очереди не подключилось.
Здесь `localhost` — это сама машина, в которой вы сидите: приложение проверяется изнутри.

### Шаг 2. Схема базы

📍 Внутри вашей машины. Штатному psql из CentOS 7 версия 9.2, он не умеет SCRAM и
отвечает `SCRAM authentication requires libpq version 10 or above`. Ставим свежий:

```bash
# 1. Репозиторий PGDG — источник пакетов PostgreSQL
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. libzstd: в репозиториях CentOS 7 её нет, берём из архива EPEL
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. Сам клиент — только из живого репозитория pgdg15
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

⚠️ Вторая и третья команды не лишние. Без `libzstd` установка падает на
`Requires: libzstd >= 1.4.0`. Без `--disablerepo`/`--enablerepo` — на
`HTTPS Error 410 - Gone`: пакет репозитория включает разом все версии PostgreSQL,
включая снятые с поддержки 12-ю и 13-ю, а `yum` перед установкой обходит каждый
включённый репозиторий и падает на первом мёртвом.

```bash
psql --version
```

Если `command not found` — клиент лёг мимо `PATH`: посмотрите
`ls /usr/pgsql-*/bin/psql`, затем `export PATH="$PATH:/usr/pgsql-15/bin"`.

Забираем схему и накатываем (эта app-VM в интернет ходит, файл скачается):

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/bastion/scripts/orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders \
  -f orders-schema.sql

PGPASSWORD='Orders2019!' psql \
  -h postgres-db-rw.tenant-workshopXX.svc.cozy.local -U orders -d orders -c '\dt'
```

**Должны увидеть:** в последней команде — таблицу `orders`.

Адрес базы — не IP, а имя: `postgres-db-rw` (сервис `db` на чтение-запись),
`tenant-workshopXX` (ваш namespace), `svc.cozy.local` (суффикс внутренних имён
кластера). Пароль задан в `manifests/04-managed.yaml`, искать его нигде не надо.

Подробно: [chat/28](chat/28-step-8-why-it-still-fails.md) ·
[chat/29](chat/29-step-8-apply-schema.md)

### Шаг 3. Проверка снаружи — по доменному имени

📍 В браузере на своём ноутбуке или через `curl` на виртуалке.

Здесь и проявляется главное отличие этого пути: **проброс порта не нужен.** Ведущий
заранее создал в вашем тенанте `Ingress`, и как только приложение внутри машины слушает
`8080`, магазин публикуется по адресу `https://app.workshopXX.workshop.aenix.io`
(`XX` — ваш номер). Проверяйте прямо оттуда:

```bash
curl -s https://app.workshopXX.workshop.aenix.io/actuator/health

curl -s -X POST https://app.workshopXX.workshop.aenix.io/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

curl -s https://app.workshopXX.workshop.aenix.io/api/orders
```

**Должны увидеть:** заказ в списке. Путь пройден целиком.

⚠️ Пока app-VM не поднята или ещё грузится, домен отвечает `503` — это нормально:
`Ingress` ждёт бэкенд. После старта машины (внутри слушается `8080`) станет `200`.

Подробно: [chat/30](chat/30-step-9-verify-chain.md)

---

## Шпаргалка

> **Префикс `vmi/` нужен не всем командам, и это не опечатка.** Под правами тенанта
> `virtctl console` принимает только **голое** имя (`vm-instance-app-1`); с `vmi/` он
> отвечает `forbidden`, приняв слово `vmi` за имя машины. А `virtctl ssh` и
> `virtctl port-forward`, наоборот, требуют форму `vmi/<имя>`.

```bash
# зайти в app-VM (root / cozydemo)
virtctl console --namespace=tenant-workshopXX vm-instance-app-1

# зайти в conversion-VM (ubuntu / ubuntu)
virtctl console --namespace=tenant-workshopXX vm-instance-convert

# оболочка внутри app-VM по SSH (когда сеть в машине уже поднята)
virtctl ssh ubuntu@vmi/vm-instance-app-1 --namespace=tenant-workshopXX
```

Проверка приложения — по домену `https://app.workshopXX.workshop.aenix.io`, `port-forward`
на этом пути не нужен. Выйти из консоли — `Ctrl+]`. Если после подключения экран пустой,
нажмите Enter. То же самое доступно мышкой: кнопка **VNC** на странице машины в дашборде.

## На чём легко застрять

* Для conversion-VM берите только `ubuntu-20.04`. На 24.04 ядро паникует, на 22.04
  `virt-v2v` не разбирает старую RPM-базу CentOS 7.
* VMDisk под каталожный образ должен быть больше самого образа, иначе клон не пройдёт,
  а диск зависнет в `Terminating`. Для `ubuntu-20.04` хватает 25Gi.
* На свежей app-VM сначала `netfix`, потом `connect` — иначе приложение не увидит
  managed-сервисы.
* Долгую конвертацию запускайте в `screen` — иначе разрыв SSH прервёт её на середине.

Остальные грабли — [chat/31](chat/31-troubleshooting.md).

## Для тех, кто разворачивает стенд

Квоты, порядок создания тенантов и версия платформы — в [REQUIREMENTS.md](../REQUIREMENTS.md).

## Все сообщения по порядку

Список из 27 сообщений — [chat/README.md](chat/README.md).
