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

# Ранние выходы обязаны оставлять отчёт: README советует «приходите в сообщество,
# приложив отчёт скрипта», а раньше при недоступном кластере прикладывать было нечего —
# то есть отчёта не было ровно в том случае, ради которого он и нужен.
need_kubeconfig() {
  if [ -z "${KUBECONFIG:-}" ]; then
    fail "не задана переменная KUBECONFIG" \
         "сначала: export KUBECONFIG=~/lab.kubeconfig (в каждом новом окне терминала)"
    finish; exit 1
  fi
  if ! kubectl version -o json >/dev/null 2>&1; then
    fail "кластер не отвечает по KUBECONFIG=${KUBECONFIG}" \
         "если kubectl get nodes висит без ответа — сервер управления кластером не поднялся; смотрите статус приложения Kubernetes в дашборде и события тенанта на нехватку квоты (exceeded quota)"
    evidence "Файл доступа" "$KUBECONFIG"
    evidence "Ответ кластера" "$(kubectl get nodes 2>&1 | head -5)"
    finish; exit 1
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

# Запустить команду в одноразовом поде, передав секреты через переменные окружения,
# заданные из временного Secret'а, а не аргументами командной строки.
#
# Зачем так. Всё, что попадает в args пода, видно любому, у кого есть `get pods`,
# лежит в etcd, уходит в audit log и светится в `ps` на узле. Лабы про базы данных
# отдельно объясняют, что пароль в командной строке — плохая практика; проверять их
# скриптом, который делает ровно это, было бы двойным стандартом.
#
# Использование:
#   in_cluster_with_secrets "<image>" "KEY1=val1
#   KEY2=val2" sh -c 'команда, читающая $KEY1'
in_cluster_with_secrets() {
  local image="$1" envs="$2"; shift 2
  local name="check-$$-$RANDOM"
  local sec="${name}-env"

  # Secret создаётся из stdin, поэтому значения не попадают в аргументы kubectl.
  local args=()
  while IFS= read -r line; do
    [ -n "$line" ] && args+=(--from-literal="$line")
  done <<EOF
$envs
EOF
  kubectl create secret generic "$sec" "${args[@]}" >/dev/null 2>&1 || return 1

  # securityContext здесь тоже обязателен: без него под не создастся в кластере
  # с профилем `restricted`, и проверки лаб с базами данных не отработают.
  local cmd_json
  cmd_json="$(printf '%s\n' "$@" | python3 -c 'import sys,json;print(json.dumps([l.rstrip("\n") for l in sys.stdin]))')"
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image="$image" --pod-running-timeout=90s \
    --overrides="{\"spec\":{\"securityContext\":{\"runAsNonRoot\":true,\"runAsUser\":65532,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}},\"containers\":[{\"name\":\"$name\",\"image\":\"$image\",\"stdin\":true,\"securityContext\":{\"allowPrivilegeEscalation\":false,\"capabilities\":{\"drop\":[\"ALL\"]}},\"envFrom\":[{\"secretRef\":{\"name\":\"$sec\"}}],\"command\":$cmd_json}]}}" \
    2>/dev/null
  local rc=$?

  kubectl delete secret "$sec" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}

# Собрать override с securityContext, проходящим профиль `restricted`.
# Вынесено отдельно: одна и та же надстройка нужна каждому одноразовому поду,
# а без неё скрипты проверки не работают в строгих кластерах.
# Аргументы команды передаются КАЖДЫЙ ОТДЕЛЬНО, а JSON собирается питоном:
# ручное экранирование кавычек в bash уже приводило к битому override и молчаливому
# отказу пода — ошибку при этом глушил 2>/dev/null.
_restricted_overrides() {
  local name="$1" image="$2"; shift 2
  python3 - "$name" "$image" "$@" <<'PYJSON'
import sys, json
name, image, *cmd = sys.argv[1:]
print(json.dumps({"spec": {
    "securityContext": {"runAsNonRoot": True, "runAsUser": 65532,
                        "seccompProfile": {"type": "RuntimeDefault"}},
    "containers": [{"name": name, "image": image, "stdin": True,
                    "securityContext": {"allowPrivilegeEscalation": False,
                                        "capabilities": {"drop": ["ALL"]}},
                    "command": cmd}]}}))
PYJSON
}

# Выполнить команду в одноразовом поде и вернуть её вывод.
# Нужно там, где проверяется доступность сервиса изнутри кластера: с ноутбука
# ClusterIP не виден. Под удаляется за собой в любом случае.
in_cluster_curl() {
  local url="$1" extra="${2:-}"
  local name="check-$$-$RANDOM"
  # securityContext обязателен: в кластере с профилем `restricted` под без него
  # не создастся, и участник не сможет проверить лабу вообще.
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 --pod-running-timeout=90s \
    --overrides="$(_restricted_overrides "$name" curlimages/curl:8.11.1 \
      curl -s --max-time 10 $extra "$url")" \
    2>/dev/null
  local rc=$?
  # `--rm` удаляет под, только пока клиент приаттачен: обрыв, таймаут или Ctrl+C
  # оставляют его висеть. Явное удаление — чтобы скрипт не мусорил в кластере.
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}

# Собрать ответы от НЕСКОЛЬКИХ запросов подряд, по одному на строку.
#
# Один запрос при нескольких копиях за сервисом — лотерея: посторонний под с той же
# меткой попадает в балансировку, но одиночная выборка может его не задеть, и проверка
# радостно зеленеет на подменённом контенте. Проверено: восемь из двадцати запросов
# уходили самозванцу, а проверка четыре раза подряд говорила «сдана».
in_cluster_curl_many() {
  local url="$1" times="${2:-8}"
  local name="check-$$-$RANDOM"
  kubectl run "$name" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.11.1 --pod-running-timeout=90s \
    --overrides="$(_restricted_overrides "$name" curlimages/curl:8.11.1 \
      sh -c "for i in \$(seq 1 $times); do curl -s --max-time 10 '$url'; echo; done")" \
    2>/dev/null
  local rc=$?
  kubectl delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  return $rc
}
