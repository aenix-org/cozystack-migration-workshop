#!/usr/bin/env bash
# Проверка лабы 6: приложение приезжает в кластер из СВОЕГО закрытого реестра.
#
# Проверяем не «Harbor создан», а всю цепочку: реестр отвечает по своему API,
# образ в манифесте лежит именно в нём, у кластера есть реквизиты на этот же адрес,
# и под с этим образом реально работает и отвечает.
#
# Два кластера: KUBECONFIG — ваш кластер lab, COZY_KUBECONFIG — управляющий кластер
# Cozystack, где живёт managed-сервис Harbor.

LAB_NAME="06-harbor"
LAB_TITLE="Лаба 6 · Свой приватный реестр образов"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig
need_tenant

APP="passes-api"
TENANT_NS="tenant-${COZY_TENANT}"
COZY_KUBECONFIG="${COZY_KUBECONFIG:-$HOME/tenant.kubeconfig}"

kget() { kubectl get "$@" 2>/dev/null; }
cozy() { kubectl --kubeconfig "$COZY_KUBECONFIG" "$@" 2>/dev/null; }

# --- managed-сервис Harbor на управляющем кластере ---------------------------
# Необязательная часть: без тенантного кубконфига лаба всё равно проверяема,
# но сервис со стороны платформы мы не увидим.
if [ ! -r "$COZY_KUBECONFIG" ]; then
  warn "не найден тенантный кубконфиг ${COZY_KUBECONFIG} — состояние Harbor не проверялось" \
       "укажите путь: export COZY_KUBECONFIG=~/.kube/workshop"
else
  HARBOR_ERR="$(kubectl --kubeconfig "$COZY_KUBECONFIG" get harbors.apps.cozystack.io \
    -n "$TENANT_NS" --no-headers 2>&1 >/dev/null)"
  HARBOR_LIST="$(cozy get harbors.apps.cozystack.io -n "$TENANT_NS" --no-headers)"
  if [ -n "$HARBOR_ERR" ]; then
    warn "не удалось посмотреть приложения Harbor в тенанте ${TENANT_NS}" \
         "роль в тенанте может не давать эту команду — это не ошибка лабы; всё остальное проверяется ниже"
  elif [ -z "$HARBOR_LIST" ]; then
    fail "в тенанте ${TENANT_NS} нет ни одного приложения Harbor" \
         "создайте его в дашборде: Создать приложение -> Harbor"
  else
    HARBOR_NAME="$(printf '%s' "$HARBOR_LIST" | awk 'NR==1{print $1}')"
    HARBOR_READY="$(cozy get harbors.apps.cozystack.io "$HARBOR_NAME" -n "$TENANT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    if [ "$HARBOR_READY" = "True" ]; then
      ok "managed-сервис Harbor «${HARBOR_NAME}» готов"
    else
      warn "Harbor «${HARBOR_NAME}» есть, но не сообщает о готовности" \
           "смотрите его состояние в дашборде; Harbor поднимается 5-10 минут, а без объектного хранилища в тенанте не поднимется совсем"
    fi
    evidence "Приложения Harbor в тенанте" "$HARBOR_LIST"
    # Секрет с реквизитами читать не пытаемся: роль тенанта его обычно не отдаёт,
    # и это правильно. Пароль в отчёте нам всё равно не нужен.
  fi
fi

# --- откуда приложение берёт образ ------------------------------------------
IMAGE="$(kget deployment "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}')"
REGISTRY=""
if [ -z "$IMAGE" ]; then
  fail "в кластере lab нет приложения ${APP}" \
       "примените passes.yaml, подставив в него адрес своего Harbor"
else
  REGISTRY="${IMAGE%%/*}"
  case "$REGISTRY" in
    *.*|*:*) : ;;              # похоже на адрес реестра
    *) REGISTRY="" ;;          # адреса нет — значит образ тянется с Docker Hub
  esac

  if [ -z "$REGISTRY" ]; then
    fail "образ ${IMAGE} тянется из публичного реестра, а не из вашего" \
         "в имени образа первой частью должен идти адрес вашего Harbor"
  elif printf '%s' "$REGISTRY" | grep -qi 'HARBOR-HOST'; then
    fail "в манифесте остался адрес-заглушка HARBOR-HOST" \
         "подставьте адрес своего Harbor: sed -i 's|HARBOR-HOST|harbor.вашдомен|g' passes.yaml"
  elif printf '%s' "$REGISTRY" | grep -qiE '^(docker\.io|registry-1\.docker\.io|quay\.io|ghcr\.io|gcr\.io|registry\.k8s\.io)$'; then
    fail "образ тянется из публичного реестра ${REGISTRY}" \
         "ИБ просила закрытый реестр — соберите и запушьте образ в свой Harbor"
  else
    ok "приложение запускается из вашего реестра: ${REGISTRY}"
    evidence "Образ приложения" "$IMAGE"
  fi
fi

# --- реестр действительно работает ------------------------------------------
if [ -z "$REGISTRY" ]; then
  : # уже отчитались выше
elif ! command -v curl >/dev/null 2>&1; then
  warn "нет утилиты curl — доступность реестра не проверялась" \
       "откройте https://${REGISTRY} в браузере, там должен быть интерфейс Harbor"
else
  PING="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/ping" 2>/dev/null)"
  if printf '%s' "$PING" | grep -qi 'pong'; then
    VER="$(curl -fsS --max-time 20 "https://${REGISTRY}/api/v2.0/systeminfo" 2>/dev/null \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("harbor_version","неизвестна"))' 2>/dev/null)"
    ok "реестр отвечает по API: https://${REGISTRY} (Harbor ${VER:-версия неизвестна})"
    evidence "Реестр" "https://${REGISTRY}
API ping: ${PING}
версия Harbor: ${VER:-неизвестна}"
  else
    fail "реестр https://${REGISTRY} не отвечает на запрос /api/v2.0/ping" \
         "проверьте адрес и состояние приложения Harbor в дашборде"
  fi
fi

# --- реквизиты доступа у кластера -------------------------------------------
PULL_SECRETS="$(kget deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.imagePullSecrets[*]}{.name}{"\n"}{end}')"
if [ -z "$IMAGE" ]; then
  : # приложения нет, отчитались выше
elif [ -z "$PULL_SECRETS" ]; then
  fail "в манифесте ${APP} не указан ни один imagePullSecret" \
       "образ из закрытого реестра без реквизитов не скачается: добавьте imagePullSecrets, см. passes.yaml"
else
  SECRET_OK=""
  for s in $PULL_SECRETS; do
    STYPE="$(kget secret "$s" -o jsonpath='{.type}')"
    [ "$STYPE" = "kubernetes.io/dockerconfigjson" ] || continue
    # Разбираем конфиг питоном: base64 -d ведёт себя по-разному на macOS и Linux,
    # а печатать пароль в отчёт нельзя — берём только список адресов.
    SERVERS="$(kget secret "$s" -o jsonpath='{.data.\.dockerconfigjson}' \
      | python3 -c 'import sys,json,base64
raw = sys.stdin.read().strip()
try:
    cfg = json.loads(base64.b64decode(raw))
    print(" ".join(cfg.get("auths", {}).keys()))
except Exception:
    pass' 2>/dev/null)"
    if [ -n "$REGISTRY" ] && printf '%s' "$SERVERS" | grep -q "$REGISTRY"; then
      SECRET_OK="$s"
      break
    fi
  done

  if [ -n "$SECRET_OK" ]; then
    ok "у кластера есть реквизиты к ${REGISTRY} в секрете ${SECRET_OK} (пароль: <скрыто>)"
  else
    fail "ни один из указанных секретов (${PULL_SECRETS}) не содержит реквизитов к ${REGISTRY:-вашему реестру}" \
         "создайте так: kubectl create secret docker-registry harbor --docker-server=${REGISTRY:-АДРЕС} --docker-username=admin --docker-password=..."
  fi
fi

# --- поды реально запустились -----------------------------------------------
PODS="$(kget pods -l app=passes-api --no-headers)"
RUNNING="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BADSTATE="$(printf '%s' "$PODS" | awk '$3!="Running"{print $3}' | sort -u | tr '\n' ' ')"

if [ "$RUNNING" -ge 1 ]; then
  ok "копий приложения работает: ${RUNNING}"
  evidence "Поды приложения" "$(kget pods -l app=passes-api -o wide)"
elif printf '%s' "$BADSTATE" | grep -q 'ImagePullBackOff\|ErrImagePull'; then
  fail "образ не скачивается: ${BADSTATE}" \
       "это отказ в доступе к реестру или опечатка в имени образа; настоящую причину покажет kubectl describe pod -l app=passes-api"
  evidence "Причина отказа" "$(kubectl describe pod -l app=passes-api 2>/dev/null \
    | grep -A2 'Failed to pull\|Warning' | head -20)"
else
  fail "нет ни одной работающей копии приложения (состояния: ${BADSTATE:-подов нет})" \
       "смотрите kubectl describe pod -l app=passes-api"
fi

# Отдельная проверка на самую труднодиагностируемую ошибку лабы: образ собран
# под ARM, а узлы кластера на x86. Всё выглядит правильно, но не запускается.
LOGS="$(kubectl logs -l app=passes-api --tail=20 --all-containers 2>&1)"
if printf '%s' "$LOGS" | grep -q 'exec format error'; then
  fail "образ собран под другую архитектуру процессора" \
       "пересоберите с флагом: docker build --platform linux/amd64 -t ${IMAGE} app/ и запушьте заново"
fi

# --- приложение отвечает по существу ----------------------------------------
if [ -z "$(kget svc "$APP" -o name)" ]; then
  fail "нет Service с именем ${APP}" \
       "он описан в passes.yaml — примените файл целиком, а не только Deployment"
else
  BODY="$(in_cluster_curl "http://${APP}.default.svc.cluster.local/")"
  SERVED_POD="$(printf '%s' "$BODY" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("pod",""))
except Exception: pass' 2>/dev/null)"

  if [ -z "$SERVED_POD" ]; then
    fail "сервис ${APP} не отдал ожидаемый JSON" \
         "смотрите kubectl logs -l app=passes-api и убедитесь, что порт в Service совпадает с портом приложения"
  elif printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
    ok "сервис отвечает JSON, ответ пришёл от реально работающего пода ${SERVED_POD}"
    evidence "Ответ сервиса" "$BODY"
  else
    warn "сервис ответил от имени пода ${SERVED_POD}, которого нет среди запущенных" \
         "скорее всего копия пересоздалась между запросами — запустите проверку ещё раз"
  fi
fi

finish
