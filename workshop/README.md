# Воркшоп: миграция VMware-VM в Cozystack

Берём приложение, которое годами работало на виртуальной машине в VMware, и перевозим
его в Cozystack. Всё делаете своими руками.

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
| 1 | Заводим хранилище под образ | ноутбук |
| 2 | Переупаковываем диск из формата VMware в формат KVM | временная машина |
| 3 | Поднимаем машину на новом месте | ноутбук |
| 4 | Заказываем базу и очередь из каталога | ноутбук |
| 5 | Чиним сеть и переключаем приложение на новые адреса | ваша машина |

Дальше — финальная проверка: заказ, созданный в приложении, доезжает до базы и очереди.

## Доступы

Выдаёт ведущий:

* дашборд https://dashboard.workshop.aenix.io
* логин `workshopXX`, пароль скажут на месте
* kubeconfig — в дашборде: `Info` → вкладка `Secrets` → секрет `kubeconfig-tenant-workshopXX`

Везде дальше `workshopXX` меняйте на свой номер.

## До начала: четыре утилиты

Ставятся на ноутбук один раз, до воркшопа.

| Утилита | Зачем | Установка |
|---|---|---|
| `kubectl` | применяет файлы, показывает, что в кластере | [chat/04](chat/04-install-kubectl.md) |
| `virtctl` | консоль виртуальной машины и проброс порта | [chat/05](chat/05-install-virtctl.md) |
| `kubelogin` | вход через браузер, без него кластер не пустит | [chat/06](chat/06-install-kubelogin.md) |
| `git` | забрать этот репозиторий | [chat/09](chat/09-install-git.md) |

⚠️ **krew для этого воркшопа не нужен** — почему, в [chat/07](chat/07-about-krew.md).

Проверка, что всё встало. Каждая команда печатает версию или справку, а не «команда
не найдена»:

```bash
kubectl version --client
virtctl version --client
kubectl oidc-login --help
```

## Подключаемся к кластеру

Сохраните kubeconfig из дашборда на диск и укажите на него переменной `KUBECONFIG`.

**macOS и Linux** — содержимое секрета положите в `~/.kube/workshop`, затем:

```bash
export KUBECONFIG=~/.kube/workshop
kubectl config current-context
kubectl get vminstance -n tenant-workshopXX
```

**Windows (PowerShell):**

```powershell
New-Item -ItemType Directory -Force "$HOME\.kube" | Out-Null
notepad "$HOME\.kube\workshop"    # вставьте kubeconfig; тип файла — "Все файлы"
[Environment]::SetEnvironmentVariable("KUBECONFIG", "$HOME\.kube\workshop", "User")
$env:KUBECONFIG = "$HOME\.kube\workshop"
kubectl get vminstance -n tenant-workshopXX
```

При первом обращении откроется браузер — залогиньтесь как `workshopXX`.

⚠️ **Windows: файл сохранять только в UTF-8.** Блокнот и перенаправление `>` в PowerShell
пишут UTF-16, и `kubectl` такой файл не прочитает — ответит
`x509: certificate signed by unknown authority`, хотя с сертификатом всё в порядке.

⚠️ Ошибка `dial tcp [::1]:8080 ... refused` означает, что `kubectl` не нашёл kubeconfig,
а не что кластер недоступен. Разбор обеих — в [chat/08](chat/08-connect-to-cluster.md).

## Забираем материалы

```bash
cd ~
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop/workshop
```

⚠️ Хвост `/workshop` обязателен: рядом в репозитории лежит папка `labs` с
самостоятельными лабами, и без него команды не найдут ни `manifests`, ни `scripts`.

Во всех файлах стоит заглушка `tenant-workshopXX`. Подставьте свой номер разом
(в примере — `workshop03`):

```bash
# Linux
find manifests scripts -type f -exec sed -i 's/tenant-workshopXX/tenant-workshop03/g' {} +

# macOS — тот же sed, но требует пустых кавычек после -i
find manifests scripts -type f -exec sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

```powershell
# Windows
Get-ChildItem -Path manifests,scripts -File -Recurse | ForEach-Object {
  (Get-Content $_.FullName -Raw) -replace 'tenant-workshopXX','tenant-workshop03' |
    Set-Content $_.FullName -NoNewline
}
```

Проверяем, что не осталось ни одной заглушки:

```bash
grep -rn tenant-workshopXX manifests scripts || echo "чисто, можно продолжать"
```

Одно место команда не тронет намеренно: в `manifests/03-app-vm.yaml` строка
`url: "ВСТАВЬТЕ_PRESIGNED_URL"` — эту ссылку вы получите после второй фазы.

Подробно: [chat/10](chat/10-clone-and-set-number.md) ·
карта файлов [chat/11](chat/11-file-map.md)

---

## Фаза 1. Хранилище под образ

📍 На ноутбуке.

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

📍 Сначала на ноутбуке, потом внутри временной машины.

Диск из VMware записан в формате VMDK, а KVM читает QCOW2. Переупаковкой занимается
`virt-v2v`; ставить его на ноутбук ради одного раза незачем, поэтому поднимаем
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
`bucketName`, `accessKey` и `secretKey` вместо `ВСТАВЬТЕ_...`, запустить
`bash convert.sh`.

**Должны увидеть:** в конце вывода после слова `Share:` — подписанную ссылку на образ.
Она понадобится на следующей фазе.

Разбор манифеста: [chat/15](chat/15-conversion-vm-manifest.md) ·
разбор скрипта: [chat/17](chat/17-convert-script.md) ·
шаги целиком: [chat/16](chat/16-step-2-conversion-vm.md),
[chat/18](chat/18-step-3-convert-image.md)

---

## Фаза 3. Машина на новом месте

📍 На ноутбуке.

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

📍 На ноутбуке.

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

Забираем схему и накатываем:

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/workshop/scripts/orders-schema.sql

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

### Шаг 3. Проброс порта и проверка снаружи

📍 На ноутбуке.

```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```

Окно не закрывайте — туннель живёт, пока команда работает. Во втором окне:

```bash
curl -s http://localhost:8080/actuator/health

curl -s -X POST http://localhost:8080/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

curl -s http://localhost:8080/api/orders
```

**Должны увидеть:** заказ в списке. Путь пройден целиком.

Подробно: [chat/30](chat/30-step-9-verify-chain.md)

---

## Шпаргалка

> **Префикс `vmi/` нужен не везде, и это не опечатка.** У двух команд разный синтаксис
> цели. `virtctl console` ждёт просто имя и с префиксом отвечает `forbidden`, потому что
> принимает слово `vmi` за имя машины. `virtctl port-forward` требует `тип/имя` и без
> префикса отвечает `target must contain type and name separated by '/'`.

```bash
# зайти в app-VM (root / cozydemo)
virtctl console --namespace=tenant-workshopXX vm-instance-app-1

# зайти в conversion-VM (ubuntu / ubuntu)
virtctl console --namespace=tenant-workshopXX vm-instance-convert

# пробросить порт приложения на ноутбук
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8080:8080
```

Выйти из консоли — `Ctrl+]`. Если после подключения экран пустой, нажмите Enter.
То же самое доступно мышкой: кнопка **VNC** на странице машины в дашборде.

## Уборка

Конвертер после второй фазы не нужен и держит 8Gi из квоты тенанта:

```bash
# Сначала машина, потом диск — в обратном порядке платформа не даст: диск занят.
kubectl delete vminstance convert --namespace tenant-workshopXX
kubectl delete vmdisk convert-tools --namespace tenant-workshopXX
```

## На чём легко застрять

* Для conversion-VM берите только `ubuntu-20.04`. На 24.04 ядро паникует, на 22.04
  `virt-v2v` не разбирает старую RPM-базу CentOS 7.
* VMDisk под каталожный образ должен быть больше самого образа, иначе клон не пройдёт,
  а диск зависнет в `Terminating`. Для `ubuntu-20.04` хватает 25Gi.
* На свежей app-VM сначала `netfix`, потом `connect` — иначе приложение не увидит
  managed-сервисы.
* Не открывайте `.yaml` в Word или Google Docs: они подменяют кавычки и дефисы, файл
  перестаёт применяться, а ошибка выглядит необъяснимо.

Остальные грабли — [chat/31](chat/31-troubleshooting.md).

## Для тех, кто разворачивает стенд

Квоты, порядок создания тенантов и версия платформы — в [REQUIREMENTS.md](../REQUIREMENTS.md).

## Все сообщения по порядку

Список из 32 сообщений — [chat/README.md](chat/README.md).
