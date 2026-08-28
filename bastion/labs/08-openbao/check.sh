#!/usr/bin/env bash
# Проверка лабы 8: пароль вынесен из манифеста в OpenBao и живёт по правилам.
#
# Проверяем не «объект создан», а суть: хранилище распечатано, секрет читается
# по токену, версий больше одной (значит, ротация действительно была), аудит
# включён, а в применённом манифесте приложения нет паролей открытым текстом.
#
# Ни один секрет в отчёт не попадает. Значения не печатаются нигде.
#
# Скрипт поднимает одноразовые поды с curl, поэтому работает около минуты.

# LAB_NAME и LAB_TITLE идут в шапку отчёта. Ниже подключается общая библиотека
# проверок: из неё берутся ok / warn / fail / evidence / finish и функции, которые
# запускают одноразовые поды внутри кластера. need_kubeconfig и need_tenant
# останавливают скрипт заранее, если доступ или номер тенанта не заданы: иначе
# провалится всё сразу и по отчёту нельзя будет понять причину.
LAB_NAME="08-openbao"
LAB_TITLE="Лаба 8 · Секреты не в манифесте"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

# --- куда смотреть ---------------------------------------------------------
# COZY_TENANT участник задаёт как `workshop07`, но namespace называется
# `tenant-workshop07`. Принимаем оба написания: ошибиться здесь легко, а
# сообщение об ошибке было бы невнятным («сервис не отвечает»).
NS="$COZY_TENANT"
case "$NS" in
  tenant-*) ;;
  *) NS="tenant-$NS" ;;
esac

# Что и где ищем. BAO_APP — имя приложения OpenBao в тенанте, и оно входит во
# внутренний адрес хранилища: назвали приложение иначе — запускайте проверку
# как BAO_APP=имя ./check.sh. SECRET_PATH — путь внутри хранилища, по которому
# лаба кладёт пароль от базы.
BAO_APP="${BAO_APP:-secrets}"
BAO_URL="http://openbao-${BAO_APP}.${NS}.svc.cozy.local:8200"
APP_DEPLOY="${APP_DEPLOY:-secrets-demo}"
SECRET_PATH="${SECRET_PATH:-passes/db}"

evidence "Адрес хранилища" "$BAO_URL"

# Достать значение по цепочке ключей из JSON на стандартном вводе.
# Возврат 1, если пути нет или это не JSON, — так вызывающий отличает
# «ключа нет» от «пустое значение».
jget() {
  python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for k in sys.argv[1:]:
    try:
        d = d[int(k)] if isinstance(d, list) else d[k]
    except Exception:
        sys.exit(1)
print("" if d is None else d)
' "$@" 2>/dev/null
}


# Запрос к OpenBao. Токен передаём переменной окружения из временного Secret'а,
# а НЕ заголовком в аргументах: аргументы пода видит любой с `get pods`, они лежат
# в etcd и уходят в audit log. Здесь это root-токен хранилища — ровно та утечка,
# против которой написана вся лаба.
#
# Определение стоит ДО первого вызова: когда оно лежало внутри ветки else, самая
# первая проверка вызывала несуществующую функцию и лаба не сдавалась никогда.
bao_get() {
  in_cluster_with_secrets "curlimages/curl:8.11.1" \
    "BAO_TOKEN=${BAO_TOKEN:-}
BAO_URL=${BAO_URL}
BAO_PATH=$1" \
    sh -c 'curl -s --max-time 15 -H "X-Vault-Token: $BAO_TOKEN" "$BAO_URL$BAO_PATH"'
}

# --- 1. хранилище отвечает -------------------------------------------------
# Первый же запрос отвечает сразу на два вопроса: поднялось ли приложение и верно ли
# указан номер тенанта. Спрашиваем состояние печати — это единственный адрес, который
# OpenBao отдаёт без токена. Пустой ответ дальше означает «связи нет», и все проверки
# содержимого теряют смысл.
SEAL="$(bao_get "/v1/sys/seal-status")"

if [ -z "$SEAL" ]; then
  fail "OpenBao не отвечает по адресу ${BAO_URL}" \
       "проверьте номер тенанта в COZY_TENANT и имя приложения (по умолчанию 'secrets'; иначе BAO_APP=имя ./check.sh); в дашборде приложение должно быть в готовом состоянии"
else
  ok "OpenBao отвечает по внутреннему адресу тенанта"
fi

# --- 2. инициализирован ----------------------------------------------------
# Инициализация — разовая операция, при которой хранилище создаёт себе мастер-ключ
# и первый токен. Пока её не сделали, внутри нет ничего: ни секретов, ни места под них.
INITED="$(printf '%s' "$SEAL" | jget initialized)"
if [ "$INITED" = "True" ]; then
  ok "хранилище инициализировано"
elif [ -n "$SEAL" ]; then
  fail "хранилище не инициализировано" \
       "выполните: kubectl exec bao-workbench -- bao operator init -key-shares=1 -key-threshold=1 и сохраните вывод"
fi

# --- 3. распечатано --------------------------------------------------------
# Запечатанное хранилище — обычное состояние после перезапуска пода: данные на диске
# лежат, но прочитать их нечем, пока не введён unseal-ключ. Отсюда и требование
# проверять поведение, а не наличие объекта: «приложение готово» и «секреты отдаются» —
# это два разных утверждения, и второе из первого не следует.
SEALED="$(printf '%s' "$SEAL" | jget sealed)"
if [ "$SEALED" = "False" ]; then
  ok "хранилище распечатано и обслуживает запросы"
  evidence "Состояние хранилища" "$SEAL"
elif [ -n "$SEAL" ]; then
  fail "хранилище запечатано — на любой запрос оно отвечает отказом 503" \
       "выполните: kubectl exec bao-workbench -- bao operator unseal <ваш-unseal-ключ>"
  evidence "Состояние хранилища" "$SEAL"
fi

# --- 4. секрет на месте и читается -----------------------------------------
# Дальше нужен токен. Без него проверять нечего, но и молча пропускать нельзя:
# читатель должен увидеть, чего не хватает.
if [ -z "$SEAL" ]; then
  # Связи нет — проверять содержимое бессмысленно. Молчим, чтобы не завалить
  # отчёт четырьмя провалами, у которых одна и та же причина, названная выше.
  warn "содержимое хранилища не проверено: до OpenBao нет связи" \
       "разберитесь со связью, потом запустите скрипт снова"
elif [ -z "${BAO_TOKEN:-}" ]; then
  fail "не задана переменная BAO_TOKEN, поэтому содержимое хранилища не проверено" \
       "export BAO_TOKEN='root-токен, напечатанный при первой распечатке хранилища' и запустите скрипт снова"
else

  DATA="$(bao_get "/v1/secret/data/${SECRET_PATH}")"
  PASS_PRESENT="$(printf '%s' "$DATA" | jget data data password)"
  DATA_VERSION="$(printf '%s' "$DATA" | jget data metadata version)"

  if [ -n "$PASS_PRESENT" ]; then
    ok "секрет secret/${SECRET_PATH} читается по токену, поле password не пустое"
    # В отчёт кладём номер версии, а не значение.
    evidence "Секрет" "путь: secret/${SECRET_PATH}
поле password: есть (значение скрыто)
текущая версия: ${DATA_VERSION:-неизвестна}"
  else
    fail "по пути secret/${SECRET_PATH} нет поля password" \
         "положите его: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=... ; если движок ещё не включён — bao secrets enable -path=secret kv-v2"
  fi

  # --- 5. ротация действительно была --------------------------------------
  # Одна-единственная версия секрета означает, что его положили и забыли. Ротация —
  # то, ради чего хранилище и заводят: сменить пароль в одном месте, а не искать его
  # по манифестам. Считаем не обещания, а версии: их счёт хранилище ведёт само.
  META="$(bao_get "/v1/secret/metadata/${SECRET_PATH}")"
  CUR_VER="$(printf '%s' "$META" | jget data current_version)"
  case "$CUR_VER" in
    ''|*[!0-9]*) CUR_VER=0 ;;
  esac
  if [ "$CUR_VER" -ge 2 ]; then
    ok "секрет менялся: версий ${CUR_VER}, значит ротация проходила не только на словах"
    evidence "История версий секрета" "$(printf '%s' "$META" | jget data versions)"
  else
    fail "у секрета всего одна версия — ротацию не делали" \
         "поменяйте пароль: kubectl exec bao-workbench -- bao kv put secret/${SECRET_PATH} password=<новый> и перезапустите приложение"
  fi

  # --- 6. политика узкая, а не «всё можно» ---------------------------------
  # Политика и есть ответ на вопрос «что сможет сделать тот, кто добыл токен». Поэтому
  # смотрим не на факт её существования, а на содержимое: выдана ли она на конкретный
  # путь вместо всего хранилища и только ли на чтение.
  POL="$(bao_get "/v1/sys/policies/acl/passes-read")"
  POL_BODY="$(printf '%s' "$POL" | jget data policy)"
  if [ -n "$POL_BODY" ]; then
    ok "политика passes-read существует"
    evidence "Политика passes-read" "$POL_BODY"
    if printf '%s' "$POL_BODY" | grep -q 'secret/data/'"${SECRET_PATH}"; then
      ok "политика выдана на конкретный путь, а не на всё хранилище"
    else
      warn "политика есть, но пути secret/data/${SECRET_PATH} в ней не видно" \
           "проверьте, что в политике указана приставка data: secret/data/${SECRET_PATH}"
    fi
    if printf '%s' "$POL_BODY" | grep -Eq '"(create|update|delete|sudo)"'; then
      warn "политика разрешает не только чтение" \
           "приложению достаточно read; лишние права стоит убрать"
    fi
  else
    fail "политика passes-read не найдена" \
         "создайте её: kubectl exec -i bao-workbench -- bao policy write passes-read - < ваш файл политики (разбор политики — в README)"
  fi

  # --- 7. аудит включён ----------------------------------------------------
  # Без журнала аудита на вопрос «кто и когда читал этот секрет» ответить нечем — а это
  # первый вопрос, который задают после инцидента. Считаем подключённые устройства
  # журналирования: хотя бы одно должно быть.
  AUD="$(bao_get "/v1/sys/audit")"
  AUD_COUNT="$(printf '%s' "$AUD" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
data = d.get("data", d)
print(len([k for k in data if isinstance(data.get(k), dict)]))
' 2>/dev/null)"
  case "$AUD_COUNT" in
    ''|*[!0-9]*) AUD_COUNT=0 ;;
  esac
  if [ "$AUD_COUNT" -ge 1 ]; then
    ok "аудит-журнал включён (устройств: ${AUD_COUNT})"
    evidence "Аудит-устройства" "$AUD"
  else
    fail "аудит-журнал не включён — ответить, кто читал секрет, будет нечем" \
         "включите: kubectl exec bao-workbench -- bao audit enable file file_path=stdout"
  fi
fi

# --- 8. приложение в лабораторном кластере ---------------------------------
# До сих пор мы проверяли хранилище на управляющем кластере. Дальше — ваш кластер lab,
# где живёт само приложение. Важен здесь не факт, что Deployment создан, а наличие
# готовых копий: init-контейнер, не сумевший забрать пароль, не даст поду подняться,
# и именно это состояние надо отличить от «всё хорошо».
if ! kubectl get deploy "$APP_DEPLOY" >/dev/null 2>&1; then
  fail "в лабораторном кластере нет приложения ${APP_DEPLOY}" \
       "примените: kubectl apply -f secrets-demo.yaml (не забыв подставить свой номер тенанта)"
else
  READY="$(kubectl get deploy "$APP_DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  case "$READY" in
    ''|*[!0-9]*) READY=0 ;;
  esac
  if [ "$READY" -ge 1 ]; then
    ok "приложение ${APP_DEPLOY} запущено (готовых копий: ${READY})"
  else
    fail "приложение ${APP_DEPLOY} есть, но ни одна копия не готова" \
         "смотрите kubectl describe deploy/${APP_DEPLOY} и kubectl logs deploy/${APP_DEPLOY} -c fetch-secret — обычно init-контейнер не смог достучаться до хранилища или получил отказ по токену"
  fi

  # --- 9. в манифесте нет паролей открытым текстом -------------------------
  # Смотрим применённый объект, а не файл на диске: применить могли что угодно.
  LEAKS="$(kubectl get deploy "$APP_DEPLOY" -o json 2>/dev/null | python3 -c '
import sys, json, re
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
suspicious = re.compile(r"(?i)pass|secret|token|key|cred")
spec = d.get("spec", {}).get("template", {}).get("spec", {})
found = []
for c in list(spec.get("initContainers", [])) + list(spec.get("containers", [])):
    for e in c.get("env", []):
        if "value" in e and suspicious.search(e.get("name", "")):
            found.append("%s / env %s задан значением, а не ссылкой" % (c.get("name"), e.get("name")))
print("\n".join(found))
' 2>/dev/null)"

  if [ -z "$LEAKS" ]; then
    ok "в манифесте приложения нет переменных с паролем, заданным значением"
  else
    fail "в манифесте приложения остались чувствительные значения открытым текстом" \
         "уберите их: значение должно приходить из хранилища, а в манифесте — только ссылка. См. secrets-demo.yaml"
    evidence "Что найдено в манифесте" "$LEAKS"
  fi

  # --- 10. приложение действительно получило секрет ------------------------
  # Последнее доказательство берём из логов, а не из описания объекта. Манифест может
  # быть безупречным, а пароль в под так и не приехать. Смотрим на две вещи сразу:
  # init-контейнер сообщил, что сходил в хранилище, и приложение печатает отпечаток —
  # значит, с полученным паролем оно действительно работает.
  INIT_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c fetch-secret --tail=5 2>/dev/null)"
  if printf '%s' "$INIT_LOG" | grep -qi 'openbao'; then
    ok "init-контейнер забрал секрет из хранилища"
    evidence "Лог init-контейнера" "$INIT_LOG"
  else
    fail "не видно, чтобы init-контейнер забирал секрет из хранилища" \
         "проверьте kubectl logs deploy/${APP_DEPLOY} -c fetch-secret; если контейнера нет — применён старый манифест"
  fi

  APP_LOG="$(kubectl logs "deploy/${APP_DEPLOY}" -c app --tail=3 2>/dev/null)"
  if printf '%s' "$APP_LOG" | grep -q 'sha256:'; then
    ok "приложение работает с полученным паролем (в лог пишется отпечаток, а не значение)"
    evidence "Лог приложения" "$APP_LOG"
  else
    fail "в логе приложения нет отпечатка пароля" \
         "проверьте kubectl logs deploy/${APP_DEPLOY} -c app — контейнер мог не стартовать"
  fi
fi

# --- 11. наивный секрет убран ----------------------------------------------
# Засчитываем «удалён» только если лабу вообще делали: на чистом кластере секрета
# не было никогда, и отчёт хвалил участника за уборку, которой не происходило.
if kubectl get secret passes-db >/dev/null 2>&1; then
  warn "в кластере остался секрет passes-db с наивной ступени" \
       "он больше не нужен и содержит старый пароль: kubectl delete secret passes-db"
elif kubectl get deployment secrets-demo >/dev/null 2>&1; then
  ok "наивный секрет passes-db удалён"
fi

finish
