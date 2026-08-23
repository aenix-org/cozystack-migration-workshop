#!/usr/bin/env bash
# Проверка лабы 13: чарт и описание приложения готовы к передаче админу.
#
# Эта проверка НАМЕРЕННО локальная. Применить ApplicationDefinition тенант не
# может (объект cluster-scoped), поэтому искать его в кластере бессмысленно:
# отсутствие объекта — не ошибка участника. Проверяем то, за что он отвечает:
# чарт собирается, схема работает, определение разобрано и согласовано с чартом.
#
# Запуск из папки лабы:
#   cd labs/13-catalog && ./check.sh
# Кластер не обязателен: без KUBECONFIG две проверки будут пропущены с предупреждением,
# а не с ошибкой.

LAB_NAME="13-catalog"
LAB_TITLE="Лаба 13 · Своё приложение в каталоге Cozystack"
. "$(cd "$(dirname "$0")/../../check" && pwd)/lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$HERE/chart"
APPDEF="$HERE/applicationdefinition.yaml"

# --- инструменты -----------------------------------------------------------
# Без helm проверять нечего, поэтому здесь скрипт останавливается сразу и не сыплет
# десятком одинаковых отказов дальше по тексту.
if ! command -v helm >/dev/null 2>&1; then
  fail "на машине нет helm" \
       "поставьте: brew install helm (macOS) или https://helm.sh/docs/intro/install/ — без него лаба не проверяется"
  finish
  exit $?
fi
HELM_VER="$(helm version --short 2>/dev/null)"
ok "helm на месте (${HELM_VER})"
evidence "Версия helm" "$HELM_VER"

# --- чарт на месте ---------------------------------------------------------
# Отличаем «чарт сломан» от «скрипт запущен не из той папки». Вторая ошибка встречается
# чаще первой, и сообщение про неё должно быть отдельным.
if [ ! -f "$CHART/Chart.yaml" ]; then
  fail "не найден чарт в ${CHART}" \
       "запускайте скрипт из папки лабы: cd labs/13-catalog && ./check.sh"
  finish
  exit $?
fi

# --- линтер ----------------------------------------------------------------
# helm lint читает чарт как текст: находит опечатки в шаблонах, недостающие поля
# Chart.yaml, ссылки на несуществующие значения. До кластера дело здесь не доходит.
LINT_OUT="$(helm lint "$CHART" 2>&1)"
if printf '%s' "$LINT_OUT" | grep -q '0 chart(s) failed'; then
  ok "чарт проходит helm lint"
  evidence "helm lint" "$LINT_OUT"
else
  fail "чарт не проходит helm lint" \
       "прочитайте вывод ниже и почините указанные файлы: helm lint chart"
  evidence "helm lint" "$LINT_OUT"
fi

# --- рендер ----------------------------------------------------------------
# Пустой вывод и вывод из одних комментариев линтер бы пропустил, поэтому смотрим,
# что среди отрендеренного есть Deployment, и перечисляем, что вообще получилось.
# Главное здесь не «команда отработала», а «получились настоящие объекты».
RENDER="$(helm template main "$CHART" 2>&1)"
if printf '%s' "$RENDER" | grep -q '^kind: Deployment'; then
  KINDS="$(printf '%s' "$RENDER" | grep '^kind:' | awk '{print $2}' | sort -u | tr '\n' ' ')"
  ok "чарт рендерится, получаются объекты: ${KINDS}"
  evidence "Что рендерит чарт" "$KINDS"
else
  fail "helm template не выдал ни одного Deployment" \
       "смотрите ошибку рендера: helm template main chart"
  evidence "Вывод helm template" "$(printf '%s' "$RENDER" | head -30)"
fi

# --- чарт принимается настоящим кластером ----------------------------------
# Единственная проверка во всём наборе лаб, которая сверяет манифест с настоящей схемой
# кластера, а не с текстом.
#
# `helm lint` и `helm template` проверяют шаблоны, но НЕ схему Kubernetes: манифест
# с полем в неположенном месте они пропускают, а кластер отвергает. Проверено на своей
# шкуре — securityContext, по ошибке вставленный в volumes, прошёл оба и развалился
# только на сервере. Проверка нужна там, где чарт применяют.
#
# Почему lint и template её не заменяют:
#   helm lint      смотрит на устройство чарта: файлы на месте, шаблоны разбираются;
#   helm template  подставляет значения и выдаёт текст — но что это за поля и бывают ли
#                  они у такого объекта, он не знает и знать не может;
#   apply --dry-run=server отправляет манифест в apiserver, тот прогоняет его через схему
#                  типа и через admission-контроль и отвечает, принял бы или нет, ничего
#                  при этом не создавая. Отсюда `unknown field` и отказ по политике —
#                  ровно то, обо что чарт спотыкается у заказчика.
# Флаг --dry-run=client такой проверки не даёт: он разбирает манифест на вашей машине.
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  DRY="$(printf '%s' "$RENDER" | kubectl apply --dry-run=server -f - 2>&1)"
  if printf '%s' "$DRY" | grep -qiE 'error|unknown field|invalid'; then
    fail "кластер отвергает отрендеренный чарт" \
         "смотрите: helm template main chart | kubectl apply --dry-run=server -f -"
    evidence "Отказ сервера" "$(printf '%s' "$DRY" | grep -iE 'error|unknown field' | head -5)"
  else
    ok "кластер принимает отрендеренный чарт — поля и их места верны"
  fi
else
  warn "проверка чарта на кластере пропущена: нет доступа" \
       "задайте KUBECONFIG, чтобы прогнать helm template через kubectl apply --dry-run=server"
fi

# --- параметры действительно доходят до манифестов -------------------------
# Чарт может собираться и рендериться, а параметр при этом никуда не подставляться —
# например, значение записали в шаблон числом. Поэтому каждый параметр проверяем делом:
# задаём заведомо необычное значение и ищем его в готовом манифесте.
R5="$(helm template main "$CHART" --set replicas=5 2>/dev/null | grep -c 'replicas: 5')"
if [ "${R5:-0}" -ge 1 ]; then
  ok "параметр replicas доходит до манифеста (--set replicas=5 даёт replicas: 5)"
else
  fail "параметр replicas не доходит до манифеста" \
       "в templates/deployment.yaml должно стоять replicas: {{ .Values.replicas }}"
fi

EXT="$(helm template main "$CHART" --set external=true 2>/dev/null | grep -c 'type: LoadBalancer')"
if [ "${EXT:-0}" -ge 1 ]; then
  ok "параметр external переключает тип Service на LoadBalancer"
else
  warn "параметр external не переключает тип Service" \
       "не поломка чарта, но соглашение каталога Cozystack: поле external у приложений означает именно внешний доступ"
fi

# --- схема действительно защищает ------------------------------------------
# Схема, которая ничего не отвергает, бесполезна. Проверяем, что она отвергает.
if helm template main "$CHART" --set replicas=abc >/dev/null 2>&1; then
  fail "схема значений не отвергает заведомо неверное значение (replicas=abc прошло)" \
       "проверьте, что рядом с values.yaml лежит values.schema.json и в нём replicas объявлен как integer"
else
  ok "схема значений отвергает неверный тип (replicas=abc не проходит)"
fi

# --- ApplicationDefinition: обязательные поля ------------------------------
# Применить определение участник не может, значит и отказа apiserver он не увидит.
# Поэтому обязательные поля пересчитываем здесь: без любого из них админ получит отказ
# уже у себя, а разбираться придётся автору файла.
if [ ! -f "$APPDEF" ]; then
  fail "не найден ${APPDEF}" \
       "файл должен лежать рядом с чартом; возьмите его из репозитория лаб"
else
  MISSING=""
  # Ищем ключи построчно, без разбора YAML: PyYAML есть не на каждой машине,
  # а тащить зависимость ради проверки одного файла не стоит.
  check_key() {
    grep -Eq "$1" "$APPDEF" || MISSING="$MISSING $2"
  }
  check_key '^kind:[[:space:]]+ApplicationDefinition[[:space:]]*$' 'kind: ApplicationDefinition'
  check_key '^apiVersion:[[:space:]]+cozystack\.io/v1alpha1[[:space:]]*$' 'apiVersion: cozystack.io/v1alpha1'
  check_key '^[[:space:]]{4}kind:[[:space:]]+\S+' 'application.kind'
  check_key '^[[:space:]]{4}plural:[[:space:]]+\S+' 'application.plural'
  check_key '^[[:space:]]{4}singular:[[:space:]]+\S+' 'application.singular'
  check_key '^[[:space:]]{4}openAPISchema:' 'application.openAPISchema'
  check_key '^[[:space:]]{4}prefix:[[:space:]]+\S+' 'release.prefix'
  check_key '^[[:space:]]{6}kind:[[:space:]]+(OCIRepository|HelmChart|ExternalArtifact)' 'release.chartRef.kind'
  check_key '^[[:space:]]{4}category:[[:space:]]+\S+' 'dashboard.category'
  check_key '^[[:space:]]{4}icon:[[:space:]]+\S+' 'dashboard.icon'

  if [ -z "$MISSING" ]; then
    ok "в ApplicationDefinition на месте все обязательные поля"
  else
    fail "в ApplicationDefinition не хватает полей:${MISSING}" \
         "сверьтесь с разбором в README — без любого из них админ получит отказ при применении"
  fi

  # --- схема в определении разбирается и совпадает со схемой чарта ---------
  # Это две разные копии одного и того же, и связи между ними нет никакой.
  # Разъехались — форма в дашборде покажет не те поля, что ждёт чарт.
  SCHEMA_LINE="$(awk '/openAPISchema:/{getline; sub(/^[[:space:]]+/,""); print; exit}' "$APPDEF")"
  if [ -z "$SCHEMA_LINE" ]; then
    fail "в ApplicationDefinition пустой openAPISchema" \
         "вставьте туда содержимое chart/values.schema.json одной строкой"
  else
    CMP="$(SCHEMA_LINE="$SCHEMA_LINE" python3 - "$CHART/values.schema.json" <<'PY' 2>&1
import os, sys, json
try:
    inline = json.loads(os.environ["SCHEMA_LINE"])
except Exception as e:
    print("BADJSON %s" % e); raise SystemExit
try:
    chart = json.load(open(sys.argv[1]))
except Exception as e:
    print("NOCHART %s" % e); raise SystemExit
a = sorted((inline.get("properties") or {}).keys())
b = sorted((chart.get("properties") or {}).keys())
if a == b:
    print("SAME %s" % ",".join(a))
else:
    only_def = sorted(set(a) - set(b))
    only_chart = sorted(set(b) - set(a))
    print("DIFF только в определении: %s | только в чарте: %s"
          % (",".join(only_def) or "-", ",".join(only_chart) or "-"))
PY
)"
    case "$CMP" in
      SAME*)
        ok "схема в определении разбирается и совпадает со схемой чарта (${CMP#SAME })"
        evidence "Параметры приложения" "${CMP#SAME }"
        ;;
      DIFF*)
        fail "схема в определении разошлась со схемой чарта: ${CMP#DIFF }" \
             "приведите их в соответствие: содержимое openAPISchema — это chart/values.schema.json одной строкой"
        ;;
      BADJSON*)
        fail "openAPISchema не разбирается как JSON: ${CMP#BADJSON }" \
             "схема должна быть одной строкой корректного JSON под 'openAPISchema: |-'"
        ;;
      *)
        warn "не удалось сверить схемы (${CMP})" \
             "проверьте руками, что openAPISchema совпадает с chart/values.schema.json"
        ;;
    esac
  fi

  # --- иконка ---------------------------------------------------------------
  # Дашборд ждёт SVG, уложенный в base64, и никуда за картинкой не ходит. Ошибка здесь
  # тихая: манифест применится, а в каталоге на месте иконки будет пусто. Поэтому строку
  # раскодируем и смотрим, что внутри действительно SVG.
  ICON="$(grep -Eo '^[[:space:]]{4}icon:[[:space:]]+\S+' "$APPDEF" | head -1 | awk '{print $2}')"
  if [ -n "$ICON" ]; then
    ICON_HEAD="$(printf '%s' "$ICON" | python3 -c 'import sys,base64
try:
    print(base64.b64decode(sys.stdin.read().strip()).decode("utf-8","replace")[:40])
except Exception:
    print("")' 2>/dev/null)"
    case "$ICON_HEAD" in
      *"<svg"*)
        ok "иконка раскодируется из base64 и оказывается SVG"
        evidence "Начало иконки" "$ICON_HEAD"
        ;;
      "")
        fail "иконка не раскодируется из base64" \
             "пересоберите строку: base64 -i icon.svg | tr -d '\\n' (на Linux: base64 -w0 icon.svg)"
        ;;
      *)
        fail "иконка раскодируется, но это не SVG" \
             "дашборд ждёт именно SVG; растровую картинку он покажет как мусор"
        ;;
    esac
  fi
fi

# --- права: отказ здесь ожидаем --------------------------------------------
# Это не проверка участника, а подтверждение устройства платформы. Поэтому
# ответ `no` — успех, а `yes` — повод удивиться, а не радоваться.
if [ -n "${KUBECONFIG:-}" ] && kubectl version -o json >/dev/null 2>&1; then
  CANI="$(kubectl auth can-i create applicationdefinitions 2>/dev/null)"
  case "$CANI" in
    no)
      ok "подтверждено: применять ApplicationDefinition вам не положено (can-i -> no)"
      evidence "Права на ApplicationDefinition" \
        "kubectl auth can-i create applicationdefinitions -> no
Объект cluster-scoped и меняет каталог для всех тенантов, поэтому его применяет админ платформы."
      ;;
    yes)
      warn "у вас есть права применять ApplicationDefinition (can-i -> yes)" \
           "значит, вы работаете под админской учёткой, а не под тенантной; лаба рассчитана на тенантную"
      ;;
    *)
      warn "не удалось спросить кластер о правах" \
           "не мешает сдаче лабы: проверка локальная, кластер здесь не нужен"
      ;;
  esac
else
  warn "кластер не опрошен (KUBECONFIG не задан или не отвечает)" \
       "это нормально: лаба проверяется локально. Чтобы увидеть отказ в правах: export KUBECONFIG=~/.kube/workshop"
fi

finish
