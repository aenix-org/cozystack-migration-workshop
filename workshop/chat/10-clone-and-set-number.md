## 10. Забираем материалы и подставляем свой номер

**Репозиторий с манифестами**

📍 **Где:** на ноутбуке, в терминале. Складываем в домашнюю папку — так путь будет
одинаковый у всех, и мне проще вам помогать.

**Где открыть терминал:**
• macOS — Spotlight (`Cmd+пробел`), наберите «Терминал»
• Linux — `Ctrl+Alt+T` в большинстве окружений
• Windows — меню «Пуск», наберите «PowerShell»

**Забираем папку с файлами** (три команды, по одной):
```bash
cd ~
git clone https://github.com/aenix-org/cozystack-migration-workshop.git
cd cozystack-migration-workshop/workshop
```
Первая команда переводит вас в домашнюю папку, вторая скачивает туда папку
с материалами, третья заходит внутрь неё. Дальше все команды выполняются **отсюда** —
пути в них написаны относительно этой папки.

**Посмотрите, что скачалось:**
```bash
ls manifests scripts
```
Должны увидеть четыре манифеста и четыре скрипта — те самые, из карты файлов.

**Если закрыли терминал или потерялись** — вернуться всегда одинаково:
```bash
cd ~/cozystack-migration-workshop/workshop
```
На Windows путь тот же: `cd $HOME\cozystack-migration-workshop\workshop`.
Проверить, где вы сейчас: `pwd` (в PowerShell тоже работает).

⚠️ Хвост `/workshop` обязателен. В репозитории рядом с материалами воркшопа лежит папка
`labs` с самостоятельными лабами — если остановиться на уровень выше, команды не найдут
ни `manifests`, ни `scripts`.

**Чем открывать файлы для правки.** Манифесты — обычные текстовые файлы, годится
что угодно:
• в терминале — `nano manifests/03-app-vm.yaml` (сохранить: `Ctrl+O`, `Enter`, выйти: `Ctrl+X`)
• мышкой на macOS — `open -a TextEdit manifests/03-app-vm.yaml`
• мышкой на Windows — `notepad manifests\03-app-vm.yaml`
• если стоит VS Code — `code .` откроет всю папку целиком, это удобнее всего

⚠️ Не открывайте `.yaml` в Word или Google Docs: они подменяют кавычки и дефисы,
после этого файл перестаёт применяться, а ошибка выглядит необъяснимо.

Во всех файлах стоит заглушка `tenant-workshopXX`. Подставьте свой номер сразу и во всё,
иначе манифест уедет не туда. Допустим, ваш логин `workshop03`:

**Linux**
```bash
find manifests scripts -type f -exec sed -i 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

**macOS** (здесь у `sed` другой синтаксис — обратите внимание на пустые кавычки)
```bash
find manifests scripts -type f -exec sed -i '' 's/tenant-workshopXX/tenant-workshop03/g' {} +
```

**Windows** (PowerShell)
```powershell
Get-ChildItem -Recurse manifests,scripts -File | ForEach-Object {
  (Get-Content $_.FullName) -replace 'tenant-workshopXX','tenant-workshop03' | Set-Content $_.FullName
}
```

**Проверяем, что не осталось ни одной заглушки:**
```bash
grep -rn tenant-workshopXX manifests scripts || echo "чисто, можно продолжать"
```

Одно место команда не тронет: в `manifests/03-app-vm.yaml` строка
`url: "ВСТАВЬТЕ_PRESIGNED_URL"`. Эту ссылку вы получите позже, когда сконвертируете образ.
Пока — знайте, что она вас там ждёт.
