#!/usr/bin/env bash
# Проверка лабы 10: в MongoDB лежат пропуска разной формы и по ним ищут.
#
# Проверяем не «сервис создан», а суть: в коллекции есть документы всех четырёх
# форм, поиск по вложенному полю и внутрь списка работает, на редкое поле
# построен разреженный индекс, валидатор схемы включён, а документов без типа
# не осталось.
#
# Пароль не печатается и в отчёт не попадает.
# Скрипт поднимает одноразовые поды, поэтому работает около минуты.

LAB_NAME="10-mongodb"
LAB_TITLE="Лаба 10 · Документное хранилище"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# COZY_TENANT участник задаёт как `workshop07`, а namespace называется
# `tenant-workshop07`. Принимаем оба написания.
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

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

if [ -z "${MONGO_PASSWORD:-}" ]; then
  fail "не задана переменная MONGO_PASSWORD, содержимое базы не проверено" \
       "export MONGO_PASSWORD='пароль пользователя ${MONGO_USER}' и запустите скрипт снова"
  finish
  exit $?
fi

MONGO_URI="mongodb://${MONGO_USER}:${MONGO_PASSWORD}@${MONGO_HOST}/${MONGO_DB}?authSource=admin&directConnection=true"

# Все проверки одним заходом: каждый вызов поднимает под, и десять подов подряд
# превратили бы проверку в многоминутное ожидание на ровном месте.
# Наружу отдаётся одна строка JSON, дальше её разбирает python.
SUMMARY="$(kubectl run "mongo-check-$$-$RANDOM" --rm -i --restart=Never --quiet \
  --image=mongo:8.0 --command -- \
  mongosh --quiet "$MONGO_URI" --eval '
var out = {};
try {
  var c = db.getSiblingDB("'"$MONGO_DB"'").getCollection("'"$MONGO_COLL"'");
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
  var info = db.getSiblingDB("'"$MONGO_DB"'").getCollectionInfos({ name: "'"$MONGO_COLL"'" });
  var opts = (info && info[0] && info[0].options) ? info[0].options : {};
  out.validator = opts.validator ? 1 : 0;
  out.validationAction = opts.validationAction || "";
} catch (e) {
  out.ok = 0;
  out.error = String(e.message || e);
}
print(JSON.stringify(out));
' </dev/null 2>/dev/null | tr -d '\r' | grep '^{' | tail -1)"

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

num() {
  local v
  v="$(mget "$1")"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

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
       "загрузите пропуска: mo < passes.js (см. шаг 3 в README)"
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

finish
