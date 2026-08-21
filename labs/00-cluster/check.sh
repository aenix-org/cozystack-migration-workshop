#!/usr/bin/env bash
# Проверка лабы 0: у участника есть свой рабочий кластер Kubernetes.
#
# Проверяем не «объект создан», а «кластером можно пользоваться»: узлы готовы,
# системные службы поднялись, есть место под приложения следующих лаб.

LAB_NAME="00-cluster"
LAB_TITLE="Лаба 0 · Свой кластер Kubernetes"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

# --- версия кластера -------------------------------------------------------
SERVER_VER="$(server_version)"
if [ -n "$SERVER_VER" ]; then
  ok "кластер отвечает, версия Kubernetes ${SERVER_VER}"
  evidence "Версия Kubernetes" "$SERVER_VER"
else
  fail "не удалось определить версию кластера" \
       "проверьте вручную: kubectl version"
fi

# --- узлы ------------------------------------------------------------------
NODES_RAW="$(kubectl get nodes --no-headers 2>/dev/null)"
NODES_TOTAL="$(printf '%s' "$NODES_RAW" | grep -c . )"
NODES_READY="$(printf '%s' "$NODES_RAW" | awk '$2=="Ready"' | grep -c . )"

if [ "$NODES_READY" -ge 1 ]; then
  ok "рабочих узлов в строю: ${NODES_READY} из ${NODES_TOTAL}"
  evidence "Узлы" "$(kubectl get nodes -o wide 2>/dev/null)"
else
  fail "нет ни одного узла в состоянии Ready (всего узлов: ${NODES_TOTAL})" \
       "узел поднимается несколько минут; посмотрите kubectl get nodes и статус приложения в дашборде"
fi

# --- системные поды --------------------------------------------------------
# Кластер, у которого узел Ready, но не поднялась сеть, выглядит рабочим и не работает.
SYS_TOTAL="$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -c . )"
SYS_BAD="$(kubectl get pods -n kube-system --no-headers 2>/dev/null \
  | awk '$3!="Running" && $3!="Completed"' | grep -c . )"

if [ "$SYS_TOTAL" -eq 0 ]; then
  fail "в kube-system нет ни одного пода" \
       "это ненормально даже для пустого кластера — проверьте статус кластера в дашборде"
elif [ "$SYS_BAD" -eq 0 ]; then
  ok "системные службы кластера работают (подов: ${SYS_TOTAL})"
else
  fail "системные службы не в порядке: ${SYS_BAD} из ${SYS_TOTAL} подов не работают" \
       "смотрите kubectl get pods -n kube-system и опишите проблему в чате сообщества"
  evidence "Проблемные системные поды" \
    "$(kubectl get pods -n kube-system --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"')"
fi

# --- умеет ли кластер вообще запускать нагрузку ----------------------------
# Самая честная проверка готовности: не «узел Ready», а «под реально запустился».
PROBE="check00-$$"
if kubectl run "$PROBE" --image=busybox:1.36 --restart=Never --quiet \
     --overrides="$(_restricted_overrides "$PROBE" busybox:1.36 sh -c 'exit 0')" \
     >/dev/null 2>&1; then
  if kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$PROBE" \
       --timeout=90s >/dev/null 2>&1; then
    ok "кластер запускает нагрузку — тестовый под отработал и завершился"
  else
    PHASE="$(kubectl get pod "$PROBE" -o jsonpath='{.status.phase}' 2>/dev/null)"
    fail "тестовый под не запустился за 90 секунд (состояние: ${PHASE:-неизвестно})" \
         "смотрите kubectl describe pod $PROBE — обычно причина в нехватке ресурсов или в том, что образ не скачался"
    evidence "События тестового пода" \
      "$(kubectl describe pod "$PROBE" 2>/dev/null | sed -n '/Events:/,$p' | head -20)"
  fi
  kubectl delete pod "$PROBE" --wait=false >/dev/null 2>&1
else
  fail "не удалось создать тестовый под" \
       "проверьте права: kubectl auth can-i create pods"
fi

# --- запас под следующие лабы ----------------------------------------------
ALLOC_CPU="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{"\n"}{end}' 2>/dev/null | head -1)"
ALLOC_MEM="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null | head -1)"
if [ -n "$ALLOC_MEM" ]; then
  ALLOC_MEM_H="$(human_bytes "$ALLOC_MEM")"
  ok "на узле есть ресурсы под приложения: ${ALLOC_CPU} процессора, ${ALLOC_MEM_H} памяти"
  evidence "Доступные ресурсы узла" "cpu: ${ALLOC_CPU}
memory: ${ALLOC_MEM_H} (${ALLOC_MEM})"
else
  warn "не удалось прочитать доступные ресурсы узла" \
       "на прохождение лаб это скорее всего не повлияет"
fi

finish
