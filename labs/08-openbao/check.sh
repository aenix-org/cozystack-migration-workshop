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

# --- 1. хранилище отвечает -------------------------------------------------
SEAL="$(in_cluster_curl "$BAO_URL/v1/sys/seal-status")"

if [ -z "$SEAL" ]; then
  fail "OpenBao не отвечает по адресу ${BAO_URL}" \
       "проверьте номер тенанта в COZY_TENANT и имя приложения (по умолчанию 'secrets'; иначе BAO_APP=имя ./check.sh); в дашборде приложение должно быть в готовом состоянии"
else
  ok "OpenBao отвечает по внутреннему адресу тенанта"
fi

# --- 2. инициализирован ----------------------------------------------------
INITED="$(printf '%s' "$SEAL" | jget initialized)"
if [ "$INITED" = "True" ]; then
  ok "хранилище инициализировано"
elif [ -n "$SEAL" ]; then
  fail "хранилище не инициализировано" \
       "выполните: kubectl exec bao-workbench -- bao operator init -key-shares=1 -key-threshold=1 и сохраните вывод"
fi

# --- 3. распечатано --------------------------------------------------------
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
       "export BAO_TOKEN='root-токен из шага 5' и запустите скрипт снова"
else
  HDR="-HX-Vault-Token:${BAO_TOKEN}"

  DATA="$(in_cluster_curl "$BAO_URL/v1/secret/data/${SECRET_PATH}" "$HDR")"
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
  META="$(in_cluster_curl "$BAO_URL/v1/secret/metadata/${SECRET_PATH}" "$HDR")"
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
  POL="$(in_cluster_curl "$BAO_URL/v1/sys/policies/acl/passes-read" "$HDR")"
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
         "создайте её: kubectl exec -i bao-workbench -- bao policy write passes-read - < ваш файл политики (см. шаг 7)"
  fi

  # --- 7. аудит включён ----------------------------------------------------
  AUD="$(in_cluster_curl "$BAO_URL/v1/sys/audit" "$HDR")"
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
if kubectl get secret passes-db >/dev/null 2>&1; then
  warn "в кластере остался секрет passes-db из шага 2" \
       "он больше не нужен и содержит старый пароль: kubectl delete secret passes-db"
else
  ok "наивный секрет passes-db удалён"
fi

finish
