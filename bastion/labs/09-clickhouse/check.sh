#!/usr/bin/env bash
# Проверка лабы 9: в ClickHouse лежит журнал проходов и по нему считается отчёт.
#
# Проверяем не «сервис создан», а суть: таблица есть, строк не меньше миллиона,
# данные разнообразные и с выраженными пиками, отчёт по месяцам отрабатывает за
# миллисекунды, а запрос по одной колонке читает малую долю таблицы — то есть
# колоночность работает, а не заявлена.
#
# Запуск (в каждом новом окне терминала переменные задаются заново):
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshopXX       # свой номер вместо XX
#   export CH_PASSWORD='пароль пользователя analyst'
#   cd labs/09-clickhouse && ./check.sh
#
# Пароль не печатается и в отчёт не попадает.
# Скрипт поднимает одноразовые поды с curl, поэтому работает около минуты.

# Имя и заголовок нужны общей библиотеке: она подписывает ими отчёт-артефакт.
# В lib.sh лежат ok/fail/warn/evidence/finish и проверки окружения ниже — чтобы
# пятнадцать скриптов проверки печатали одинаково, а не каждый по-своему.
LAB_NAME="09-clickhouse"
LAB_TITLE="Лаба 9 · Аналитика на миллионе строк"
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
# иначе — запустите как CH_APP=имя ./check.sh, править скрипт не нужно.
# Адрес внутренний, из самого кластера: 8123 — порт HTTP-интерфейса ClickHouse.
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

# Всё, что дальше, требует входа в базу. Без пароля скрипт не гадает и не молчит,
# а честно говорит, что содержимое базы не проверено, и заканчивает отчёт: иначе
# участник решил бы, что проверка пройдена.
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
         "создайте её: ch < 01-schema.sql (разбор схемы — в README)"
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
    (SELECT sum(data_uncompressed_bytes) FROM system.columns
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
       "запустите генератор: ch < 02-generate.sql (разбор генератора — в README)"
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
  # Порог держим близко к тому, что обещает лаба. Прежние пять секунд засчитывали
  # как успех отчёт за четыре секунды — при том что в шапке лабы написано
  # «считается за миллисекунды». Скрипт не должен подтверждать то, чего не проверил.
  FAST="$(python3 -c "print(1 if float('$ELAPSED') < 0.5 else 0)" 2>/dev/null)"
  SLOW="$(python3 -c "print(1 if float('$ELAPSED') > 3 else 0)" 2>/dev/null)"
  if [ "$FAST" = "1" ]; then
    ok "отчёт по месяцам посчитан за ${MS} мс, прочитано строк: ${READ_ROWS}"
  elif [ "$SLOW" = "1" ]; then
    fail "отчёт по месяцам считался ${MS} мс — это не тот порядок, о котором лаба" \
         "миллион строк на свободном стенде укладывается в десятки миллисекунд; проверьте, что сервис не занят соседней нагрузкой, и повторите"
  else
    warn "отчёт по месяцам посчитан за ${MS} мс — медленнее ожидаемого, но в пределах разумного" \
         "на занятом стенде так бывает; на свободном такой отчёт укладывается в десятки миллисекунд"
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

# Обе величины НЕСЖАТЫЕ: `bytes_read` в статистике запроса — это распакованный
# объём, а из system.columns берётся `data_uncompressed_bytes`. Сравнение с
# `data_compressed_bytes` давало долю от размера на диске и печатало участнику
# неверное число — на хорошо сжатой таблице она могла перевалить за сто процентов.
if [ "$NARROW_BYTES" -gt 0 ] && [ "$TABLE_BYTES" -gt 0 ]; then
  SHARE="$(python3 -c "print(round(100 * $NARROW_BYTES / $TABLE_BYTES))" 2>/dev/null)"
  evidence "Чтение одной колонки" "прочитано байт: ${NARROW_BYTES}
вся таблица без сжатия, байт: ${TABLE_BYTES}
доля: ${SHARE}%"
  # Порог, а не просто «меньше целого». Одна узкая колонка из семи должна дать единицы
  # процентов; «99% вместо 100%» формально меньше, но ничего не доказывает — а именно
  # это утверждение лаба и выносит в заголовок.
  if [ "$SHARE" -le 25 ]; then
    ok "запрос по одной колонке прочитал ${SHARE}% данных таблицы — колоночное хранение работает"
  elif [ "$NARROW_BYTES" -lt "$TABLE_BYTES" ]; then
    warn "запрос по одной колонке прочитал ${SHARE}% данных таблицы — меньше целого, но выигрыш скромнее ожидаемого" \
         "ожидались единицы процентов; проверьте, что запрос обращается к одной узкой колонке, а не к нескольким"
  else
    warn "запрос по одной колонке прочитал не меньше всей таблицы" \
         "так бывает на очень маленьких таблицах; проверьте, что строк действительно миллион"
  fi
else
  warn "не удалось измерить, сколько прочитал узкий запрос" \
       "выполните вручную: SELECT count() FROM ${CH_TABLE} WHERE duration_min > 100 FORMAT JSON и посмотрите bytes_read"
fi

# finish печатает итог и складывает отчёт-артефакт в файл; код возврата — ненулевой,
# если хоть одна проверка провалилась.
finish
