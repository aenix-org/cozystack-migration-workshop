#!/usr/bin/env bash
# Проверка лабы 14: наблюдаемость действительно работает.
#
# «Участник посмотрел график» проверить нельзя, и притворяться, что можно, нечестно.
# Поэтому проверяем то, без чего график невозможен:
#   1) агент сбора метрик работает в кластере,
#   2) он отправляет собранное в ваш тенант, а не в никуда,
#   3) сбор логов тоже работает — без него половина лабы бессмысленна,
#   4) в кластере есть след нагрузки из лабы 3, который в графиках можно найти.

LAB_NAME="14-observability"
LAB_TITLE="Лаба 14 · Найти свой всплеск в графиках"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

MON_NS=cozy-monitoring

# --- namespace сбора --------------------------------------------------------
if ! kubectl get ns "$MON_NS" >/dev/null 2>&1; then
  fail "в кластере нет namespace ${MON_NS} — сбор метрик выключен" \
       "включите дополнение: дашборд -> Kubernetes -> lab -> изменить -> Addons -> Monitoring agents. Учтите: записи появятся только с этого момента"
  finish
  exit $?
fi

# --- агент метрик -----------------------------------------------------------
VMAGENT_RUNNING="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/ && $3=="Running"' | grep -c . )"
VMAGENT_TOTAL="$(kubectl get pods -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /^vmagent/' | grep -c . )"

if [ "$VMAGENT_RUNNING" -ge 1 ]; then
  ok "агент сбора метрик работает (подов vmagent: ${VMAGENT_RUNNING})"
elif [ "$VMAGENT_TOTAL" -ge 1 ]; then
  fail "агент сбора метрик есть, но не работает (${VMAGENT_RUNNING} из ${VMAGENT_TOTAL} в Running)" \
       "смотрите причину: kubectl -n ${MON_NS} describe pod -l app.kubernetes.io/name=vmagent | sed -n '/Events:/,\$p'"
else
  fail "в ${MON_NS} нет ни одного пода vmagent" \
       "дополнение Monitoring agents включено не до конца; подождите пару минут и проверьте: kubectl get pods -n ${MON_NS}"
fi
evidence "Поды сбора в ${MON_NS}" "$(kubectl get pods -n "$MON_NS" 2>/dev/null)"

# --- куда именно уезжают метрики -------------------------------------------
# Работающий агент, который пишет в никуда, выглядит точно так же, как рабочий.
RW_URL="$(kubectl get vmagent -n "$MON_NS" \
  -o jsonpath='{.items[0].spec.remoteWrite[0].url}' 2>/dev/null)"
if [ -n "$RW_URL" ]; then
  case "$RW_URL" in
    *tenant-*)
      TARGET_NS="$(printf '%s' "$RW_URL" | sed -n 's|.*vminsert-[a-z]*\.\([^.]*\)\..*|\1|p')"
      ok "метрики отправляются в тенант${TARGET_NS:+ (${TARGET_NS})}"
      ;;
    *)
      warn "метрики отправляются по адресу, не похожему на тенантный" \
           "это может быть нормально, если ведущий настроил общее хранилище; адрес в свидетельствах"
      ;;
  esac
  evidence "Куда отправляются метрики" "$RW_URL"
else
  warn "не удалось прочитать адрес отправки метрик" \
       "посмотрите руками: kubectl get vmagent -n ${MON_NS} -o yaml"
fi

# --- сбор логов -------------------------------------------------------------
FB_DESIRED="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $2; exit}')"
FB_READY="$(kubectl get ds -n "$MON_NS" --no-headers 2>/dev/null \
  | awk '$1 ~ /fluent-bit/ {print $4; exit}')"
if [ -n "$FB_DESIRED" ] && [ "${FB_READY:-0}" = "$FB_DESIRED" ] && [ "${FB_READY:-0}" != "0" ]; then
  ok "сбор логов работает на всех узлах (${FB_READY}/${FB_DESIRED})"
elif [ -n "$FB_DESIRED" ]; then
  fail "сбор логов запущен не на всех узлах (${FB_READY:-0} из ${FB_DESIRED})" \
       "смотрите: kubectl -n ${MON_NS} get pods | grep fluent-bit — без него шаг с поиском по журналам не сработает"
else
  warn "сборщик логов fluent-bit не найден" \
       "источник vlogs-generic в Grafana будет пустым; шаг с поиском по журналам выполнить не получится"
fi

# --- есть ли что искать в графиках -----------------------------------------
# Метрики могут собираться идеально, но если нагрузки не было, искать нечего.
if kubectl get hpa rickroll >/dev/null 2>&1; then
  LAST_SCALE="$(kubectl get hpa rickroll -o jsonpath='{.status.lastScaleTime}' 2>/dev/null)"
  CUR="$(kubectl get hpa rickroll -o jsonpath='{.status.currentReplicas}' 2>/dev/null)"
  DES="$(kubectl get hpa rickroll -o jsonpath='{.status.desiredReplicas}' 2>/dev/null)"
  if [ -n "$LAST_SCALE" ]; then
    ok "след нагрузки есть: автомасштабирование срабатывало (последний раз ${LAST_SCALE})"
    evidence "Состояние автомасштабирования" "$(kubectl get hpa rickroll 2>/dev/null)
последнее срабатывание: ${LAST_SCALE}
сейчас копий: ${CUR:-?}, требуется: ${DES:-?}"
  else
    warn "автомасштабирование настроено, но ни разу не срабатывало" \
         "ступеньку роста копий вы не найдёте; повторите нагрузку из лабы 3 генератором fortio"
  fi
else
  warn "в кластере нет HorizontalPodAutoscaler с именем rickroll" \
       "шаги 5 и 6 этой лабы опираются на лабу 3; без неё найдёте только всплеск процессора, но не ступеньку"
fi

# --- сами метрики о приложении ----------------------------------------------
# Косвенно, но по существу: если поды приложения живы, их потребление в графиках есть.
APP_PODS="$(kubectl get pods -l app=rickroll --no-headers 2>/dev/null | grep -c . )"
if [ "${APP_PODS:-0}" -ge 1 ]; then
  ok "поды приложения на месте (${APP_PODS} шт.) — их потребление видно в графиках"
  evidence "Поды приложения" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
else
  warn "подов приложения rickroll в кластере нет" \
       "исторические метрики за время лабы 3 при этом сохранились; просто выставьте в Grafana тот диапазон времени"
fi

# --- где искать Grafana -----------------------------------------------------
# Не проверка, а помощь: адрес Grafana участники ищут дольше всего.
: "${COZY_KUBECONFIG:=$HOME/.kube/workshop}"
if [ -n "${COZY_TENANT:-}" ] && [ -r "$COZY_KUBECONFIG" ]; then
  TNS="tenant-${COZY_TENANT}"
  MON_TARGET="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get ns "$TNS" \
    -o jsonpath='{.metadata.labels.namespace\.cozystack\.io/monitoring}' 2>/dev/null)"
  if [ -n "$MON_TARGET" ]; then
    GRAF_HOST="$(kubectl --kubeconfig "$COZY_KUBECONFIG" -n "$MON_TARGET" get ingress \
      -o jsonpath='{range .items[*]}{.spec.rules[0].host}{"\n"}{end}' 2>/dev/null \
      | grep '^grafana\.' | head -1)"
    if [ -n "$GRAF_HOST" ]; then
      ok "Grafana для ваших метрик: https://${GRAF_HOST}"
      evidence "Grafana" "https://${GRAF_HOST}
метрики тенанта ${TNS} хранятся в namespace ${MON_TARGET}"
    else
      warn "мониторинг вашего тенанта живёт в ${MON_TARGET}, но адрес Grafana прочитать не удалось" \
           "если ${MON_TARGET} — не ваш namespace, значит Grafana общая: спросите адрес у ведущего"
      evidence "Мониторинг тенанта" "namespace с мониторингом: ${MON_TARGET}"
    fi
  else
    warn "не удалось определить, куда уходят метрики тенанта ${TNS}" \
         "адрес Grafana спросите у ведущего или найдите в дашборде: приложение Monitoring -> Ingress"
  fi
else
  warn "адрес Grafana не определён" \
       "задайте COZY_TENANT и COZY_KUBECONFIG, и скрипт найдёт его сам; на сдачу лабы это не влияет"
fi

finish
