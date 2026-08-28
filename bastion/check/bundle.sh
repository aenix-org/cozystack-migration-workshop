#!/usr/bin/env bash
# Собирает результаты всех лаб в один файл для загрузки в систему сертификации.
#
# Важное свойство: скрипт НИЧЕГО НЕ ПЕРЕЗАПУСКАЕТ. Он берёт то, что каждая лаба
# записала в момент, когда вы её сдавали. Иначе получилось бы вот что: лабы сами
# велят убирать за собой, а квота тенанта не даёт держать все сервисы неделями —
# и перепроверка в конце показала бы отказ по работе, честно сделанной три недели
# назад.
#
#   ./bundle.sh                 собрать всё, что найдено
#   ./bundle.sh --rerun 07-redis  перепройти одну лабу и обновить её результат
#
set -uo pipefail

RESULTS_DIR="${COZY_LAB_RESULTS:-$HOME/.cozystack-labs/results}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${1:-$HOME/cozystack-labs-bundle.json}"

if [ "${1:-}" = "--rerun" ]; then
  lab="${2:?укажите лабу, например: ./bundle.sh --rerun 07-redis}"
  [ -d "$REPO/labs/$lab" ] || { echo "нет такой лабы: $lab"; exit 1; }
  echo "перепрохожу $lab…"
  ( cd "$REPO/labs/$lab" && ./check.sh )
  echo "результат обновлён, теперь запустите ./bundle.sh без ключей"
  exit 0
fi

if [ ! -d "$RESULTS_DIR" ] || [ -z "$(ls -A "$RESULTS_DIR" 2>/dev/null)" ]; then
  cat <<'MSG'
Результатов не найдено.

Каждая лаба сохраняет свой результат, когда вы запускаете в ней ./check.sh.
Пройдите хотя бы одну и запустите проверку — потом возвращайтесь сюда.

Если вы проходили лабы на другой машине, скопируйте оттуда папку
~/.cozystack-labs/results или укажите путь: COZY_LAB_RESULTS=/путь ./bundle.sh
MSG
  exit 1
fi

python3 - "$RESULTS_DIR" "$OUT" "$REPO" <<'PYEOF'
import json, os, sys, glob, datetime

results_dir, out_path, repo = sys.argv[1], sys.argv[2], sys.argv[3]

# Сколько лаб вообще существует — считаем по наличию скрипта проверки.
# У шестнадцатой ("Что делать в понедельник") скрипта нет: это текстовое
# упражнение, и в зачёт оно не идёт.
all_labs = sorted(
    os.path.basename(os.path.dirname(p))
    for p in glob.glob(os.path.join(repo, "labs", "*", "check.sh"))
)

labs, uids, versions, problems = [], set(), set(), []
for path in sorted(glob.glob(os.path.join(results_dir, "result-*.json"))):
    try:
        with open(path) as fh:
            d = json.load(fh)
    except Exception as exc:
        problems.append(f"{os.path.basename(path)}: не читается ({exc})")
        continue
    if d.get("schema_version") != 1:
        problems.append(f"{os.path.basename(path)}: неизвестная версия формата")
        continue
    labs.append(d)
    if d.get("env", {}).get("cluster_uid"):
        uids.add(d["env"]["cluster_uid"])
    if d.get("env", {}).get("kubernetes_server_version"):
        versions.add(d["env"]["kubernetes_server_version"])

passed = sorted(d["lab"] for d in labs if d["verdict"] == "passed")
failed = sorted(d["lab"] for d in labs if d["verdict"] != "passed")
missing = [l for l in all_labs if l not in {d["lab"] for d in labs}]

bundle = {
    "schema_version": 1,
    "kind": "cozystack-labs-bundle",
    "generated_at": datetime.datetime.now(datetime.timezone.utc)
                      .strftime("%Y-%m-%dT%H:%M:%SZ"),
    "labs_total": len(all_labs),
    "labs_passed": len(passed),
    "cluster_uids": sorted(uids),          # больше одного — проходили на разных кластерах
    "kubernetes_versions": sorted(versions),
    "results": labs,
}
with open(out_path, "w") as fh:
    json.dump(bundle, fh, ensure_ascii=False, indent=1)

# То же самое обычным текстом — чтобы человек видел, что отправляет.
txt = out_path.rsplit(".", 1)[0] + ".txt"
with open(txt, "w") as fh:
    fh.write("Результаты лабораторных Cozystack\n")
    fh.write("Собрано: %s\n\n" % bundle["generated_at"])
    fh.write("Сдано %d из %d лаб\n\n" % (len(passed), len(all_labs)))
    for lab in all_labs:
        rec = next((d for d in labs if d["lab"] == lab), None)
        if rec is None:
            mark, extra = "—", "результата нет"
        elif rec["verdict"] == "passed":
            mark = "сдана"
            extra = "проверок: %d" % len(rec["checks"])
        else:
            mark = "не сдана"
            extra = "провалено: %d" % rec["totals"]["fail"]
        fh.write("  %-20s %-9s %s\n" % (lab, mark, extra))
    fh.write("\nКластеров: %d. Версии Kubernetes: %s\n"
             % (len(uids), ", ".join(sorted(versions)) or "не определены"))
    fh.write("\nВ файл попадают только идентификаторы проверок и их исходы.\n"
             "Ни адресов, ни имён, ни содержимого логов в нём нет.\n")

print("Сдано %d из %d лаб." % (len(passed), len(all_labs)))
if failed:
    print("Не сдано: %s" % ", ".join(failed))
if missing:
    print("Нет результата: %s" % ", ".join(missing))
if len(uids) > 1:
    print("\nВнимание: результаты сняты с %d разных кластеров. Это допустимо, "
          "но при загрузке набор будет помечен." % len(uids))
for p in problems:
    print("  проблема: %s" % p)
print("\nФайл для загрузки: %s" % out_path)
print("Он же обычным текстом:  %s" % txt)
print("Посмотрите текстовый файл перед отправкой — в нём видно всё, что уходит.")
PYEOF
