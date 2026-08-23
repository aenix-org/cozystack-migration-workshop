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
#
# Запускается на ноутбуке, из папки этой лабы, по доступу к учебному кластеру `lab`
# (не к тенанту на управляющем кластере):
#     export KUBECONFIG=~/lab.kubeconfig
#     cd labs/03-scale && ./check.sh
# Переменная COZY_TENANT здесь не нужна: вся лаба идёт внутри кластера `lab`.
#
# Запускать ДО уборки. Часть проверок опирается на следы уже случившегося роста,
# а они живут вместе с объектом HPA: удалите его — и доказывать будет нечем.

# Попадают в заголовок отчёта и в имя файла report-<лаба>-<дата>.md рядом со скриптом.
LAB_NAME="03-scale"
LAB_TITLE="Лаба 3 · Нагрузка и автомасштабирование"
# Общая библиотека: ok / fail / warn / evidence / finish, запросы изнутри кластера,
# запись отчёта. Путь считается от места самого скрипта, а не от текущего каталога.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Без KUBECONFIG kubectl ищет кластер на ноутбуке и валит всё подряд одной ошибкой,
# в которой настоящей причины не разглядеть. Останавливаемся сразу.
need_kubeconfig

# Имена вынесены в переменные, чтобы совпадение имени приложения и имени HPA
# в этой лабе не выглядело как одно и то же имя, случайно написанное дважды.
APP=rickroll
HPA=rickroll

# --- цель масштабирования на месте -----------------------------------------
# Приложение из лабы 1 — то, чем HPA управляет. Если его нет, все дальнейшие
# проверки посыплются каскадом и участник получит десяток ошибок вместо одной
# внятной, поэтому здесь единственное место, где скрипт завершается досрочно.
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
# Проверяем не только наличие объекта, но и на кого он нацелен. HPA с опечаткой
# в scaleTargetRef создаётся успешно и выглядит в списке как рабочий, но всю лабу
# управляет несуществующим приложением.
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
# Здесь warn, а не fail: вариант с AverageValue (порог в миллиядрах) тоже рабочий,
# лаба разбирает лишь один из двух. Заваливать за него было бы неправдой.
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
# Дублирует предыдущую проверку с другой стороны и разделяет две разные поломки:
# «метрик нет во всём кластере» и «метрики есть, но HPA до них не добрался».
# Первое чинит администратор кластера, второе — участник в своём манифесте.
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

# Одной отметки времени мало: она проставляется и при сокращении копий, то есть
# появляется даже у того, кто поднял реплики руками и дал HPA убрать лишние. Ищем
# именно рост ПО НАГРУЗКЕ — событие с превышением порога.
#
# И наоборот: сама отметка живёт не всегда. На кластере, где нагрузку давали час
# назад, lastScaleTime может быть пустой, а события ещё живы — поэтому события
# проверяются ПЕРВЫМИ, иначе выполненная лаба ложно заваливается.
SCALE_UP="$(kubectl get events --field-selector involvedObject.name="$HPA" \
  -o jsonpath='{range .items[*]}{.reason}{" "}{.message}{"\n"}{end}' 2>/dev/null \
  | grep -i 'SuccessfulRescale' | grep -ci 'above target')"

if [ "${SCALE_UP:-0}" -ge 1 ]; then
  ok "HPA поднимал количество копий из-за нагрузки — событие с превышением порога на месте"
  evidence "Масштабирование" "событий роста: ${SCALE_UP}
lastScaleTime: ${LAST_SCALE:-нет}
currentReplicas: ${CUR_REPL:-неизвестно}"
elif [ -n "$LAST_SCALE" ]; then
  ok "HPA менял количество копий (последний раз: ${LAST_SCALE})"
  evidence "Отметка о масштабировании" "lastScaleTime: ${LAST_SCALE}
currentReplicas: ${CUR_REPL:-неизвестно}"
else
  fail "следов работы автомасштабирования нет" \
       "дайте нагрузку из Fortio: URL http://${APP}/, QPS 1200, Connections 80, Duration 90s"
fi

# --- Fortio: нужен в лабе 4 ------------------------------------------------
# К самой лабе 3 отношения уже не имеет, поэтому warn, а не fail. Смысл в том, чтобы
# участник узнал о пропаже генератора здесь, а не посреди выкатки под нагрузкой,
# когда останавливаться и разворачивать его будет некстати.
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
