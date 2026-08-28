#!/usr/bin/env bash
# Проверка лабы 10: в MongoDB лежат пропуска разной формы и по ним ищут.
#
# Проверяем не «сервис создан», а суть: в коллекции есть документы всех четырёх
# форм, поиск по вложенному полю и внутрь списка работает, на редкое поле
# построен разреженный индекс, валидатор схемы включён, а документов без типа
# не осталось.
#
# Запуск (в каждом новом окне терминала переменные задаются заново):
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # свой номер вместо XX
#   export MONGO_PASSWORD='пароль пользователя passapp'
#   cd labs/10-mongodb && ./check.sh
#
# Пароль не печатается и в отчёт не попадает.
# Скрипт поднимает одноразовые поды, поэтому работает около минуты.

# Имя и заголовок нужны общей библиотеке: она подписывает ими отчёт-артефакт.
# В lib.sh лежат ok/fail/warn/evidence/finish и проверки окружения ниже — чтобы
# пятнадцать скриптов проверки печатали одинаково, а не каждый по-своему.
LAB_NAME="10-mongodb"
LAB_TITLE="Лаба 10 · Документное хранилище"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Обе проверки останавливают скрипт с внятным сообщением, если не задан файл доступа
# к кластеру или номер тенанта. Без них дальше сыпались бы ошибки kubectl.
need_kubeconfig
need_tenant

# COZY_TENANT участник задаёт как `workshop07`, а namespace называется
# `tenant-workshop07`. Принимаем оба написания.
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# Имена по умолчанию — те же, что в лабе. Запись ${X:-значение} означает «взять
# переменную окружения, а если её нет, подставить значение»: назвали приложение
# иначе — запустите как MONGO_APP=имя ./check.sh, править скрипт не нужно.
# Адрес внутренний, из самого кластера; rs0 в имени — это набор реплик, в котором
# наша единственная копия и живёт.
MONGO_APP="${MONGO_APP:-passes}"
MONGO_USER="${MONGO_USER:-passapp}"
MONGO_DB="${MONGO_DB:-passes}"
MONGO_COLL="${MONGO_COLL:-passes}"
MONGO_HOST="mongodb-${MONGO_APP}-rs0.${NS}.svc.cozy.local:27017"

evidence "Адрес MongoDB" "$MONGO_HOST"

# --- 1. до порта вообще есть связь -----------------------------------------
# MongoDB на своём порту отвечает на HTTP-запрос понятной фразой про то, что
# сюда ходят драйвером, а не браузером. Этого достаточно, чтобы отделить
# «имя не разрешается / порт закрыт» от «связь есть, реквизиты не те».
PROBE="$(in_cluster_curl "http://${MONGO_HOST}/")"
if printf '%s' "$PROBE" | grep -qi 'mongodb'; then
  ok "MongoDB отвечает по внутреннему адресу тенанта"
else
  fail "до MongoDB нет связи по адресу ${MONGO_HOST}" \
       "проверьте номер тенанта в COZY_TENANT и имя приложения (по умолчанию 'passes'; иначе MONGO_APP=имя ./check.sh); в дашборде приложение должно быть в готовом состоянии"
  finish
  exit $?
fi

# Всё, что дальше, требует входа в базу. Без пароля скрипт не гадает и не молчит,
# а честно говорит, что содержимое базы не проверено, и заканчивает отчёт: иначе
# участник решил бы, что проверка пройдена.
if [ -z "${MONGO_PASSWORD:-}" ]; then
  fail "не задана переменная MONGO_PASSWORD, содержимое базы не проверено" \
       "export MONGO_PASSWORD='пароль пользователя ${MONGO_USER}' и запустите скрипт снова"
  finish
  exit $?
fi

# Пароль процентно кодируется: символы @ : / ? # % в нём иначе разваливают строку
# подключения, и человек получает невнятную ошибку разбора вместо «неверный пароль».
_pct() { printf %s "$1" | sed -e 's|%|%25|g' -e 's|@|%40|g' -e 's|:|%3A|g' \
                              -e 's|/|%2F|g' -e 's|?|%3F|g' -e 's|#|%23|g'; }
MONGO_URI="mongodb://${MONGO_USER}:$(_pct "$MONGO_PASSWORD")@${MONGO_HOST}/${MONGO_DB}?authSource=admin&directConnection=true"

# ⚠️ Строка подключения содержит пароль и передаётся аргументом пода. Это осознанный
# компромисс: см. `in_cluster_with_secrets` в check/lib.sh — безопасный путь есть, но
# он несовместим с многострочным --eval без переусложнения. Под живёт секунды и
# удаляется за собой; в отчёт пароль не попадает. В боевых скриптах так не делайте.
#
# Все проверки одним заходом: каждый вызов поднимает под, и десять подов подряд
# превратили бы проверку в многоминутное ожидание на ровном месте.
# Наружу отдаётся одна строка JSON, дальше её разбирает python.
# `--overrides` с securityContext: без него под не создастся в кластере с профилем
# `restricted`, и лаба провалится по причине, к участнику отношения не имеющей.
# `--command --` остаётся: kubectl объединяет его с override, где заданы только
# поля безопасности.
# Программа для mongosh. Двойные кавычки внутри неё безопасны: наружу текст уходит
# через python, который сам его закавычит, а имена базы и коллекции подставляются
# по меткам ниже.
MONGO_EVAL=$(cat <<'JSEOF'

var out = {};
try {
  var c = db.getSiblingDB("__DB__").getCollection("__COLL__");
  out.ok = 1;
  out.total = c.countDocuments({});
  out.types = c.distinct("type").length;
  out.withCar = c.countDocuments({ "car.plate": { $exists: true } });
  out.withArray = c.countDocuments({
    $or: [ { entrances: { $exists: true } }, { members: { $exists: true } } ]
  });
  out.nested = c.countDocuments({ "members.name": { $exists: true } });
  out.typeless = c.countDocuments({ type: { $exists: false } });
  var idx = c.getIndexes();
  out.indexes = idx.map(function (i) { return i.name; });
  out.sparse = idx.filter(function (i) {
    return i.sparse === true || i.partialFilterExpression !== undefined;
  }).map(function (i) { return i.name; });
  var info = db.getSiblingDB("__DB__").getCollectionInfos({ name: "__COLL__" });
  var opts = (info && info[0] && info[0].options) ? info[0].options : {};
  out.validator = opts.validator ? 1 : 0;
  out.validationAction = opts.validationAction || "";
} catch (e) {
  out.ok = 0;
  out.error = String(e.message || e);
}
print(JSON.stringify(out));
JSEOF
)
MONGO_EVAL="${MONGO_EVAL//__DB__/$MONGO_DB}"
MONGO_EVAL="${MONGO_EVAL//__COLL__/$MONGO_COLL}"

# Команда контейнера кладётся ВНУТРЬ override, а не остаётся снаружи в `--command --`.
# kubectl применяет override как JSON merge patch, а в нём массив containers заменяется
# целиком: заданный снаружи `--command` до пода не доедет, и вместо mongosh запустился бы
# штатный процесс образа — то есть сама база. Так же это сделано в check/lib.sh.
MONGO_SC="$(python3 - "$MONGO_URI" "$MONGO_EVAL" <<'PYEOF'
import json, sys
uri, script = sys.argv[1], sys.argv[2]
print(json.dumps({"spec": {
  "securityContext": {"runAsNonRoot": True, "runAsUser": 999,
                      "seccompProfile": {"type": "RuntimeDefault"}},
  "containers": [{"name": "mongo-check", "image": "mongo:8.0", "stdin": True,
                  "securityContext": {"allowPrivilegeEscalation": False,
                                      "capabilities": {"drop": ["ALL"]}},
                  "command": ["mongosh", "--quiet", uri, "--eval", script]}]}}))
PYEOF
)"

SUMMARY="$(kubectl run "mongo-check" --rm -i --restart=Never --quiet \
  --pod-running-timeout=90s --overrides="$MONGO_SC" \
  --image=mongo:8.0 </dev/null 2>/dev/null | tr -d '\r' | grep '^{' | tail -1)"

# Достать поле из строки JSON, которую напечатал mongosh. Списки склеиваются через
# запятую, чтобы их можно было показать участнику как есть.
mget() {
  printf '%s' "$SUMMARY" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
v = d.get(sys.argv[1])
if v is None:
    sys.exit(1)
print(v if not isinstance(v, list) else ", ".join(str(x) for x in v))
' "$1" 2>/dev/null
}

# То же, но для чисел: любое неожиданное значение превращается в 0, иначе сравнение
# ниже упало бы с ошибкой арифметики вместо понятного FAIL.
num() {
  local v
  v="$(mget "$1")"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

# Если ответа нет вовсе или mongosh сообщил об ошибке — дальше проверять нечего.
# Отказ в аутентификации отделён от прочих ошибок: у него своя частая причина —
# забытый authSource=admin, и подсказка должна вести именно к ней.
if [ -z "$SUMMARY" ] || [ "$(mget ok)" != "1" ]; then
  ERR="$(mget error)"
  case "$ERR" in
    *[Aa]uthentication*)
      fail "MongoDB не приняла реквизиты пользователя ${MONGO_USER}" \
           "проверьте пароль и то, что в строке подключения есть authSource=admin: пользователь заведён в базе admin, а права выданы в ${MONGO_DB}" ;;
    *)
      fail "не удалось выполнить запрос к базе ${MONGO_DB}${ERR:+: $ERR}" \
           "проверьте вручную: kubectl exec -it mongo-workbench -- sh -c 'mongosh \"\$MONGO_URI\"'" ;;
  esac
  finish
  exit $?
fi

ok "подключение к базе ${MONGO_DB} под пользователем ${MONGO_USER} работает"

# --- 2. документы есть ------------------------------------------------------
TOTAL="$(num total)"
if [ "$TOTAL" -ge 4 ]; then
  ok "в коллекции ${MONGO_COLL} документов: ${TOTAL}"
else
  fail "в коллекции ${MONGO_COLL} всего ${TOTAL} документов, ожидалось не меньше четырёх" \
       "загрузите пропуска: mo < passes.js (разбор файла — в README)"
fi

# --- 3. формы действительно разные -----------------------------------------
TYPES="$(num types)"
if [ "$TYPES" -ge 4 ]; then
  ok "в коллекции ${TYPES} разных типа пропуска"
else
  fail "разных типов пропуска всего ${TYPES}, ожидалось четыре" \
       "проверьте, что passes.js загрузился целиком: db.passes.distinct('type')"
fi

WITH_CAR="$(num withCar)"
if [ "$WITH_CAR" -ge 1 ]; then
  ok "есть документы с вложенным объектом (car.plate): ${WITH_CAR}"
else
  fail "нет ни одного документа с вложенным объектом car" \
       "автомобильный пропуск не загрузился; повторите mo < passes.js"
fi

WITH_ARRAY="$(num withArray)"
if [ "$WITH_ARRAY" -ge 2 ]; then
  ok "есть документы со списками (entrances и members): ${WITH_ARRAY}"
else
  fail "документов со списками ${WITH_ARRAY}, ожидалось не меньше двух" \
       "недельный и групповой пропуска не загрузились; повторите mo < passes.js"
fi

NESTED="$(num nested)"
if [ "$NESTED" -ge 1 ]; then
  ok "поиск внутрь списка объектов (members.name) находит документы"
else
  fail "поиск по members.name ничего не нашёл" \
       "групповой пропуск со списком участников не загрузился; повторите mo < passes.js"
fi

evidence "Состав коллекции" "документов: ${TOTAL}
разных типов пропуска: ${TYPES}
с вложенным объектом car: ${WITH_CAR}
со списками: ${WITH_ARRAY}"

# --- 4. индекс на редкое поле ----------------------------------------------
SPARSE="$(mget sparse)"
IDX="$(mget indexes)"
if [ -n "$SPARSE" ]; then
  ok "построен разреженный (или частичный) индекс: ${SPARSE}"
  evidence "Индексы коллекции" "все: ${IDX}
разреженные: ${SPARSE}"
else
  fail "разреженного индекса нет — поиск по номеру машины идёт перебором" \
       "создайте: db.${MONGO_COLL}.createIndex({ 'car.plate': 1 }, { name: 'car_plate', sparse: true })"
  evidence "Индексы коллекции" "все: ${IDX}"
fi

# --- 5. валидатор схемы включён --------------------------------------------
VALIDATOR="$(num validator)"
ACTION="$(mget validationAction)"
if [ "$VALIDATOR" = "1" ]; then
  ok "валидатор схемы включён (действие при нарушении: ${ACTION:-по умолчанию})"
  if [ "$ACTION" = "warn" ]; then
    warn "валидатор только предупреждает, но документы принимает" \
         "для боевой коллекции нужен validationAction: error"
  fi
else
  fail "валидатор схемы не включён — опечатка в имени поля пройдёт молча" \
       "включите: mo < validator.js (см. разбор предсказуемой неудачи в README)"
fi

# --- 6. испорченные документы убраны ---------------------------------------
TYPELESS="$(num typeless)"
if [ "$TYPELESS" -eq 0 ]; then
  ok "документов без поля type не осталось"
else
  fail "в коллекции ${TYPELESS} документов без поля type — охрана их не увидит" \
       "найдите и уберите: db.${MONGO_COLL}.deleteMany({ type: { \$exists: false } })"
fi

# finish печатает итог и складывает отчёт-артефакт в файл; код возврата — ненулевой,
# если хоть одна проверка провалилась.
finish
