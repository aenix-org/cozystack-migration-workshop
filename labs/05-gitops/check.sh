#!/usr/bin/env bash
# Проверка лабы 5: состояние кластера приезжает из Git и удерживается сверкой.
#
# Проверяем не «Flux установлен», а «механизм работает»: источник читается, применённое
# принадлежит Flux, сервис отвечает, сверка не выключена. Установленный, но
# приостановленный Flux — это самый частый способ пройти лабу мимо смысла.

LAB_NAME="05-gitops"
LAB_TITLE="Лаба 5 · Инфраструктура в Git"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

NS_APP="passes"
GITREPO="passes"
KUSTOMIZATION="passes"

# Читаем поле объекта, не падая, если объекта или CRD нет.
kget() { kubectl get "$@" 2>/dev/null; }

# --- службы Flux -----------------------------------------------------------
if ! kget namespace flux-system >/dev/null; then
  fail "в кластере нет пространства имён flux-system" \
       "Flux не установлен: flux install --components=source-controller,kustomize-controller"
else
  FLUX_BAD=""
  for d in source-controller kustomize-controller; do
    READY="$(kget deployment "$d" -n flux-system -o jsonpath='{.status.readyReplicas}')"
    [ "${READY:-0}" -ge 1 ] 2>/dev/null || FLUX_BAD="$FLUX_BAD $d"
  done
  if [ -z "$FLUX_BAD" ]; then
    ok "службы Flux работают: source-controller и kustomize-controller"
    evidence "Поды Flux" "$(kget pods -n flux-system -o wide)"
  else
    fail "не работают службы Flux:${FLUX_BAD}" \
         "смотрите kubectl get pods -n flux-system; на маленьком узле им может не хватать памяти"
  fi
fi

# --- источник: GitRepository ------------------------------------------------
if ! kubectl api-resources --api-group=source.toolkit.fluxcd.io 2>/dev/null | grep -q gitrepositories; then
  fail "в кластере нет типа GitRepository" \
       "Flux не установлен или установлен без source-controller"
else
  GR_URL="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.spec.url}')"
  GR_READY="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  GR_MSG="$(kget gitrepository "$GITREPO" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  GR_REV="$(kget gitrepository "$GITREPO" -n flux-system -o jsonpath='{.status.artifact.revision}')"

  if [ -z "$GR_URL" ]; then
    fail "не найден GitRepository с именем ${GITREPO} в flux-system" \
         "примените flux/gitrepository.yaml, подставив адрес своего репозитория"
  elif printf '%s' "$GR_URL" | grep -q 'ЗАМЕНИТЕ-МЕНЯ'; then
    fail "в GitRepository остался адрес-заглушка" \
         "откройте flux/gitrepository.yaml и впишите адрес своего репозитория на GitHub"
  elif [ "$GR_READY" = "True" ]; then
    ok "Flux читает ваш репозиторий: ${GR_URL}"
    evidence "Источник в Git" "url: ${GR_URL}
revision: ${GR_REV:-неизвестна}"
  else
    fail "Flux не может прочитать репозиторий ${GR_URL}" \
         "смотрите flux get sources git; чаще всего это опечатка в адресе, приватный репозиторий или другая ветка"
    evidence "Ошибка источника" "${GR_MSG:-нет сообщения}"
  fi
fi

# --- применение: Kustomization ----------------------------------------------
KS_READY=""
if ! kubectl api-resources --api-group=kustomize.toolkit.fluxcd.io 2>/dev/null | grep -q kustomizations; then
  fail "в кластере нет типа Kustomization" \
       "Flux установлен без kustomize-controller — переустановите с обоими компонентами"
else
  KS_READY="$(kget kustomization "$KUSTOMIZATION" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
  KS_MSG="$(kget kustomization "$KUSTOMIZATION" -n flux-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')"
  KS_REV="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.status.lastAppliedRevision}')"
  KS_SUSPEND="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.suspend}')"
  KS_PRUNE="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.prune}')"
  KS_INTERVAL="$(kget kustomization "$KUSTOMIZATION" -n flux-system -o jsonpath='{.spec.interval}')"

  if [ -z "$KS_REV" ] && [ -z "$KS_READY" ]; then
    fail "не найден Kustomization с именем ${KUSTOMIZATION} в flux-system" \
         "примените flux/kustomization.yaml"
  elif [ "$KS_READY" = "True" ]; then
    ok "Flux применил состояние из Git, ревизия ${KS_REV}"
    evidence "Применённая ревизия" "$KS_REV"
  else
    fail "Flux не смог применить состояние из Git" \
         "смотрите flux get kustomizations и kubectl describe kustomization ${KUSTOMIZATION} -n flux-system"
    evidence "Ошибка применения" "${KS_MSG:-нет сообщения}"
  fi

  # Приостановленный Flux выглядит установленным и не делает ничего. Это главный
  # способ «сдать» лабу, не получив ни одной её выгоды.
  if [ "$KS_SUSPEND" = "true" ]; then
    fail "сверка приостановлена (suspend: true) — Flux не следит за кластером" \
         "включите обратно: flux resume kustomization ${KUSTOMIZATION}"
  else
    ok "сверка активна: расхождение с Git будет устранено само, интервал ${KS_INTERVAL:-по умолчанию}"
  fi

  if [ "$KS_PRUNE" = "true" ]; then
    ok "включено удаление того, что исчезло из Git (prune)"
  else
    warn "prune выключен — удалённое из репозитория останется работать в кластере" \
         "поставьте prune: true в flux/kustomization.yaml, иначе Git описывает состояние только наполовину"
  fi
fi

# --- объекты в кластере принадлежат Flux, а не были применены руками ---------
# Это ключевая проверка лабы: kubectl apply тем же файлом дал бы такой же
# Deployment, но без метки владельца. Метку ставит только kustomize-controller.
OWNER="$(kget deployment passes -n "$NS_APP" \
  -o jsonpath='{.metadata.labels.kustomize\.toolkit\.fluxcd\.io/name}')"
if [ -z "$(kget deployment passes -n "$NS_APP" -o name)" ]; then
  fail "в пространстве имён ${NS_APP} нет приложения passes" \
       "положите app/*.yaml в папку apps своего репозитория, сделайте push и дождитесь сверки"
elif [ "$OWNER" = "$KUSTOMIZATION" ]; then
  ok "приложение в кластере принадлежит Flux, а не применено руками"
else
  fail "приложение passes есть, но его создал не Flux" \
       "уберите его (kubectl delete ns ${NS_APP}) и дайте Flux развернуть его из Git заново"
fi

# --- приложение действительно отвечает --------------------------------------
PODS="$(kget pods -n "$NS_APP" -l app=passes --no-headers)"
PODS_READY="$(printf '%s' "$PODS" | awk '$3=="Running"' | grep -c .)"
BODY="$(in_cluster_curl "http://passes.${NS_APP}.svc.cluster.local/")"

if printf '%s' "$BODY" | grep -q 'Пропуск'; then
  ok "сервис «Пропуск» отвечает по HTTP внутри кластера (работающих копий: ${PODS_READY})"
else
  fail "сервис «Пропуск» не отвечает по адресу passes.${NS_APP}.svc.cluster.local" \
       "смотрите kubectl get pods -n ${NS_APP} и kubectl logs -n ${NS_APP} deploy/passes"
fi

# Имя пода в странице должно совпадать с реально запущенной копией: так видно,
# что отвечает именно тот под, который мы видим в кластере.
SERVED_POD="$(printf '%s' "$BODY" | grep -o 'passes-[a-z0-9]*-[a-z0-9]*' | head -1)"
if [ -n "$SERVED_POD" ] && printf '%s' "$PODS" | grep -q "$SERVED_POD"; then
  ok "страницу отдал реально существующий под ${SERVED_POD}"
  evidence "Копии сервиса" "$(kget pods -n "$NS_APP" -o wide)"
elif [ -n "$SERVED_POD" ]; then
  warn "под ${SERVED_POD} из ответа не найден среди запущенных" \
       "скорее всего копия пересоздалась между двумя запросами — запустите проверку ещё раз"
fi

# --- история изменений в вашем клоне репозитория ----------------------------
# Необязательная часть: скрипт не знает, где лежит клон, пока ему не скажут.
REPO="${LAB_REPO:-}"
if [ -z "$REPO" ]; then
  warn "история репозитория не проверялась: не задана переменная LAB_REPO" \
       "чтобы проверить и её: export LAB_REPO=~/passes-gitops && ./check.sh"
elif [ ! -d "$REPO/.git" ]; then
  warn "в ${REPO} нет клона репозитория" \
       "укажите папку, в которую вы делали git clone"
else
  HEAD_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null | cut -c1-7)"
  LOG="$(git -C "$REPO" log --oneline -20 2>/dev/null)"

  if printf '%s' "$LOG" | grep -qi '^[0-9a-f]* *revert'; then
    ok "в истории есть откат через git revert — плохое изменение отменено там, где живёт истина"
    evidence "История изменений" "$LOG"
  else
    fail "в последних коммитах нет ни одного revert" \
         "откатите плохое изменение через git revert --no-edit HEAD и сделайте push, а не через kubectl rollout undo"
  fi

  # Применённое в кластере должно совпадать с последним коммитом в ветке.
  if [ -n "$HEAD_SHA" ] && printf '%s' "${KS_REV:-}" | grep -q "$HEAD_SHA"; then
    ok "в кластере работает ровно то, что лежит в вашей ветке (коммит ${HEAD_SHA})"
  elif [ -n "$HEAD_SHA" ]; then
    warn "коммит в кластере (${KS_REV:-неизвестен}) отличается от локального HEAD (${HEAD_SHA})" \
         "проверьте, что локальные коммиты отправлены (git push), и подождите интервал сверки"
  fi
fi

finish
