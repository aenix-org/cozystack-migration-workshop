#!/usr/bin/env bash
# Проверка лабы 1: приложение развёрнуто и работает по существу.
#
# «По существу» здесь значит: страница реально отдаётся по HTTP, в ней подставлено
# имя пода, и это имя совпадает с именем реально запущенной копии. Проверять
# существование объекта Deployment бессмысленно — он может существовать и не работать.

LAB_NAME="01-deploy"
LAB_TITLE="Лаба 1 · Первое приложение: мышкой и текстом"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

# --- объект приложения ------------------------------------------------------
if kubectl get deployment rickroll >/dev/null 2>&1; then
  DESIRED="$(kubectl get deployment rickroll -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  READY="$(kubectl get deployment rickroll -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  READY="${READY:-0}"
  DESIRED="${DESIRED:-0}"
  if [ "$DESIRED" -eq 0 ]; then
    # Отдельный случай: объект есть, но у него запрошено ноль копий. Сообщение
    # «ни одна копия не готова (нужно 0)» звучало бы бессмыслицей.
    fail "приложение остановлено — запрошено 0 копий" \
         "верните копию: kubectl scale deployment rickroll --replicas=1"
  elif [ "$READY" -ge 1 ]; then
    ok "приложение развёрнуто, готовых копий ${READY} из ${DESIRED}"
  else
    fail "приложение создано, но ни одна копия не готова (нужно ${DESIRED})" \
         "смотрите kubectl get pods -l app=rickroll и kubectl describe deployment rickroll"
    evidence "Состояние подов" "$(kubectl get pods -l app=rickroll -o wide 2>/dev/null)"
  fi
else
  fail "не найден Deployment с именем rickroll" \
       "примените манифест: kubectl apply -f rickroll.yaml"
fi

# --- настройки и страница ---------------------------------------------------
for cm in rickroll-conf rickroll-page-v1; do
  if kubectl get configmap "$cm" >/dev/null 2>&1; then
    ok "настройки на месте: ConfigMap ${cm}"
  else
    fail "не найден ConfigMap ${cm}" \
         "он создаётся тем же файлом: kubectl apply -f rickroll.yaml"
  fi
done

# --- постоянный адрес -------------------------------------------------------
if kubectl get service rickroll >/dev/null 2>&1; then
  # Service без эндпоинтов — типичная и незаметная поломка: объект есть,
  # а метки на подах не совпали с селектором, и за адресом пусто.
  EPS="$(kubectl get endpoints rickroll -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
  EPS_N="$(printf '%s' "$EPS" | wc -w | tr -d ' ')"
  if [ "${EPS_N:-0}" -ge 1 ]; then
    ok "постоянный адрес работает, за ним копий: ${EPS_N}"
    evidence "Адреса за сервисом" "$EPS"
  else
    fail "Service rickroll есть, но за ним нет ни одной копии" \
         "обычно причина в том, что метки пода не совпали с selector сервиса — сверьте app: rickroll"
  fi
else
  fail "не найден Service с именем rickroll" \
       "он создаётся тем же файлом: kubectl apply -f rickroll.yaml"
fi

# --- главное: страница реально отдаётся -------------------------------------
BODY="$(in_cluster_curl 'http://rickroll/')"
if printf '%s' "$BODY" | grep -q 'Never Gonna Give You Up'; then
  ok "приложение отвечает по HTTP и отдаёт свою страницу"
else
  fail "приложение не отдало ожидаемую страницу" \
       "проверьте вручную: kubectl port-forward svc/rickroll 8080:80, затем откройте http://localhost:8080"
  evidence "Что вернулось вместо страницы" "$(printf '%s' "$BODY" | head -20)"
fi

# --- подстановка имени пода -------------------------------------------------
# Ради этого лаба и сделана: имя в странице должно совпадать с реальным подом.
SERVED_BY="$(printf '%s' "$BODY" | grep -o '<b>[^<]*</b>' | head -1 | sed 's/<[^>]*>//g')"
REAL_PODS="$(kubectl get pods -l app=rickroll -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"

if [ -z "$SERVED_BY" ]; then
  fail "в странице нет имени пода" \
       "проверьте, что подставился ConfigMap rickroll-conf — в нём строка sub_filter '__POD__' '\$hostname'"
elif [ "$SERVED_BY" = "__POD__" ]; then
  fail "имя пода не подставилось — в странице осталась заглушка __POD__" \
       "nginx не применил sub_filter: проверьте, что том с настройками смонтирован в /etc/nginx/conf.d"
elif printf '%s' "$REAL_PODS" | grep -qx "$SERVED_BY"; then
  ok "имя пода подставляется и совпадает с реально запущенной копией: ${SERVED_BY}"
  evidence "Кто обслужил запрос" "$SERVED_BY"
  evidence "Запущенные копии" "$REAL_PODS"
else
  fail "страница называет под «${SERVED_BY}», но такого пода в кластере нет" \
       "возможно, копия пересоздалась между запросом и проверкой — запустите скрипт ещё раз"
fi

# --- проверка готовности настроена ------------------------------------------
# Без неё в лабе про обновление версий будет простой, и участник решит, что мы соврали.
PROBE_PATH="$(kubectl get deployment rickroll \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE_PATH" ]; then
  ok "проверка готовности настроена (${PROBE_PATH}) — обновление пройдёт без простоя"
else
  warn "у приложения нет проверки готовности" \
       "лаба 4 про обновление без простоя на таком приложении даст ошибки — верните readinessProbe из rickroll.yaml"
fi

finish
