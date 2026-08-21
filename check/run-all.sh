#!/usr/bin/env bash
# Прогнать проверки всех лаб подряд и собрать сводный отчёт.
#
# Нужен тем, кто прошёл несколько лаб и хочет одной командой убедиться, что ничего
# не развалилось по дороге, — и нам, чтобы гонять весь набор на стендах.
#
# Использование:
#   export KUBECONFIG=~/lab.kubeconfig
#   export COZY_TENANT=workshop07        # для лаб с managed-сервисами
#   check/run-all.sh                     # все лабы
#   check/run-all.sh 00 01 02            # только выбранные

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date -u '+%Y%m%d-%H%M%S')"
SUMMARY="$ROOT/summary-${STAMP}.md"

if [ "$#" -gt 0 ]; then
  LABS=()
  for a in "$@"; do
    # Принимаем и «03», и «03-scale» — участник наберёт как ему удобнее.
    d="$(find "$ROOT/labs" -maxdepth 1 -type d -name "${a}*" | head -1)"
    [ -n "$d" ] && LABS+=("$d") || echo "лаба '$a' не найдена, пропускаю"
  done
else
  LABS=()
  while IFS= read -r d; do LABS+=("$d"); done < <(find "$ROOT/labs" -maxdepth 1 -mindepth 1 -type d | sort)
fi

echo "# Сводный отчёт по лабораторным" > "$SUMMARY"
echo >> "$SUMMARY"
echo "- Дата: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$SUMMARY"
[ -n "${COZY_TENANT:-}" ] && echo "- Тенант: \`${COZY_TENANT}\`" >> "$SUMMARY"
echo >> "$SUMMARY"
echo "| Лаба | Итог | Прошло | Провалено |" >> "$SUMMARY"
echo "|---|---|---|---|" >> "$SUMMARY"

total_fail=0
for d in "${LABS[@]}"; do
  name="$(basename "$d")"
  [ -x "$d/check.sh" ] || { echo "$name: нет check.sh, пропускаю"; continue; }

  printf '\n\033[1m=== %s ===\033[0m\n' "$name"
  out="$(cd "$d" && ./check.sh 2>&1)"
  rc=$?
  printf '%s\n' "$out"

  # Числа берём из строки итога, которую печатает finish().
  line="$(printf '%s' "$out" | grep -m1 'проверок:')"
  passed="$(printf '%s' "$line" | sed -n 's/.*прошло: \([0-9]*\).*/\1/p')"
  failed="$(printf '%s' "$line" | sed -n 's/.*провалено: \([0-9]*\).*/\1/p')"

  if [ "$rc" -eq 0 ]; then
    verdict="сдана"
  else
    verdict="**есть незакрытые**"
    total_fail=$((total_fail + 1))
  fi
  echo "| $name | $verdict | ${passed:-?} | ${failed:-?} |" >> "$SUMMARY"
done

{
  echo
  if [ "$total_fail" -eq 0 ]; then
    echo "**Все проверенные лабы сданы.**"
  else
    echo "**Лаб с незакрытыми пунктами: ${total_fail}.** Подробности — в отчётах"
    echo "\`report-*.md\` внутри папок соответствующих лаб."
  fi
} >> "$SUMMARY"

printf '\n\033[1mсводка: %s\033[0m\n' "$SUMMARY"
[ "$total_fail" -eq 0 ] && exit 0 || exit 1
