# Сообщения для чата воркшопа — путь через виртуалку

Один файл — одно сообщение. Отправляйте по ходу практики, не всё сразу.

Этот набор — для участников, которые работают **через общую виртуалку (bastion)**:
инструменты и доступ к кластеру уже на виртуалке, номер тенанта в файлах подставлен
заранее, приложение проверяется по доменному имени. Набор для работы со своего ноутбука —
в [`../../laptop/chat/`](../../laptop/chat/).

Нумерация сообщений сквозная с ноутбучным набором (поэтому в ней есть пропуски: посты про
установку инструментов здесь не нужны).

| № | Сообщение | Файл |
|---|---|---|
| 1 | Что мы вообще делаем | [`01-what-we-are-doing.md`](01-what-we-are-doing.md) |
| 2 | Словарик: как это называется у вас и как здесь | [`02-glossary.md`](02-glossary.md) |
| 3 | Перед началом: что понадобится | [`03-prerequisites.md`](03-prerequisites.md) |
| 8 | Заходим на виртуалку | [`08-connect-to-cluster.md`](08-connect-to-cluster.md) |
| 10 | Материалы уже на виртуалке | [`10-clone-and-set-number.md`](10-clone-and-set-number.md) |
| 11 | Карта файлов: что где лежит и где запускается | [`11-file-map.md`](11-file-map.md) |
| 12 | Фаза 1. Вывозим образ из vSphere | [`12-phase-1-export-image.md`](12-phase-1-export-image.md) |
| 13 | Разбор: что внутри 01-bucket.yaml | [`13-bucket-manifest.md`](13-bucket-manifest.md) |
| 14 | Шаг 1: своё хранилище | [`14-step-1-bucket.md`](14-step-1-bucket.md) |
| 15 | Разбор: что внутри 02-conversion-vm.yaml | [`15-conversion-vm-manifest.md`](15-conversion-vm-manifest.md) |
| 16 | Шаг 2: машина-конвертер | [`16-step-2-conversion-vm.md`](16-step-2-conversion-vm.md) |
| 17 | Разбор: что делает convert.sh | [`17-convert-script.md`](17-convert-script.md) |
| 18 | Шаг 3: конвертация образа | [`18-step-3-convert-image.md`](18-step-3-convert-image.md) |
| 19 | Фаза 2. Заводим машину на новом месте | [`19-phase-2-new-vm.md`](19-phase-2-new-vm.md) |
| 20 | Разбор: что внутри 03-app-vm.yaml | [`20-app-vm-manifest.md`](20-app-vm-manifest.md) |
| 21 | Шаг 4: ваша виртуальная машина | [`21-step-4-your-vm.md`](21-step-4-your-vm.md) |
| 22 | Фаза 3. Выбрасываем зоопарк | [`22-phase-3-managed-services.md`](22-phase-3-managed-services.md) |
| 23 | Разбор: что внутри 04-managed.yaml | [`23-managed-manifest.md`](23-managed-manifest.md) |
| 24 | Шаг 5: база и очередь из каталога | [`24-step-5-database-and-queue.md`](24-step-5-database-and-queue.md) |
| 25 | Шаг 6: чиним сеть внутри машины | [`25-step-6-fix-networking.md`](25-step-6-fix-networking.md) |
| 26 | Первая проверка: пробуем запустить и ловим ошибку | [`26-first-check-fails.md`](26-first-check-fails.md) |
| 27 | Шаг 7: переключаем приложение на управляемые сервисы | [`27-step-7-switch-app.md`](27-step-7-switch-app.md) |
| 28 | Шаг 8: почему приложение всё ещё падает | [`28-step-8-why-it-still-fails.md`](28-step-8-why-it-still-fails.md) |
| 29 | Шаг 8: ставим клиент и накатываем схему | [`29-step-8-apply-schema.md`](29-step-8-apply-schema.md) |
| 30 | Шаг 9: проверяем всю цепочку | [`30-step-9-verify-chain.md`](30-step-9-verify-chain.md) |
| 31 | Если что-то не работает | [`31-troubleshooting.md`](31-troubleshooting.md) |
| 32 | После воркшопа | [`32-after-the-workshop.md`](32-after-the-workshop.md) |
