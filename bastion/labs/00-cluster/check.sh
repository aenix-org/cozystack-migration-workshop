#!/usr/bin/env bash
# Проверка лабы 0: учебный кластер поднялся и вы к нему подключились.
#
# Проверяем не «объект создан», а что кластер работает по существу:
#   1) кластер lab отвечает по вашему файлу доступа (KUBECONFIG=~/lab.kubeconfig),
#   2) хотя бы один узел в состоянии Ready,
#   3) на узлах есть свободные ресурсы под будущие приложения.
# Если задан COZY_TENANT — дополнительно смотрим на УПРАВЛЯЮЩЕМ кластере, что заказ
# Kubernetes/lab дошёл до Ready и что включён сбор метрик (без него лаба 14 пустая).
#
# Запускается на виртуалке, из папки этой лабы:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_TENANT=workshopXX      # для проверок со стороны тенанта (необязательно)
#     cd labs/00-cluster && ./check.sh
#
# Скрипт только читает — состояние кластера не меняет.
LAB_NAME="00-cluster"
LAB_TITLE="Лаба 0 · Свой кластер Kubernetes"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Без доступа к самому кластеру lab проверять нечего — это и есть главное
# доказательство лабы. need_kubeconfig остановит скрипт с понятной подсказкой,
# если KUBECONFIG не задан или кластер не отвечает.
need_kubeconfig

COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/.kube/config}"
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- 1) Подключение к кластеру lab -------------------------------------------
# need_kubeconfig уже убедился, что сервер отвечает. Фиксируем это отдельным
# результатом и кладём версию сервера в отчёт.
KVER="$(server_version)"
ok "кластер lab отвечает — файл доступа рабочий"
[ -n "$KVER" ] && evidence "Версия сервера кластера lab" "$KVER"

# --- 2) Узлы в строю ---------------------------------------------------------
# Считаем, сколько узлов в состоянии Ready. Пустой список означает, что кластер
# поднялся, но узловая группа md0 ещё разворачивается.
NODES_WIDE="$(kubectl get nodes -o wide 2>/dev/null)"
READY_NODES="$(kubectl get nodes \
  -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' 2>/dev/null \
  | grep -c '^True')"
TOTAL_NODES="$(kubectl get nodes --no-headers 2>/dev/null | grep -c .)"
if [ "${READY_NODES:-0}" -ge 1 ]; then
  ok "узлы в строю: ${READY_NODES} из ${TOTAL_NODES} в состоянии Ready"
  [ -n "$NODES_WIDE" ] && evidence "Узлы кластера" "$NODES_WIDE"
else
  fail "ни один узел не в состоянии Ready (узлов всего: ${TOTAL_NODES:-0})" \
       "подождите пару минут, пока узловая группа md0 развернётся; статус — в дашборде на приложении lab, либо: kubectl get nodes"
  evidence "Узлы кластера" "${NODES_WIDE:-нет узлов}"
fi

# --- 3) Есть ли место под будущие приложения --------------------------------
# allocatable первого узла: если ресурсов нет, дальше ничего не запустится.
ALLOC_CPU="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null)"
ALLOC_MEM="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null)"
if [ -n "$ALLOC_MEM" ]; then
  ok "на узлах есть ресурсы под приложения (на узле: ${ALLOC_CPU} CPU, $(human_bytes "$ALLOC_MEM") RAM)"
  evidence "Свободные ресурсы узла (allocatable)" "cpu: ${ALLOC_CPU}, memory: $(human_bytes "$ALLOC_MEM")"
else
  warn "не удалось прочитать свободные ресурсы узлов" \
       "обычно это временно — повторите через минуту"
fi

# --- 4) Со стороны управляющего кластера (если задан тенант) -----------------
# Не обязательно для лабы 0: подключение к самому кластеру выше уже всё доказало.
# Но если тенантный доступ есть — подтвердим заказ и проверим сбор метрик.
if [ -n "${COZY_TENANT:-}" ]; then
  TENANT_NS="tenant-${COZY_TENANT}"
  if [ ! -r "$COZY_KUBECONFIG" ]; then
    warn "тенантный доступ ${COZY_KUBECONFIG} не найден — заказ кластера на управляющем не проверялся" \
         "это не провал лабы; путь задаётся: export COZY_KUBECONFIG=~/.kube/config"
  else
    LAB_READY="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$LAB_READY" = "True" ]; then
      ok "на управляющем кластере заказ Kubernetes/lab в состоянии Ready"
    elif [ -n "$LAB_READY" ]; then
      warn "заказ Kubernetes/lab ещё не Ready (сейчас: ${LAB_READY})" \
           "кластер уже отвечает, платформа ещё сводит его к заданному; посмотрите: kubectl --kubeconfig ~/.kube/config -n ${TENANT_NS} get kubernetes.apps.cozystack.io lab"
    else
      warn "не нашёл заказ Kubernetes/lab в тенанте ${TENANT_NS}" \
           "если кластер вы называли иначе — подставьте своё имя; либо роль в тенанте не даёт эту команду (не ошибка лабы)"
    fi
    # Сбор метрик: лаба 14 опирается на данные, которые копятся с момента включения.
    MON="$(cozy get kubernetes.apps.cozystack.io lab -n "$TENANT_NS" \
      -o jsonpath='{.spec.addons.monitoringAgents.enabled}')"
    if [ "$MON" = "true" ]; then
      ok "сбор метрик включён (понадобится в лабе 14)"
    elif [ -n "$LAB_READY" ]; then
      warn "сбор метрик выключен — лаба 14 останется без данных" \
           "включить: дашборд → приложение lab → Addons → Monitoring agents (задним числом метрики не появятся)"
    fi
  fi
else
  warn "COZY_TENANT не задан — проверки со стороны управляющего кластера пропущены" \
       "не обязательно для лабы 0; чтобы включить: export COZY_TENANT=workshopXX"
fi

finish
