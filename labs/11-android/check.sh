#!/usr/bin/env bash
# Проверка лабы 11: сборка Android доехала до конца, а APK — до бакета.
#
# Проверяем не «Job создан», а три разных утверждения, и они не равны друг другу:
#   1) Job завершился успешно,
#   2) внутри него действительно собрался APK (BUILD SUCCESSFUL),
#   3) файл действительно уехал в объектное хранилище (маркер APK-UPLOADED).
# Job может завершиться успешно и не собрать ничего — если кто-то поправил скрипт.

LAB_NAME="11-android"
LAB_TITLE="Лаба 11 · Сборка мобильного приложения в кластере"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

need_kubeconfig

JOB=propusk-build
SECRET=bucket-creds

# Значение ключа секрета. base64 -d есть не везде одинаковый (BSD против GNU),
# поэтому декодируем питоном — он уже нужен библиотеке проверок.
secret_val() {
  kubectl get secret "$SECRET" -o jsonpath="{.data.$1}" 2>/dev/null \
    | python3 -c 'import sys,base64
d=sys.stdin.read().strip()
print(base64.b64decode(d).decode("utf-8", "replace") if d else "")' 2>/dev/null
}

# --- секрет с доступом к бакету -------------------------------------------
if kubectl get secret "$SECRET" >/dev/null 2>&1; then
  MISSING=""
  for k in endpoint bucketName accessKey secretKey; do
    [ -z "$(secret_val "$k")" ] && MISSING="$MISSING $k"
  done
  if [ -z "$MISSING" ]; then
    ok "секрет ${SECRET} на месте, все четыре ключа заполнены"
    # Значения ключей в отчёт не попадают — только имена полей.
    evidence "Поля секрета ${SECRET}" "endpoint: $(secret_val endpoint)
bucketName: $(secret_val bucketName)
accessKey: <скрыто>
secretKey: <скрыто>"
  else
    fail "в секрете ${SECRET} не заполнены поля:${MISSING}" \
         "пересоздайте секрет командой из шага 3, значения берутся в дашборде: Bucket -> builds -> Secrets"
  fi
else
  fail "в кластере нет секрета ${SECRET}" \
       "шаг 3 лабы: kubectl create secret generic ${SECRET} --from-literal=endpoint=... (четыре поля)"
fi

# --- доступно ли хранилище изнутри кластера --------------------------------
# Самая частая причина «Job упал на пятом шаге» — не ключи, а то, что до
# хранилища из кластера не достучаться. Проверяем это отдельно от сборки.
EP="$(secret_val endpoint)"
if [ -n "$EP" ]; then
  CODE="$(in_cluster_curl "https://${EP}/" "-k -o /dev/null -w %{http_code}")"
  case "$CODE" in
    2*|3*|4*)
      ok "хранилище ${EP} отвечает изнутри кластера (HTTP ${CODE})"
      evidence "Ответ хранилища" "GET https://${EP}/ -> HTTP ${CODE}
Коды 403 и 404 здесь нормальны: анонимный запрос к корню S3 и должен быть отклонён."
      ;;
    5*)
      warn "хранилище ${EP} отвечает ошибкой HTTP ${CODE}" \
           "сборка может пройти, но выгрузка APK — нет; скажите ведущему"
      ;;
    *)
      fail "хранилище ${EP} не отвечает изнутри кластера" \
           "проверьте поле endpoint в секрете: оно должно быть БЕЗ https:// и без слэша на конце"
      ;;
  esac
else
  warn "не проверяю доступность хранилища" \
       "сначала нужен секрет ${SECRET} с полем endpoint"
fi

# --- сам Job ---------------------------------------------------------------
if ! kubectl get job "$JOB" >/dev/null 2>&1; then
  fail "в кластере нет Job ${JOB}" \
       "шаг 6 лабы: kubectl apply -f android-build.yaml"
else
  SUCCEEDED="$(kubectl get job "$JOB" -o jsonpath='{.status.succeeded}' 2>/dev/null)"
  FAILED="$(kubectl get job "$JOB" -o jsonpath='{.status.failed}' 2>/dev/null)"
  DURATION="$(kubectl get job "$JOB" -o jsonpath='{.status.completionTime}' 2>/dev/null)"
  POD_PHASE="$(kubectl get pods -l "job-name=${JOB}" \
    -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)"

  if [ "${SUCCEEDED:-0}" -ge 1 ] 2>/dev/null; then
    ok "Job ${JOB} завершился успешно"
    evidence "Job" "$(kubectl get job "$JOB" -o wide 2>/dev/null)
завершён: ${DURATION:-неизвестно}"
  elif [ "$POD_PHASE" = "Pending" ]; then
    fail "под сборки висит в Pending — он не запустился и сам не запустится" \
         "смотрите причину: kubectl describe pod -l job-name=${JOB} | grep -A5 Events; при Insufficient memory увеличьте узел до u1.large (шаг 7)"
    evidence "События пода сборки" \
      "$(kubectl describe pod -l "job-name=${JOB}" 2>/dev/null | sed -n '/Events:/,$p' | head -20)"
  elif [ "${FAILED:-0}" -ge 1 ] 2>/dev/null; then
    fail "Job ${JOB} завершился с ошибкой (неудачных попыток: ${FAILED})" \
         "смотрите последние строки лога: kubectl logs job/${JOB} --tail=40"
    evidence "Хвост лога упавшей сборки" \
      "$(kubectl logs "job/${JOB}" --tail=30 2>/dev/null)"
  else
    fail "Job ${JOB} ещё не завершился (состояние пода: ${POD_PHASE:-неизвестно})" \
         "первая сборка идёт 20-30 минут; следите за ходом: kubectl logs -f job/${JOB}"
  fi

  # --- что именно произошло внутри ----------------------------------------
  LOGS="$(kubectl logs "job/${JOB}" --tail=-1 2>/dev/null)"
  if [ -z "$LOGS" ]; then
    warn "логи сборки недоступны" \
         "под сборки удалён или ещё не создан; без логов нельзя подтвердить, что APK действительно собрался"
  else
    if printf '%s' "$LOGS" | grep -q 'BUILD SUCCESSFUL'; then
      GRADLE_LINE="$(printf '%s' "$LOGS" | grep -m1 'BUILD SUCCESSFUL')"
      ok "APK действительно собрался (${GRADLE_LINE})"
    else
      fail "в логах нет строки BUILD SUCCESSFUL — компиляция не дошла до конца" \
           "ищите первую строку с FAILURE: kubectl logs job/${JOB} | grep -n -m1 -A20 FAILURE"
    fi

    UPLOADED="$(printf '%s' "$LOGS" | grep -m1 '^APK-UPLOADED ' | awk '{print $2}')"
    if [ -n "$UPLOADED" ]; then
      ok "APK уехал в бакет: ${UPLOADED}"
      evidence "Содержимое бакета после сборки" \
        "$(printf '%s' "$LOGS" | sed -n '/5\/5 кладу APK в бакет/,$p' | grep -v '^APK-UPLOADED ' | head -20)"
    else
      fail "APK собрался, но в бакет не уехал" \
           "смотрите хвост лога: kubectl logs job/${JOB} --tail=20; чаще всего виноват bucketName — в нём нужно длинное имя из дашборда, а не 'builds'"
    fi
  fi
fi

# --- хватает ли узлу места под такую сборку --------------------------------
# Не приговор, а объяснение: если Job не поместился, причина почти всегда здесь.
BIGGEST_MEM="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
  | sort -n | tail -1)"
if [ -n "$BIGGEST_MEM" ]; then
  BIGGEST_H="$(human_bytes "$BIGGEST_MEM")"
  case "$BIGGEST_H" in
    *Gi)
      GB="${BIGGEST_H%Gi}"
      GB_INT="${GB%%.*}"
      if [ "${GB_INT:-0}" -ge 6 ] 2>/dev/null; then
        ok "самый крупный узел отдаёт ${BIGGEST_H} памяти — сборке хватает"
      else
        warn "самый крупный узел отдаёт всего ${BIGGEST_H} памяти" \
             "сборка просит 4Gi только под requests; если Job висит в Pending, увеличьте тип узла до u1.large (шаг 7)"
      fi
      ;;
    *)
      warn "на узлах меньше гигабайта доступной памяти (${BIGGEST_H})" \
           "сборка Android туда не поместится, увеличьте тип узла (шаг 7)"
      ;;
  esac
  evidence "Ресурсы узлов" "$(kubectl get nodes -o wide 2>/dev/null)"
fi

finish
