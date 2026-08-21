#!/usr/bin/env bash
# Проверка лабы 7: кеш реально ускоряет, и это видно в цифрах.
#
# Главная проверка здесь поведенческая, а не структурная. Скрипт сам берёт неиспользованный
# идентификатор, запрашивает его дважды и смотрит: первый раз должен быть промах на сотни
# миллисекунд, второй — попадание на единицы. Манифест с правильными переменными окружения
# такую проверку не пройдёт, если кеш на самом деле не отвечает.
#
# Два кластера: KUBECONFIG — ваш кластер lab, COZY_KUBECONFIG — управляющий кластер
# Cozystack, где живёт managed-сервис Redis.

LAB_NAME="07-redis"
LAB_TITLE="Лаба 7 · Кеш перед медленным бэкендом"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

APP="passes-api"
HR="hr-legacy"
SVC="http://${APP}.default.svc.cluster.local"
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/tenant.kubeconfig}"

kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# Достать поле из JSON. Без jq: его нет на голой macOS, а python3 есть везде,
# где работает остальная библиотека проверок.
jfield() {
  python3 -c 'import sys,json
try:
    print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))
except Exception:
    pass' "$1" 2>/dev/null
}

# --- managed-сервис Redis на управляющем кластере ----------------------------
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "не найден тенантный кубконфиг ${COZY_KUBECONFIG} — состояние Redis не проверялось" \
       "укажите путь: export COZY_KUBECONFIG=~/tenant.kubeconfig"
else
  REDIS_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get redises.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  REDIS_LIST="$(cozy get redises.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$REDIS_ERR" ]; then
    warn "не удалось посмотреть приложения Redis в тенанте ${TENANT_NS}" \
         "роль в тенанте может не давать эту команду — это не ошибка лабы; работу кеша проверяем ниже напрямую"
  elif [ -z "$REDIS_LIST" ]; then
    fail "в тенанте ${TENANT_NS} нет ни одного приложения Redis" \
         "создайте его в дашборде: Создать приложение -> Redis"
  else
    R_NAME="$(printf '%s' "$REDIS_LIST" | awk 'NR==1{print $1}')"
    R_READY="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    R_REPLICAS="$(cozy get redises.apps.cozystack.io "$R_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.spec.replicas}')"
    if [ "$R_READY" = "True" ]; then
      ok "managed Redis «${R_NAME}» готов, копий данных: ${R_REPLICAS:-по умолчанию}"
    else
      warn "Redis «${R_NAME}» есть, но не сообщает о готовности" \
           "смотрите его состояние в дашборде; поднимается три-пять минут"
    fi
    evidence "Redis в тенанте" "$REDIS_LIST"
  fi
fi

# --- медленный справочник на месте и действительно медленный -----------------
# Без этой проверки сравнение «до и после» ничего не значит: если справочник
# отвечает мгновенно, ускорять нечего и кеш нечем измерить.
HR_RUNNING="$(kget pods -l app=hr-legacy --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$HR_RUNNING" -lt 1 ]; then
  fail "справочник ${HR} не работает" \
       "примените hr-legacy.yaml и посмотрите kubectl describe pod -l app=hr-legacy"
else
  HR_SEC="$(in_cluster_curl "http://${HR}.default.svc.cluster.local/employee?id=1" \
    "-o /dev/null -w %{time_total}")"
  HR_MS="$(python3 -c 'import sys
try: print(int(float(sys.argv[1])*1000))
except Exception: print(-1)' "${HR_SEC:-0}" 2>/dev/null)"
  if [ "${HR_MS:-0}" -ge 300 ] 2>/dev/null; then
    ok "справочник отвечает за ${HR_MS} мс — есть что ускорять"
    evidence "Задержка справочника" "${HR_MS} мс на запрос /employee"
  elif [ "${HR_MS:-0}" -lt 0 ] 2>/dev/null; then
    fail "справочник ${HR} не ответил на запрос" \
         "смотрите kubectl logs -l app=hr-legacy"
  else
    warn "справочник отвечает за ${HR_MS} мс, это слишком быстро для замера" \
         "проверьте, что в hr-legacy.yaml задано MODE=hr и HR_DELAY=800ms"
  fi
fi

# --- приложение настроено на кеш ---------------------------------------------
# Разбираем окружение контейнера питоном, а не jsonpath: фильтры jsonpath по
# вложенным спискам ведут себя по-разному в разных версиях kubectl, а нам важно,
# чтобы проверка одинаково работала у всех.
DEPLOY_JSON="$(kget deployment "$APP" -o json)"
readenv() {
  printf '%s' "$DEPLOY_JSON" | python3 -c 'import sys,json
try:
    d = json.loads(sys.stdin.read())
    env = d["spec"]["template"]["spec"]["containers"][0].get("env", [])
except Exception:
    raise SystemExit
want = sys.argv[1]
if want == "--names":
    print("\n".join(e.get("name","") for e in env))
else:
    for e in env:
        if e.get("name") == want:
            print(e.get("value", ""))
            break' "$1" 2>/dev/null
}

ENVS="$(readenv --names)"
REDIS_ADDR="$(readenv REDIS_ADDR)"
TTL="$(readenv CACHE_TTL)"

if [ -z "$(kget deployment "$APP" -o name)" ]; then
  fail "в кластере lab нет приложения ${APP}" \
       "примените passes-api.yaml, подставив адрес своего Harbor"
elif [ -z "$REDIS_ADDR" ]; then
  fail "в ${APP} не задана переменная REDIS_ADDR — кеш выключен" \
       "примените патч: kubectl patch deployment ${APP} --patch-file cache-patch.yaml"
elif printf '%s' "$REDIS_ADDR" | grep -q 'REDIS-ADDR'; then
  fail "в патче остался адрес-заглушка REDIS-ADDR" \
       "подставьте адрес своего Redis, например rfrm-redis-cache.${TENANT_NS}.svc.cozy.local"
else
  ok "приложение настроено на кеш по адресу ${REDIS_ADDR}, срок жизни записи ${TTL:-по умолчанию} с"
fi

if printf '%s' "$ENVS" | grep -q '^REDIS_PASSWORD$'; then
  ok "пароль к Redis приезжает в приложение (значение: <скрыто>)"
else
  fail "в ${APP} не задана переменная REDIS_PASSWORD" \
       "Redis требует аутентификации; создайте секрет redis-password и примените cache-patch.yaml"
fi

if [ -n "$(kget secret redis-password -o name)" ]; then
  ok "секрет redis-password с паролем от Redis существует"
else
  warn "в кластере нет секрета redis-password" \
       "создайте: read -rs P && kubectl create secret generic redis-password --from-literal=password=\"\$P\""
fi

# --- главная проверка: кеш действительно ускоряет ----------------------------
# Идентификатор берём заведомо новый, чтобы первый запрос гарантированно был промахом.
PROBE_ID="check$$$RANDOM"
R1="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"
R2="$(in_cluster_curl "${SVC}/employee?id=${PROBE_ID}")"

C1="$(printf '%s' "$R1" | jfield cached)"
C2="$(printf '%s' "$R2" | jfield cached)"
T1="$(printf '%s' "$R1" | jfield took_ms)"
T2="$(printf '%s' "$R2" | jfield took_ms)"
MODE="$(printf '%s' "$R2" | jfield cache)"

if [ -z "$C1" ] || [ -z "$C2" ]; then
  fail "сервис ${APP} не отдал ожидаемый JSON" \
       "смотрите kubectl logs -l app=passes-api; проверьте, что образ собран из app/ этой лабы (тег v2)"
  evidence "Что ответил сервис" "первый запрос: ${R1:-пусто}
второй запрос: ${R2:-пусто}"
elif [ "$MODE" != "redis" ]; then
  fail "приложение сообщает, что кеш выключен (cache: ${MODE})" \
       "переменная REDIS_ADDR не доехала до работающих подов — проверьте kubectl rollout status deployment/${APP}"
elif [ "$C1" = "True" ]; then
  warn "первый запрос уже пришёл из кеша — сравнить не с чем" \
       "маловероятное совпадение по идентификатору; запустите проверку ещё раз"
elif [ "$C2" != "True" ]; then
  fail "второй запрос по тому же идентификатору снова не попал в кеш" \
       "приложение не может писать в Redis: смотрите kubectl logs -l app=passes-api, обычно там NOAUTH или таймаут"
  evidence "Ответы сервиса" "первый:  ${R1}
второй: ${R2}"
else
  ok "кеш работает: промах ${T1} мс, попадание ${T2} мс"
  SPEEDUP="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print(f"{a/b:.0f}" if b > 0 else "больше чем в 1000")
except Exception:
    print("?")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  evidence "Замер на живом сервисе" "идентификатор: ${PROBE_ID}
первый запрос (промах):   ${T1} мс
второй запрос (попадание): ${T2} мс
выигрыш: примерно в ${SPEEDUP} раз
срок жизни записи: ${TTL:-по умолчанию} с"

  # Строгая часть: попадание должно быть на порядок быстрее промаха. Иначе
  # «кеш работает» означает только, что ключ записался, а выгоды нет.
  FASTER="$(python3 -c 'import sys
try:
    a, b = float(sys.argv[1]), float(sys.argv[2])
    print("yes" if a >= 100 and b * 10 <= a else "no")
except Exception:
    print("no")' "${T1:-0}" "${T2:-0}" 2>/dev/null)"
  if [ "$FASTER" = "yes" ]; then
    ok "выигрыш измерим: попадание примерно в ${SPEEDUP} раз быстрее промаха"
  else
    warn "попадание в кеш не даёт заметного выигрыша (${T1} мс против ${T2} мс)" \
         "проверьте, что справочник действительно медленный, а Redis находится не на том же поде"
  fi
fi

# --- сколько копий сервиса разделяют один кеш --------------------------------
# Кеш общий для всех копий — это стоит увидеть в отчёте: попадание могло прийти
# от другого пода, чем промах, и это правильно.
API_PODS="$(kget pods -l app=passes-api --no-headers | awk '$3=="Running"' | grep -c .)"
if [ "$API_PODS" -ge 1 ]; then
  ok "копий сервиса работает: ${API_PODS} (кеш у них общий)"
  evidence "Копии сервиса" "$(kget pods -l app=passes-api -o wide)"
else
  fail "нет ни одной работающей копии ${APP}" \
       "смотрите kubectl describe pod -l app=passes-api"
fi

finish
