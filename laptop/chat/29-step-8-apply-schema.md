## 29. Шаг 8: ставим клиент и накатываем схему

**Доступ к базе:**
```
хост:   postgres-db-rw.tenant-workshopXX.svc.cozy.local
база:   orders
логин:  orders
пароль: Orders2019!
```
Пароль задан в `manifests/04-managed.yaml`, искать его нигде не надо.

⚠️ **Штатный psql из CentOS 7 не подойдёт.** Ему 9.2 года выпуска, а наша база требует
аутентификации SCRAM, которую он не умеет, и отвечает:
`psql: SCRAM authentication requires libpq version 10 or above`. Нужен клиент версии 10 или новее.
Берём из репозитория PGDG — для CentOS 7 там доступен максимум 15-й.

Три команды подряд, по одной причине на каждую:

```bash
# 1. Подключаем репозиторий PGDG — источник пакетов PostgreSQL.
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

# 2. Библиотека libzstd, без неё клиент не поставится. В репозиториях CentOS 7 её нет,
#    берём из архива EPEL.
yum install -y https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/l/libzstd-1.5.5-1.el7.x86_64.rpm

# 3. Сам клиент — только из живого репозитория pgdg15.
yum install -y --disablerepo='pgdg*' --enablerepo=pgdg15 postgresql15
```

Вторая и третья команды выглядят избыточно, но без них установка падает, и обе ошибки
вы иначе увидите своими глазами:

- без `libzstd` — `Requires: libzstd >= 1.4.0`;
- без `--disablerepo`/`--enablerepo` — `HTTPS Error 410 - Gone`. Пакет репозитория
  включает разом все версии PostgreSQL, включая снятые с поддержки 12-ю и 13-ю, а `yum`
  перед установкой обходит **каждый** включённый репозиторий и падает на первом мёртвом.
  Мы явно оставляем только тот, который нам нужен.

Проверяем, что клиент на месте:

```bash
psql --version
```

Если ответ — `command not found`, клиент положен мимо `PATH`; найдите его и допишите
каталог на текущую сессию:

```bash
ls /usr/pgsql-*/bin/psql
export PATH="$PATH:/usr/pgsql-15/bin"
psql --version
```

**Забираем файл схемы** — сеть у машины уже есть:

```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/laptop/scripts/orders-schema.sql
```

**Накатываем.** Разберём команду по частям, чтобы не вводить вслепую:

```bash
PGPASSWORD='Orders2019!' psql -h postgres-db-rw.tenant-workshopXX.svc.cozy.local \
  -U orders -d orders -f orders-schema.sql
```

- `PGPASSWORD='...'` — пароль передаётся переменной окружения, чтобы `psql` не
  спрашивал его в диалоге. Так делают в скриптах.
- `-h postgres-db-rw.tenant-workshopXX.svc.cozy.local` — адрес базы. Это **не IP**, а
  внутреннее имя в кластере. Суффикс `-rw` важен: у managed Postgres несколько копий,
  и это имя всегда указывает на ту, в которую **можно писать**. Есть парное имя с `-ro`
  — только для чтения. При переключении ролей между копиями имя не меняется, поэтому в
  настройках приложения прописывают его, а не адрес конкретного сервера.
- `-U orders` — под каким пользователем, `-d orders` — в какую базу.
- `-f orders-schema.sql` — выполнить команды из файла.

Именно возможность обращаться к базе по постоянному имени, а не по IP, и делает
переключение копий незаметным для приложения. На старой машине у вас в конфиге стоял
`localhost`, и никакого переключения не было в принципе.

Проверяем, что таблица на месте:

```bash
PGPASSWORD='Orders2019!' psql -h postgres-db-rw.tenant-workshopXX.svc.cozy.local \
  -U orders -d orders -c '\dt'
```

Появилась — значит, заказ теперь создастся. Проверим это на следующем шаге, вместе
со всей цепочкой.
