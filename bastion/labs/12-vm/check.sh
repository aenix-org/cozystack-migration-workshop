#!/usr/bin/env bash
# Проверка лабы 12: виртуалка и контейнерное приложение живут рядом и связаны.
#
# Проверяем не «объекты созданы», а связность:
#   1) приложению выдан адрес, видимый за пределами кластера lab,
#   2) по этому адресу действительно отвечает приложение и называет живой под,
#   3) виртуальная машина запущена,
#   4) выданный адрес принадлежит сети тенанта — той самой, где стоит машина.
# Четвёртый пункт и есть ответ на вопрос «а достучится ли машина», без входа в гостя.
#
# Запускается на виртуалке, из папки этой лабы. Лаба идёт сразу в двух местах, поэтому
# и доступов нужно два — к учебному кластеру и к тенанту на управляющем кластере:
#     export KUBECONFIG=~/lab.kubeconfig
#     export COZY_TENANT=workshopXX
#     export COZY_KUBECONFIG=~/.kube/workshop
#     cd labs/12-vm && ./check.sh
# Без тенантного доступа скрипт не падает: проверки со стороны тенанта он пропустит
# и скажет об этом, а всё, что относится к кластеру `lab`, отработает как обычно.
#
# Скрипт ничего не меняет — только читает и отправляет HTTP-запросы. Запускать
# до уборки: после удаления машины и адреса проверять будет нечего.

# Эти две переменные подхватывает lib.sh — они попадают в заголовок отчёта и в имя
# файла report-<лаба>-<дата>.md, который скрипт кладёт рядом с собой.
LAB_NAME="12-vm"
LAB_TITLE="Лаба 12 · Виртуалка рядом с контейнерами"
# Общая библиотека проверок: отсюда приходят ok / fail / warn / evidence / finish,
# запрос изнутри кластера и запись отчёта. Путь считается от места, где лежит сам
# скрипт, поэтому запуск из любого каталога работает одинаково.
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

# Без KUBECONFIG kubectl ищет кластер на самом виртуалке и валит все проверки подряд
# одной ошибкой, из которой настоящей причины не видно. Номер тенанта тоже обязателен:
# из него складывается имя namespace строкой ниже.
need_kubeconfig
need_tenant

# Имена, которые проверяем. VM — имя ЗАКАЗА на машину, то есть объекта VMInstance;
# по нему и спрашивается `kubectl get vminstance`. Сам запущенный экземпляр называется
# иначе: платформа разворачивает заказ чартом `vm-instance`, имя чарта склеивается
# с именем релиза, и получается vm-instance-spravochnik. Обращаться к нему нужно как
# vmi/vm-instance-spravochnik — с префиксом типа, потому что тенантные права выданы
# на virtualmachineinstances, а не на virtualmachines, и голое имя вернёт forbidden.
VM=spravochnik
SVC=rickroll-lb
NS="tenant-${COZY_TENANT}"
: "${COZY_KUBECONFIG:=$HOME/.kube/workshop}"

# Обращение к управляющему кластеру. Отдельный kubeconfig: тенант и кластер lab —
# это два разных кластера, одним файлом доступа их не охватить.
kt() { kubectl --kubeconfig "$COZY_KUBECONFIG" -n "$NS" "$@"; }

TENANT_OK=0
if [ -r "$COZY_KUBECONFIG" ] && kt get ns >/dev/null 2>&1; then
  TENANT_OK=1
elif [ -r "$COZY_KUBECONFIG" ] && kt get vminstance >/dev/null 2>&1; then
  TENANT_OK=1
fi

# --- внешний адрес приложения ----------------------------------------------
# Проверяем не то, что Service создан, а то, что платформа действительно выдала ему
# адрес: объект создаётся мгновенно, а EXTERNAL-IP появляется отдельным действием
# драйвера платформы и может не появиться вовсе. Заодно ловим самую частую правку
# не туда — тип, изменённый на ClusterIP: такой сервис работает, но снаружи кластера
# его не видно, и виртуалка до него не достучится.
LB_IP=""
if ! kubectl get svc "$SVC" >/dev/null 2>&1; then
  fail "в кластере нет Service ${SVC}" \
       "отдайте приложение наружу: kubectl apply -f rickroll-lb.yaml"
else
  SVC_TYPE="$(kubectl get svc "$SVC" -o jsonpath='{.spec.type}' 2>/dev/null)"
  LB_IP="$(kubectl get svc "$SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)"
  [ -z "$LB_IP" ] && LB_IP="$(kubectl get svc "$SVC" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"

  if [ "$SVC_TYPE" != "LoadBalancer" ]; then
    fail "Service ${SVC} имеет тип ${SVC_TYPE:-неизвестно}, а не LoadBalancer" \
         "внешнего адреса у такого сервиса не будет; примените rickroll-lb.yaml как есть, не меняя type"
  elif [ -n "$LB_IP" ]; then
    ok "приложению выдан адрес за пределами кластера: ${LB_IP}"
    evidence "Service ${SVC}" "$(kubectl get svc "$SVC" -o wide 2>/dev/null)"
  else
    fail "Service ${SVC} создан, но адрес до сих пор не выдан (EXTERNAL-IP пуст)" \
         "смотрите события: kubectl describe svc ${SVC} | sed -n '/Events:/,\$p' — обычно это значит, что драйвер платформы не смог выделить адрес"
    evidence "События Service ${SVC}" \
      "$(kubectl describe svc "$SVC" 2>/dev/null | sed -n '/Events:/,$p' | head -20)"
  fi
fi

# --- отвечает ли по этому адресу настоящее приложение ----------------------
# Сначала пробуем ровно тот путь, которым пойдёт виртуалка — по внешнему адресу.
# Если из пода этот адрес недоступен (маршрутизация зависит от того, как устроен
# кластер), откатываемся на внутренний адрес: он подтверждает хотя бы то, что
# сервис отбирает живые поды.
PAGE=""
VIA=""
if [ -n "$LB_IP" ]; then
  PAGE="$(in_cluster_curl "http://${LB_IP}/" )"
  VIA="внешнему адресу ${LB_IP}"
fi
if [ -z "$PAGE" ] && kubectl get svc "$SVC" >/dev/null 2>&1; then
  if [ -n "$LB_IP" ]; then
    warn "по внешнему адресу ${LB_IP} из пода кластера ответа нет" \
         "это не обязательно поломка: под и виртуалка ходят к адресу разными путями. Проверьте из консоли виртуалки: curl http://${LB_IP}"
  fi
  PAGE="$(in_cluster_curl "http://${SVC}.$(kubectl get svc "$SVC" -o jsonpath='{.metadata.namespace}' 2>/dev/null).svc/" )"
  VIA="внутреннему имени ${SVC}"
fi

if [ -z "$PAGE" ] && ! kubectl get svc "$SVC" >/dev/null 2>&1; then
  : # Service нет — об этом уже сказано выше, второй раз про то же не пишем.
elif [ -n "$PAGE" ]; then
  # Имя пода приложение подставляет прямо в страницу — по нему и сверяем.
  SERVED_POD="$(printf '%s' "$PAGE" | sed -n 's|.*<b>\([a-z0-9-]*\)</b>.*|\1|p' | head -1)"
  if [ -n "$SERVED_POD" ] && kubectl get pod "$SERVED_POD" >/dev/null 2>&1; then
    ok "по ${VIA} отвечает приложение, страницу отдал живой под ${SERVED_POD}"
    evidence "Ответ приложения" "запрос по ${VIA}
страницу отдал под: ${SERVED_POD}
поды приложения:
$(kubectl get pods -l app=rickroll --no-headers 2>/dev/null)"
  elif [ -n "$SERVED_POD" ]; then
    fail "страницу отдал под ${SERVED_POD}, но такого пода в кластере нет" \
         "адрес ведёт куда-то не туда; проверьте selector в rickroll-lb.yaml — он должен быть app: rickroll"
  else
    fail "по ${VIA} что-то отвечает, но это не страница приложения" \
         "проверьте, что приложение из лабы 1 работает: kubectl get pods -l app=rickroll"
  fi
else
  fail "по адресу ${SVC} ничего не отвечает" \
       "сначала убедитесь, что работает приложение из лабы 1: kubectl get pods -l app=rickroll"
fi

# --- сторона тенанта: сама виртуальная машина ------------------------------
# Здесь спрашиваем не «есть ли объект», а условие Ready: заказ на машину создаётся
# за секунду, а гость поднимается три-пять минут, и всё это время машина существует,
# но ничего не отвечает.
if [ "$TENANT_OK" -eq 0 ]; then
  warn "проверки со стороны тенанта пропущены: не читается ${COZY_KUBECONFIG}" \
       "укажите тенантный доступ: export COZY_KUBECONFIG=~/.kube/workshop"
else
  if ! kt get vminstance "$VM" >/dev/null 2>&1; then
    fail "в тенанте ${NS} нет виртуальной машины ${VM}" \
         "создайте VM Disk и VM Instance в дашборде или примените staff-directory-vm.yaml"
  else
    VM_READY="$(kt get vminstance "$VM" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    if [ "$VM_READY" = "True" ]; then
      ok "виртуальная машина ${VM} запущена"
    elif [ -n "$VM_READY" ]; then
      fail "виртуальная машина ${VM} есть, но не готова (Ready=${VM_READY})" \
           "смотрите карточку машины в дашборде; первое включение занимает 3-5 минут"
    else
      # Не у всех версий платформы у этого объекта есть условие Ready —
      # отсутствие условия не то же самое, что неработающая машина.
      warn "виртуальная машина ${VM} существует, но состояние прочитать не удалось" \
           "посмотрите её глазами в дашборде: должна быть включена"
    fi
    evidence "Виртуальные машины тенанта" "$(kt get vminstance 2>/dev/null)"
  fi

  # --- принадлежит ли выданный адрес сети тенанта -------------------------
  # Это и есть ответ на вопрос «достучится ли машина», без входа в гостя:
  # адрес, который кластер lab показывает как внешний, должен существовать
  # объектом в том же namespace, где стоит машина.
  if [ -n "$LB_IP" ]; then
    MIRROR="$(kt get svc -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.clusterIP}{"\n"}{end}' 2>/dev/null \
      | awk -v ip="$LB_IP" '$2==ip {print $1}' | head -1)"
    if [ -n "$MIRROR" ]; then
      ok "адрес ${LB_IP} принадлежит сети тенанта (объект ${MIRROR} в ${NS}) — машина его видит"
      evidence "Адрес в тенанте" "внешний адрес кластера lab: ${LB_IP}
объект в namespace ${NS}: ${MIRROR}"
    else
      warn "адрес ${LB_IP} не нашёлся объектом в namespace ${NS}" \
           "проверка косвенная и может не сработать на вашей версии платформы; решающий ответ даёт curl из консоли машины"
    fi
  fi
fi

finish
