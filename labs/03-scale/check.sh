#!/usr/bin/env bash
# Проверка лабы 3: автомасштабирование.
#
# Проверяем не «hpa.yaml применён», а что механизм живой и способен принимать решения:
#   - у контейнера есть requests.cpu, иначе процент считать не от чего;
#   - HPA существует и нацелен именно на наш Deployment;
#   - коридор задан осмысленно (maxReplicas больше одного, иначе расти некуда);
#   - метрики РЕАЛЬНО собираются: в статусе есть число, а не <unknown>;
#   - масштабирование уже срабатывало, то есть нагрузку действительно давали.
#
# Скрипт ничего не меняет. Одноразовый под поднимается только чтобы проверить,
# что Fortio отвечает изнутри кластера, и убирает себя сам.

LAB_NAME="03-scale"
LAB_TITLE="Лаба 3 · Нагрузка и автомасштабирование"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

APP=rickroll
HPA=rickroll

# --- цель масштабирования на месте -----------------------------------------
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "приложения ${APP} нет в кластере — масштабировать нечего" \
       "разверните его: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi
ok "приложение ${APP} на месте"

# --- requests.cpu: без него HPA не считает проценты ------------------------
# Самая частая причина «HPA не работает», и по манифесту её не видно:
# объект создаётся успешно, а TARGETS навсегда остаётся <unknown>.
REQ_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)"
LIM_CPU="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null)"

if [ -n "$REQ_CPU" ]; then
  ok "у контейнера задан requests.cpu = ${REQ_CPU} — есть от чего считать проценты"
  evidence "Ресурсы контейнера" "requests.cpu: ${REQ_CPU}
limits.cpu:   ${LIM_CPU:-не задан}"
else
  fail "у контейнера ${APP} не задан requests.cpu" \
       "HPA по Utilization без него не работает; примените ../01-deploy/rickroll.yaml заново"
fi

# --- сам HPA ---------------------------------------------------------------
TARGET_KIND="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.kind}' 2>/dev/null)"
TARGET_NAME="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)"

if [ -z "$TARGET_NAME" ]; then
  fail "в кластере нет HorizontalPodAutoscaler с именем ${HPA}" \
       "примените его: kubectl apply -f hpa.yaml (проверку запускайте до уборки)"
  evidence "Что есть из автомасштабирования" "$(kubectl get hpa 2>&1)"
  finish
  exit $?
fi

if [ "$TARGET_KIND" = "Deployment" ] && [ "$TARGET_NAME" = "$APP" ]; then
  ok "HPA ${HPA} нацелен на Deployment/${APP}"
else
  fail "HPA ${HPA} управляет объектом ${TARGET_KIND}/${TARGET_NAME}, а не Deployment/${APP}" \
       "поправьте scaleTargetRef в hpa.yaml и примените заново"
fi

MINR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)"
MAXR="$(kubectl get hpa "$HPA" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)"
[ -z "$MINR" ] && MINR=1

if [ -n "$MAXR" ] && [ "$MAXR" -gt 1 ] 2>/dev/null; then
  ok "коридор задан: от ${MINR} до ${MAXR} копий — расти есть куда"
else
  fail "верхняя граница коридора равна ${MAXR:-не задана} — расти некуда" \
       "в hpa.yaml должно быть maxReplicas больше единицы"
fi

# --- цель по метрике -------------------------------------------------------
TGT_TYPE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.type}' 2>/dev/null)"
TGT_VAL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null)"

if [ "$TGT_TYPE" = "Utilization" ] && [ -n "$TGT_VAL" ]; then
  ok "порог задан: ${TGT_VAL}% от requests.cpu (${REQ_CPU:-?})"
else
  warn "порог задан не в процентах от requests (тип: ${TGT_TYPE:-нет})" \
       "лаба разбирает вариант Utilization; на работоспособность это не влияет"
fi

# --- ГЛАВНОЕ: метрики реально собираются -----------------------------------
# Именно здесь видно разницу между «объект создан» и «механизм работает».
CUR_UTIL="$(kubectl get hpa "$HPA" \
  -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)"
SCALING_ACTIVE="$(kubectl get hpa "$HPA" \
  -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.status}{end}' 2>/dev/null)"

if [ -n "$CUR_UTIL" ] && [ "$SCALING_ACTIVE" = "True" ]; then
  ok "метрики собираются: текущая загрузка ${CUR_UTIL}% от requests, HPA принимает решения"
elif [ "$SCALING_ACTIVE" = "True" ]; then
  ok "HPA принимает решения (ScalingActive=True), текущее значение метрики ещё не отдано"
else
  REASON="$(kubectl get hpa "$HPA" \
    -o jsonpath='{range .status.conditions[?(@.type=="ScalingActive")]}{.reason}: {.message}{end}' 2>/dev/null)"
  fail "HPA не получает метрики — в TARGETS будет <unknown>, решать ему не на чем" \
       "первые две минуты после apply это нормально, подождите и повторите; если не прошло — kubectl top pods и kubectl describe hpa ${HPA}"
  evidence "Почему HPA не активен" "${REASON:-причина не указана в статусе}"
fi

evidence "Состояние HPA" "$(kubectl get hpa "$HPA" 2>/dev/null)"

# --- metrics-server отвечает напрямую --------------------------------------
TOP="$(kubectl top pods -l app=${APP} --no-headers 2>&1)"
# `kubectl top` при отсутствии подов печатает «No resources found» и возвращает 0 —
# без явной проверки на пустоту это давало зелёный там, где метрик нет вообще.
if [ -z "$TOP" ] || printf '%s' "$TOP" | grep -qiE 'error|not available|No resources found'; then
  fail "kubectl top не отдаёт потребление подов" \
       "в кластере нет работающего metrics-server — без него автомасштабирование по CPU невозможно"
  evidence "Ответ kubectl top" "$TOP"
else
  ok "metrics-server отдаёт потребление подов ${APP}"
  evidence "Потребление копий" "$TOP"
fi

# --- масштабирование действительно срабатывало -----------------------------
# lastScaleTime живёт столько же, сколько сам HPA, поэтому проверка не зависит
# от того, истекли события кластера или нет.
LAST_SCALE="$(kubectl get hpa "$HPA" -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
CUR_REPL="$(kubectl get hpa "$HPA" -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"

if [ -n "$LAST_SCALE" ]; then
  ok "HPA уже менял количество копий (последний раз: ${LAST_SCALE}) — нагрузку давали"
  evidence "Отметка о масштабировании" "lastScaleTime: ${LAST_SCALE}
currentReplicas: ${CUR_REPL:-неизвестно}"
else
  fail "HPA ни разу не менял количество копий" \
       "дайте нагрузку из Fortio: URL http://${APP}/, QPS 1200, Connections 80, Duration 90s"
fi

# --- Fortio: нужен в лабе 4 ------------------------------------------------
if kubectl get deployment fortio >/dev/null 2>&1; then
  FBODY="$(in_cluster_curl "http://fortio:8080/fortio/")"
  if printf '%s' "$FBODY" | grep -qi 'fortio'; then
    ok "генератор нагрузки Fortio работает и отвечает изнутри кластера"
  else
    warn "Fortio развёрнут, но его веб-интерфейс не ответил" \
         "проверьте: kubectl rollout status deployment/fortio и kubectl logs deploy/fortio"
  fi
else
  warn "Fortio в кластере нет" \
       "если собираетесь делать лабу 4, он там понадобится: kubectl apply -f fortio.yaml"
fi

finish
