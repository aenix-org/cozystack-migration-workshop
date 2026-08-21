#!/usr/bin/env bash
# Проверка лабы 9: в ClickHouse лежит журнал проходов и по нему считается отчёт.
#
# Проверяем не «сервис создан», а суть: таблица есть, строк не меньше миллиона,
# данные разнообразные и с выраженными пиками, отчёт по месяцам отрабатывает за
# миллисекунды, а запрос по одной колонке читает малую долю таблицы — то есть
# колоночность работает, а не заявлена.
#
# Пароль не печатается и в отчёт не попадает.
# Скрипт поднимает одноразовые поды с curl, поэтому работает около минуты.

LAB_NAME="09-clickhouse"
LAB_TITLE="Лаба 9 · Аналитика на миллионе строк"
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

CH_APP="${CH_APP:-analytics}"
CH_USER="${CH_USER:-analyst}"
CH_TABLE="${CH_TABLE:-passes}"
CH_HOST="chendpoint-clickhouse-${CH_APP}.${NS}.svc.cozy.local:8123"
CH_URL="http://${CH_HOST}/"

evidence "Адрес ClickHouse" "$CH_URL"

# --- 1. сервис вообще отвечает ---------------------------------------------
# /ping не требует пароля, поэтому это первая и самая дешёвая проверка:
# отделяет «нет связи» от «связь есть, пароль не тот».
PING="$(in_cluster_curl "${CH_URL}ping")"
if printf '%s' "$PING" | grep -qi 'ok'; then
  ok "ClickHouse отвечает по внутреннему адресу тенанта"
else
  fail "ClickHouse не отвечает по адресу ${CH_HOST}" \
       "проверьте номер тенанта в COZY_TENANT и имя приложения (по умолчанию 'analytics'; иначе CH_APP=имя ./check.sh); в дашборде приложение должно быть в готовом состоянии"
  finish
  exit $?
fi

if [ -z "${CH_PASSWORD:-}" ]; then
  fail "не задана переменная CH_PASSWORD, содержимое базы не проверено" \
       "export CH_PASSWORD='пароль пользователя ${CH_USER}' и запустите скрипт снова; пароль виден в дашборде, секрет clickhouse-${CH_APP}-credentials"
  finish
  exit $?
fi

# Выполнить SQL со стандартного ввода и вернуть ответ.
# Отдельная функция, а не in_cluster_curl: запрос уходит телом POST, а телу
# нужен стандартный ввод, которого у общей функции нет.
# Пароль уходит в под переменной окружения из временного Secret'а, а не аргументом:
# всё, что попадает в args, видно любому с `get pods`, лежит в etcd и светится в audit
# log. Сама лаба про это и говорит — проверять её скриптом, который делает наоборот,
# было бы двойным стандартом.
ch_query() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "CH_USER=${CH_USER}
CH_PASSWORD=${CH_PASSWORD}
CH_URL=${CH_URL}" \
    sh -c 'curl -sS --max-time 90 -u "$CH_USER:$CH_PASSWORD" --data-binary @- "$CH_URL?default_format=TSV"'
}

# Достать число из блока statistics ответа в формате JSON.
chstat() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
key = sys.argv[1]
src = d.get("statistics", {}) if key in ("elapsed",) else d
val = src.get(key, d.get("statistics", {}).get(key))
if val is None:
    sys.exit(1)
print(val)
' "$1" 2>/dev/null
}

# --- 2. таблица существует --------------------------------------------------
EXISTS="$(printf 'EXISTS TABLE %s' "$CH_TABLE" | ch_query | tr -d '[:space:]')"
if [ "$EXISTS" = "1" ]; then
  ok "таблица ${CH_TABLE} существует"
else
  if printf '%s' "$EXISTS" | grep -qi 'auth'; then
    fail "ClickHouse не принял пароль пользователя ${CH_USER}" \
         "сверьте пароль в дашборде: приложение ${CH_APP} → Secrets → clickhouse-${CH_APP}-credentials"
  else
    fail "таблицы ${CH_TABLE} нет" \
         "создайте её: ch < 01-schema.sql (см. шаг 3 в README)"
  fi
  finish
  exit $?
fi

# --- 3. сколько данных и насколько они разнообразны -------------------------
# Одним запросом вместо шести: каждый вызов ch_query поднимает под, и шесть
# подов подряд превратили бы проверку в минутное ожидание на ровном месте.
STATS="$(ch_query <<SQL
SELECT
    (SELECT count() FROM ${CH_TABLE}),
    (SELECT uniqExact(entrance) FROM ${CH_TABLE}),
    (SELECT uniqExact(pass_type) FROM ${CH_TABLE}),
    (SELECT uniqExact(toStartOfMonth(created_at)) FROM ${CH_TABLE}),
    (SELECT max(c) FROM (SELECT toHour(created_at) AS h, count() AS c FROM ${CH_TABLE} GROUP BY h)),
    (SELECT min(c) FROM (SELECT toHour(created_at) AS h, count() AS c FROM ${CH_TABLE} GROUP BY h)),
    (SELECT sum(data_compressed_bytes) FROM system.columns
      WHERE database = currentDatabase() AND table = '${CH_TABLE}')
SQL
)"

ROWS="$(printf '%s' "$STATS" | awk 'NR==1{print $1}')"
UNIQ_ENT="$(printf '%s' "$STATS" | awk 'NR==1{print $2}')"
UNIQ_TYPE="$(printf '%s' "$STATS" | awk 'NR==1{print $3}')"
UNIQ_MONTH="$(printf '%s' "$STATS" | awk 'NR==1{print $4}')"
PEAK_MAX="$(printf '%s' "$STATS" | awk 'NR==1{print $5}')"
PEAK_MIN="$(printf '%s' "$STATS" | awk 'NR==1{print $6}')"
TABLE_BYTES="$(printf '%s' "$STATS" | awk 'NR==1{print $7}')"

for v in ROWS UNIQ_ENT UNIQ_TYPE UNIQ_MONTH PEAK_MAX PEAK_MIN TABLE_BYTES; do
  eval "val=\$$v"
  case "$val" in
    ''|*[!0-9]*) eval "$v=0" ;;
  esac
done

if [ "$ROWS" -ge 1000000 ]; then
  ok "в таблице ${ROWS} строк — миллион сгенерирован"
else
  fail "в таблице ${ROWS} строк, ожидался миллион" \
       "запустите генератор: ch < 02-generate.sql (см. шаг 4 в README)"
fi

if [ "$UNIQ_ENT" -ge 2 ] && [ "$UNIQ_TYPE" -ge 3 ] && [ "$UNIQ_MONTH" -ge 3 ]; then
  ok "данные разнообразные: входов ${UNIQ_ENT}, типов пропуска ${UNIQ_TYPE}, месяцев ${UNIQ_MONTH}"
else
  fail "данные однообразные: входов ${UNIQ_ENT}, типов ${UNIQ_TYPE}, месяцев ${UNIQ_MONTH}" \
       "на таких данных отчёт ничего не покажет; перегенерируйте: TRUNCATE TABLE ${CH_TABLE}, затем ch < 02-generate.sql"
fi

if [ "$PEAK_MIN" -gt 0 ] && [ "$PEAK_MAX" -ge $((PEAK_MIN * 2)) ]; then
  ok "в данных есть выраженные пики по часам (самый нагруженный час к самому тихому — не меньше чем вдвое)"
  evidence "Распределение по часам" "максимум за час: ${PEAK_MAX}
минимум за час: ${PEAK_MIN}"
else
  warn "пиков по часам не видно: максимум ${PEAK_MAX}, минимум ${PEAK_MIN}" \
       "отчёт «когда пики» на таких данных бессмысленный; проверьте, что генератор отработал целиком"
fi

# --- 4. отчёт по месяцам считается быстро -----------------------------------
REPORT="$(ch_query <<SQL
SELECT toStartOfMonth(created_at) AS month, count() AS guests
FROM ${CH_TABLE}
GROUP BY month
ORDER BY month
FORMAT JSON
SQL
)"

ELAPSED="$(printf '%s' "$REPORT" | chstat elapsed)"
READ_ROWS="$(printf '%s' "$REPORT" | chstat rows_read)"

if [ -z "$ELAPSED" ]; then
  fail "отчёт по месяцам не отработал" \
       "запустите его вручную: ch < 03-report.sql и посмотрите на текст ошибки"
else
  MS="$(python3 -c "print(round(float('$ELAPSED') * 1000, 1))" 2>/dev/null)"
  FAST="$(python3 -c "print(1 if float('$ELAPSED') < 5 else 0)" 2>/dev/null)"
  if [ "$FAST" = "1" ]; then
    ok "отчёт по месяцам посчитан за ${MS} мс, прочитано строк: ${READ_ROWS}"
  else
    warn "отчёт по месяцам посчитан за ${MS} мс — это медленнее ожидаемого" \
         "проверьте, не занят ли сервис чем-то ещё; на пустом стенде такой отчёт укладывается в десятки миллисекунд"
  fi
  evidence "Отчёт по месяцам" "время: ${MS} мс
прочитано строк: ${READ_ROWS}"
fi

# --- 5. колоночность работает, а не заявлена --------------------------------
# Запрос трогает одну маленькую колонку. Если хранилище колоночное, прочитано
# будет заметно меньше, чем весит вся таблица.
NARROW="$(ch_query <<SQL
SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON
SQL
)"
NARROW_BYTES="$(printf '%s' "$NARROW" | chstat bytes_read)"
case "$NARROW_BYTES" in
  ''|*[!0-9]*) NARROW_BYTES=0 ;;
esac

if [ "$NARROW_BYTES" -gt 0 ] && [ "$TABLE_BYTES" -gt 0 ]; then
  SHARE="$(python3 -c "print(round(100 * $NARROW_BYTES / $TABLE_BYTES))" 2>/dev/null)"
  evidence "Чтение одной колонки" "прочитано байт: ${NARROW_BYTES}
вся таблица на диске, байт: ${TABLE_BYTES}
доля: ${SHARE}%"
  if [ "$NARROW_BYTES" -lt "$TABLE_BYTES" ]; then
    ok "запрос по одной колонке прочитал ${SHARE}% от размера таблицы — колоночное хранение работает"
  else
    warn "запрос по одной колонке прочитал не меньше всей таблицы" \
         "так бывает на очень маленьких таблицах; проверьте, что строк действительно миллион"
  fi
else
  warn "не удалось измерить, сколько прочитал узкий запрос" \
       "выполните вручную: SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON и посмотрите bytes_read"
fi

finish
