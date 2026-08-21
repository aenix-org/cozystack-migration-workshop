#!/usr/bin/env bash
# Общая библиотека для скриптов проверки лабораторных.
# Подключается так:  . "$(dirname "$0")/../../check/lib.sh"
#
# Намеренно НЕ используется `set -e`: скрипт обязан прогнать все проверки и показать
# полную картину, а не останавливаться на первой же неудаче. Читатель запускает его
# именно тогда, когда застрял, — обрывать его на полпути значит скрыть половину ответа.

LAB_NAME="${LAB_NAME:-unknown}"
LAB_TITLE="${LAB_TITLE:-$LAB_NAME}"

_pass=0
_fail=0
_warn=0
_lines=()
_evidence=()

# Цвета только когда вывод идёт в терминал: в файле и в CI escape-последовательности
# читаются как мусор.
if [ -t 1 ]; then
  _C_OK=$'\033[32m'; _C_FAIL=$'\033[31m'; _C_WARN=$'\033[33m'; _C_DIM=$'\033[2m'; _C_OFF=$'\033[0m'
else
  _C_OK=''; _C_FAIL=''; _C_WARN=''; _C_DIM=''; _C_OFF=''
fi

ok() {
  _pass=$((_pass + 1))
  printf '%s[  OK  ]%s %s\n' "$_C_OK" "$_C_OFF" "$1"
  _lines+=("- **OK** — $1")
}

# fail "что не так" "что с этим делать"
fail() {
  _fail=$((_fail + 1))
  printf '%s[ FAIL ]%s %s\n' "$_C_FAIL" "$_C_OFF" "$1"
  [ -n "${2:-}" ] && printf '         %s%s%s\n' "$_C_DIM" "$2" "$_C_OFF"
  _lines+=("- **FAIL** — $1")
  [ -n "${2:-}" ] && _lines+=("  - что делать: $2")
}

warn() {
  _warn=$((_warn + 1))
  printf '%s[ WARN ]%s %s\n' "$_C_WARN" "$_C_OFF" "$1"
  [ -n "${2:-}" ] && printf '         %s%s%s\n' "$_C_DIM" "$2" "$_C_OFF"
  _lines+=("- **WARN** — $1")
  [ -n "${2:-}" ] && _lines+=("  - примечание: $2")
}

# evidence "заголовок" "значение" — попадает в артефакт, в терминал не печатается.
# Свидетельства нужны, чтобы отчёт можно было кому-то показать и он что-то значил.
evidence() {
  _evidence+=("### $1")
  _evidence+=('```')
  _evidence+=("$2")
  _evidence+=('```')
}

need_kubeconfig() {
  if [ -z "${KUBECONFIG:-}" ]; then
    printf '%s[ FAIL ]%s не задана переменная KUBECONFIG\n' "$_C_FAIL" "$_C_OFF"
    printf '         %sсначала: export KUBECONFIG=~/lab.kubeconfig%s\n' "$_C_DIM" "$_C_OFF"
    exit 1
  fi
  if ! kubectl version -o json >/dev/null 2>&1; then
    printf '%s[ FAIL ]%s кластер не отвечает по KUBECONFIG=%s\n' "$_C_FAIL" "$_C_OFF" "$KUBECONFIG"
    printf '         %sпроверьте: kubectl get nodes%s\n' "$_C_DIM" "$_C_OFF"
    exit 1
  fi
}

need_tenant() {
  if [ -z "${COZY_TENANT:-}" ]; then
    printf '%s[ FAIL ]%s не задана переменная COZY_TENANT\n' "$_C_FAIL" "$_C_OFF"
    printf '         %sнапример: export COZY_TENANT=workshop07%s\n' "$_C_DIM" "$_C_OFF"
    exit 1
  fi
}

# Время без GNU-расширений: BSD date на macOS не понимает `-d`.
_now() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }
_stamp() { date -u '+%Y%m%d-%H%M%S'; }

finish() {
  local total=$((_pass + _fail + _warn))
  local report="report-${LAB_NAME}-$(_stamp).md"
  local verdict

  if [ "$_fail" -eq 0 ]; then
    verdict="ЛАБА СДАНА"
  else
    verdict="ЕСТЬ НЕЗАКРЫТЫЕ ПУНКТЫ"
  fi

  printf '\n'
  printf 'проверок: %d · прошло: %d · провалено: %d · предупреждений: %d\n' \
    "$total" "$_pass" "$_fail" "$_warn"
  if [ "$_fail" -eq 0 ]; then
    printf '%s%s%s\n' "$_C_OK" "$verdict" "$_C_OFF"
  else
    printf '%s%s%s\n' "$_C_FAIL" "$verdict" "$_C_OFF"
  fi

  {
    echo "# Отчёт: ${LAB_TITLE}"
    echo
    echo "- Дата: $(_now)"
    echo "- Итог: **${verdict}**"
    echo "- Проверок: ${total} (прошло ${_pass}, провалено ${_fail}, предупреждений ${_warn})"
    [ -n "${COZY_TENANT:-}" ] && echo "- Тенант: \`${COZY_TENANT}\`"
    echo
    echo "## Проверки"
    echo
    printf '%s\n' "${_lines[@]}"
    if [ "${#_evidence[@]}" -gt 0 ]; then
      echo
      echo "## Свидетельства"
      echo
      printf '%s\n' "${_evidence[@]}"
    fi
    echo
    echo "---"
    echo
    echo "Отчёт получен скриптом \`check.sh\` из лабораторных Cozystack."
    echo "Проверялась работоспособность по существу, а не факт применения манифестов."
  } > "$report"

  printf 'отчёт: %s\n' "$report"
  [ "$_fail" -eq 0 ] && return 0 || return 1
}

# Версия ИМЕННО сервера. `kubectl version -o json` печатает и клиентскую, и серверную;
# наивный grep по gitVersion берёт первую попавшуюся — клиентскую — и отчёт начинает
# врать о версии кластера. Ошибиться здесь легко, поэтому вынесено в библиотеку.
server_version() {
  kubectl version -o json 2>/dev/null \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null
}

# Человекочитаемый размер: Kubernetes отдаёт allocatable то в Ki, то в голых байтах,
# и «3258002390» в отчёте читателю ничего не говорит.
human_bytes() {
  python3 - "$1" <<'PY' 2>/dev/null
import sys, re
v = sys.argv[1].strip()
m = re.fullmatch(r'(\d+(?:\.\d+)?)(Ki|Mi|Gi|Ti|K|M|G|T)?', v)
if not m:
    print(v); raise SystemExit
n = float(m.group(1))
mult = {'Ki':1024,'Mi':1024**2,'Gi':1024**3,'Ti':1024**4,
        'K':1000,'M':1000**2,'G':1000**3,'T':1000**4}.get(m.group(2), 1)
b = n * mult
for unit, size in (('Gi',1024**3), ('Mi',1024**2), ('Ki',1024)):
    if b >= size:
        print(f"{b/size:.1f}{unit}"); break
else:
    print(f"{int(b)}B")
PY
}

# Выполнить команду в одноразовом поде и вернуть её вывод.
# Нужно там, где проверяется доступность сервиса изнутри кластера: с ноутбука
# ClusterIP не виден. Под удаляется за собой в любом случае.
in_cluster_curl() {
  local url="$1" extra="${2:-}"
  local name="check-$$-$RANDOM"
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 --command -- \
    curl -s --max-time 10 $extra "$url" 2>/dev/null
}
