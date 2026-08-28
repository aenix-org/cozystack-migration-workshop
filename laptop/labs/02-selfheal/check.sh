#!/usr/bin/env bash
# Проверка лабы 2: самолечение.
#
# Проверяем не «команды набраны», а состояние кластера после лабы: приложение снова
# обслуживает запросы через Service, отдаёт имя своей копии, и это имя принадлежит
# реально работающему поду. Плюс ищем следы того, что копии пересоздавались.
#
# Скрипт ничего не удаляет и не создаёт, кроме одноразового пода для проверки
# доступности сервиса изнутри кластера — он убирает себя сам.

LAB_NAME="02-selfheal"
LAB_TITLE="Лаба 2 · Убить под и посмотреть, что будет"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

APP=rickroll

# RFC3339 из kubectl (всегда UTC с Z) в unix-секунды. Через python3, потому что
# BSD date на macOS и GNU date на Linux разбирают даты по-разному, а python есть везде,
# где работает lib.sh.
_epoch() {
  python3 -c 'import sys,datetime as d;print(int(d.datetime.strptime(sys.argv[1],
"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=d.timezone.utc).timestamp()))' "$1" 2>/dev/null
}

# --- приложение вообще есть ------------------------------------------------
DEP_TS="$(kubectl get deployment "$APP" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)"

if [ -z "$DEP_TS" ]; then
  fail "приложения ${APP} нет в кластере" \
       "в конце лабы его надо было вернуть: kubectl apply -f ../01-deploy/rickroll.yaml"
  evidence "Что есть в namespace" "$(kubectl get deployment,rs,pods 2>/dev/null)"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

if [ "${HAVE:-0}" -ge 1 ] && [ "$HAVE" = "$WANT" ]; then
  ok "приложение ${APP} восстановлено: готовых копий ${HAVE} из ${WANT}"
else
  fail "копий готово ${HAVE} из заказанных ${WANT}" \
       "смотрите kubectl describe deployment ${APP} и kubectl get pods -l app=${APP}"
fi
evidence "Состояние приложения" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- цепочка Deployment -> ReplicaSet -> Pod -------------------------------
# Смысл лабы в том, что копию возвращает ReplicaSet, а не «кластер вообще».
# Если владельцем пода оказался не ReplicaSet, значит участник поднял под руками,
# и самолечения он не увидит.
# Считаем поды поимённо, а не собираем уникальные виды владельцев: у пода без
# ownerReferences jsonpath отдаёт пустую строку, `sort -u` схлопывает её в невидимый
# элемент, и `*ReplicaSet*` матчится, пока хоть один под управляется ReplicaSet.
# Из-за этого посторонний под, поднятый руками, проходил проверку незамеченным.
PODS_TOTAL="$(kubectl get pods -l app=${APP} --no-headers 2>/dev/null | grep -c . )"
PODS_BY_RS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | grep -c . )"
OWNER_KINDS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null \
  | sort -u | tr '\n' ' ')"

case "${PODS_TOTAL}:${PODS_BY_RS}" in
  0:*)
    fail "нет ни одного пода с меткой app=${APP}" \
         "верните приложение: kubectl apply -f ../01-deploy/rickroll.yaml"
    ;;
  *:0)
    fail "ни один под ${APP} не управляется ReplicaSet — самолечения не будет" \
         "похоже, под поднят руками (kubectl run). Удалите его и примените ../01-deploy/rickroll.yaml"
    ;;
  *)
    if [ "$PODS_TOTAL" -ne "$PODS_BY_RS" ]; then
      fail "метку app=${APP} носят посторонние поды: ${PODS_BY_RS} из ${PODS_TOTAL} управляются ReplicaSet" \
           "остальные попадут в балансировку и будут отдавать чужой ответ — найдите их: kubectl get pods -l app=${APP} -o wide"
      evidence "Владельцы подов" \
        "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"\n"}{end}' 2>/dev/null)"
    else
    ok "копиями управляет ReplicaSet — цепочка Deployment → ReplicaSet → Pod цела"
    evidence "Кто чей владелец" \
      "$(kubectl get pods -l app=${APP} -o jsonpath='{range .items[*]}{.metadata.name}{" <- "}{.metadata.ownerReferences[0].kind}{"/"}{.metadata.ownerReferences[0].name}{"\n"}{end}' 2>/dev/null)"
    fi
    ;;
esac

# --- следы пересоздания копий ----------------------------------------------
# Прямых улик «под убивали» кластер не хранит. Есть две косвенные, и обе достаточные:
# под заметно моложе своего Deployment, и в событиях ReplicaSet больше одного создания.
POD_TS="$(kubectl get pods -l app=${APP} \
  -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null)"

DEP_E="$(_epoch "$DEP_TS")"
POD_E="$(_epoch "$POD_TS")"

if [ -n "$DEP_E" ] && [ -n "$POD_E" ]; then
  DELTA=$(( POD_E - DEP_E ))
  if [ "$DELTA" -ge 45 ]; then
    ok "копия моложе приложения на ${DELTA} с — значит прежнюю убирали, а эту создали взамен"
  else
    warn "копия почти ровесница приложения (разница ${DELTA} с)" \
         "если вы восстанавливали приложение целиком в самом конце — это нормально; иначе шаг с удалением пода не выполнен"
  fi
  evidence "Возраст объектов" "deployment создан: ${DEP_TS}
pod создан:        ${POD_TS}
разница:           ${DELTA} с"
else
  warn "не удалось сравнить возраст пода и приложения" \
       "нужен python3 в PATH; на прохождение лабы это не влияет"
fi

# События живут около часа, поэтому их отсутствие — не провал, а замечание.
CREATES="$(kubectl get events \
  --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet \
  --no-headers 2>/dev/null | grep -c "$APP")"
[ -z "$CREATES" ] && CREATES=0

if [ "$CREATES" -ge 2 ]; then
  ok "в событиях кластера ${CREATES} создания копии — самолечение действительно срабатывало"
  evidence "События создания копий" \
    "$(kubectl get events --field-selector reason=SuccessfulCreate,involvedObject.kind=ReplicaSet 2>/dev/null | grep "$APP" | tail -10)"
else
  warn "в событиях кластера видно создание копии только ${CREATES} раз" \
       "события хранятся около часа и могли истечь"
fi

# Ни один из двух признаков по отдельности не блокирующий: события живут около часа,
# а возраст совпадает у того, кто законно восстановил приложение целиком в конце лабы.
# Но если НЕ выполнен ни один — копию не удаляли вовсе, и лаба не сделана. Без этой
# связки скрипт печатал «ЛАБА СДАНА» сразу после лабы 1, не дождавшись ни одного удаления.
if [ "${DELTA:-0}" -lt 45 ] && [ "$CREATES" -lt 2 ]; then
  fail "следов самолечения не найдено: копию не удаляли" \
       "удалите копию: kubectl delete pod -l app=${APP} — и запустите проверку в течение часа, пока живы события"
fi

# --- сервис реально обслуживает --------------------------------------------
# Главная проверка по существу: не «объект есть», а «через Service приходит страница
# и в ней имя живой копии».
BODY="$(in_cluster_curl "http://${APP}/")"

if [ -z "$BODY" ]; then
  fail "Service ${APP} не отдал страницу изнутри кластера" \
       "проверьте эндпоинты: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
elif printf '%s' "$BODY" | grep -q '__POD__'; then
  fail "страница отдаётся, но имя копии в неё не подставилось" \
       "потерян ConfigMap rickroll-conf: примените ../01-deploy/rickroll.yaml целиком"
else
  SERVED="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
  if [ -z "$SERVED" ]; then
    fail "в ответе Service нет имени копии" \
         "страница пришла не от нашего приложения — проверьте kubectl get svc ${APP} -o yaml"
  elif kubectl get pod "$SERVED" >/dev/null 2>&1; then
    ok "Service отдаёт страницу, её обслужила живая копия ${SERVED}"
    evidence "Ответ Service (фрагмент)" \
      "$(printf '%s' "$BODY" | grep -o "вас обслужил под<b>${APP}-[a-z0-9-]*</b>" | head -1)"
  else
    fail "страницу отдала копия ${SERVED}, но такого пода в кластере уже нет" \
         "подождите десяток секунд и запустите проверку снова — вероятно, копия менялась прямо сейчас"
  fi
fi

# --- готовность к следующей лабе -------------------------------------------
if [ "$WANT" = "1" ]; then
  ok "количество копий возвращено к одной — лаба 3 начнётся с чистого листа"
else
  warn "сейчас заказано копий: ${WANT}" \
       "перед лабой 3 верните одну: kubectl scale deployment ${APP} --replicas=1"
fi

finish
