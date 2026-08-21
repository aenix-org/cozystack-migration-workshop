#!/usr/bin/env bash
# Проверка лабы 4: выкатка новой версии и откат.
#
# Проверяем существо, а не набранные команды:
#   - в истории приложения есть несколько ревизий, то есть версию реально меняли;
#   - ConfigMap второй версии лежит в кластере отдельным объектом, а не правкой первого;
#   - у контейнера есть readinessProbe — без неё нулевой простой невоспроизводим;
#   - выкатка доведена до конца, а не застряла;
#   - страница, которую отдаёт Service, соответствует тому ConfigMap, на который
#     ссылается описание. Это ловит случай «описание откатили, а поды не пересоздались».
#
# Скрипт ничего не меняет. Одноразовый под нужен только чтобы забрать страницу
# изнутри кластера и убирает себя сам.

LAB_NAME="04-rollout"
LAB_TITLE="Лаба 4 · Выкатка новой версии и откат"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

APP=rickroll

# --- приложение на месте и доведено до рабочего состояния ------------------
if ! kubectl get deployment "$APP" >/dev/null 2>&1; then
  fail "приложения ${APP} нет в кластере" \
       "разверните его: kubectl apply -f ../01-deploy/rickroll.yaml"
  finish
  exit $?
fi

WANT="$(kubectl get deployment "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
HAVE="$(kubectl get deployment "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ -z "$HAVE" ] && HAVE=0

PROG_REASON="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .status.conditions[?(@.type=="Progressing")]}{.reason}{end}' 2>/dev/null)"

if [ "$HAVE" = "$WANT" ] && [ "${HAVE:-0}" -ge 1 ] && [ "$PROG_REASON" = "NewReplicaSetAvailable" ]; then
  ok "выкатка доведена до конца: готовых копий ${HAVE} из ${WANT}"
else
  fail "приложение не в завершённом состоянии (готово ${HAVE} из ${WANT}, причина: ${PROG_REASON:-нет})" \
       "если выкатка застряла — выйдите откатом: kubectl rollout undo deployment/${APP}"
fi
evidence "Состояние приложения" "$(kubectl get deployment,rs,pods -l app=${APP} 2>/dev/null)"

# --- readinessProbe: то, чем оплачен нулевой простой -----------------------
PROBE="$(kubectl get deployment "$APP" \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}' 2>/dev/null)"
if [ -n "$PROBE" ]; then
  ok "у контейнера есть readinessProbe (${PROBE}) — замена копий идёт только после готовности"
else
  fail "у контейнера нет readinessProbe" \
       "без неё кластер пускает трафик на неготовую копию; примените ../01-deploy/rickroll.yaml"
fi

# --- версии сделаны разными объектами --------------------------------------
if kubectl get configmap rickroll-page-v2 >/dev/null 2>&1; then
  ok "ConfigMap rickroll-page-v2 лежит в кластере отдельным объектом"
else
  fail "в кластере нет ConfigMap rickroll-page-v2" \
       "примените его: kubectl apply -f rickroll-page-v2.yaml"
fi

if kubectl get configmap rickroll-page-v1 >/dev/null 2>&1; then
  ok "первая версия страницы тоже сохранена — есть куда откатываться"
else
  warn "ConfigMap rickroll-page-v1 в кластере не найден" \
       "откат на первую версию без него не поднимет поды: kubectl apply -f ../01-deploy/rickroll.yaml"
fi

# --- история ревизий -------------------------------------------------------
# Смотрим НОМЕР последней ревизии, а не количество строк в истории. Откат не
# добавляет новый ReplicaSet — он переиспользует старый и повышает его номер,
# поэтому строк в истории после отката столько же, а номер вырастает.
#   1 — описание ни разу не меняли
#   2 — версию переключили
#   3 и больше — переключили и вернули
REV_MAX="$(kubectl rollout history deployment/${APP} 2>/dev/null \
  | awk '$1 ~ /^[0-9]+$/ { if ($1+0 > m) m = $1+0 } END { print m+0 }')"
[ -z "$REV_MAX" ] && REV_MAX=0

if [ "$REV_MAX" -ge 3 ]; then
  ok "последняя ревизия приложения — ${REV_MAX}: версию переключали и возвращали"
elif [ "$REV_MAX" -eq 2 ]; then
  warn "последняя ревизия — 2: выкатка сделана, откат ещё нет" \
       "верните первую версию: kubectl rollout undo deployment/${APP}"
else
  fail "последняя ревизия — ${REV_MAX}: описание приложения ни разу не менялось" \
       "переключите том на вторую версию патчем из шага 5, затем откатитесь"
fi
evidence "История ревизий" "$(kubectl rollout history deployment/${APP} 2>/dev/null)"

# --- на какую версию смотрит описание --------------------------------------
VOL_CM="$(kubectl get deployment "$APP" \
  -o jsonpath='{range .spec.template.spec.volumes[?(@.name=="page")]}{.configMap.name}{end}' 2>/dev/null)"

case "$VOL_CM" in
  rickroll-page-v1)
    ok "описание приложения возвращено на первую версию страницы"
    ;;
  rickroll-page-v2)
    warn "описание приложения указывает на вторую версию страницы" \
         "лаба заканчивается откатом; если так и задумано — ничего страшного, иначе: kubectl rollout undo deployment/${APP}"
    ;;
  "")
    fail "в описании нет тома с именем page" \
         "похоже, патч попал не туда (адресация по номеру!); примените ../01-deploy/rickroll.yaml заново"
    ;;
  *)
    fail "том page указывает на ConfigMap ${VOL_CM}, которого лаба не создавала" \
         "откатитесь: kubectl rollout undo deployment/${APP}"
    ;;
esac

# --- что реально отдаётся клиенту ------------------------------------------
# Самая содержательная проверка: сверяем описание с тем, что видит пользователь.
# Расхождение здесь означает, что поды не пересоздались под новое описание.
BODY="$(in_cluster_curl "http://${APP}/")"

if [ -z "$BODY" ]; then
  fail "Service ${APP} не отдал страницу изнутри кластера" \
       "проверьте эндпоинты: kubectl get endpointslices -l kubernetes.io/service-name=${APP}"
else
  if printf '%s' "$BODY" | grep -q 'ВЕРСИЯ 2'; then
    SERVED_VER="rickroll-page-v2"
  else
    SERVED_VER="rickroll-page-v1"
  fi

  if [ -n "$VOL_CM" ] && [ "$SERVED_VER" = "$VOL_CM" ]; then
    ok "клиенту отдаётся ровно та версия, что записана в описании (${SERVED_VER})"
  elif [ -n "$VOL_CM" ]; then
    fail "описание указывает на ${VOL_CM}, а клиенту отдаётся ${SERVED_VER}" \
         "копии не пересоздались под новое описание: kubectl rollout status deployment/${APP}"
  fi

  if printf '%s' "$BODY" | grep -q '__POD__'; then
    fail "имя копии в страницу не подставляется" \
         "потерян ConfigMap rickroll-conf: примените ../01-deploy/rickroll.yaml целиком"
  else
    SERVED_POD="$(printf '%s' "$BODY" | grep -o "${APP}-[a-z0-9]*-[a-z0-9]*" | head -1)"
    if [ -n "$SERVED_POD" ] && kubectl get pod "$SERVED_POD" >/dev/null 2>&1; then
      ok "страницу отдала живая копия ${SERVED_POD}"
    else
      warn "не удалось сопоставить имя из страницы с работающей копией" \
           "вероятно, копии менялись прямо во время проверки — запустите скрипт ещё раз"
    fi
  fi

  evidence "Отданная страница (фрагмент)" \
    "$(printf '%s' "$BODY" | grep -o '<h1>[^<]*</h1>' | head -1)
$(printf '%s' "$BODY" | grep -o "вас обслужил под<b>${APP}-[a-z0-9-]*</b>" | head -1)"
fi

# --- готовность к следующим лабам ------------------------------------------
if [ "$WANT" = "1" ]; then
  ok "количество копий возвращено к одной"
else
  warn "сейчас заказано копий: ${WANT}" \
       "после лабы стоит вернуть одну: kubectl scale deployment ${APP} --replicas=1"
fi

finish
