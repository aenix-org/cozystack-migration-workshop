# Установка инструментов

Ставится один раз, до воркшопа. Если всё уже стоит и `kubectl get nodes` отвечает —
этот файл вам не нужен.

Всё ставится на ваш ноутбук, один раз, до начала воркшопа. Утилиты три.

| Утилита | Зачем нужна | Откуда берётся |
|---|---|---|
| `kubectl` | Основная команда: применяет файлы, показывает, что в кластере | Пакетный менеджер вашей системы |
| `virtctl` | Работа с виртуальными машинами: консоль, проброс порта | Один файл с релизов KubeVirt |
| `kubelogin` | Логин через браузер: без него кластер вас не пустит | Один файл с релизов kubelogin |

**«Один файл» — это буквально.** `virtctl` и `kubelogin` написаны на Go и представляют
собой один исполняемый файл без зависимостей. Установка сводится к тому, чтобы скачать
его и положить в папку, где система ищет команды. Ни установщика, ни прав
администратора (кроме записи в системную папку на macOS и Linux), ни удаления потом —
достаточно стереть файл.

**Зачем `kubelogin` отдельно.** Доступ к кластеру выдан не по сертификату, а через
Keycloak — это сервер входа, тот же механизм, что и «войти через корпоративный аккаунт»
в любом внутреннем сервисе. При первом обращении к кластеру `kubectl` вызовет
`kubelogin`, тот откроет браузер, вы залогинитесь как `workshopXX`, и полученный пропуск
будет использоваться дальше. Без этой утилиты `kubectl` просто не поймёт, как логиниться.

⚠️ **Не ставьте krew ради этого воркшопа.** krew — менеджер дополнений для `kubectl`, и
через него те же две утилиты тоже ставятся, но на прошлых воркшопах именно он съел
больше всего времени. На Windows он обычно вообще не работает: падает с `A required
privilege is not held by the client`, потому что создаёт символьные ссылки, а это
требует «Режима разработчика» или прав администратора — на корпоративных ноутбуках
закрыто. На macOS и Linux он работает, но добавляет ещё один шаг, который может
сломаться, а выигрыша не даёт: файлов всё равно два.

Если krew у вас уже стоит и вы им пользуетесь — `kubectl krew install virt` и
`kubectl krew install oidc-login` сделают то же самое. Если не стоит — не начинайте
сегодня.

Дальше — по системам. Найдите свою и пропустите остальные.

### Установка: Windows

Все команды — в **PowerShell**, права администратора не нужны. Утилиты кладём в
`$HOME\bin` — это папка `C:\Users\Вы\bin`.

**1. kubectl** — через встроенный в Windows менеджер пакетов:

```powershell
winget install -e --id Kubernetes.kubectl
```

Если `winget` не распознан — он есть не во всех сборках Windows. Тогда качайте файл
вручную со страницы https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/
и кладите в ту же `$HOME\bin` из следующего шага.

**2. Создаём папку для утилит и добавляем её в PATH.** PATH — список папок, где система
ищет команды; без этого шага Windows не найдёт скачанные файлы:

```powershell
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
[Environment]::SetEnvironmentVariable("PATH", "$env:PATH;$HOME\bin", "User")
```

**3. virtctl** — узнаём номер последнего выпуска KubeVirt и качаем файл под него:

```powershell
$ver = (Invoke-RestMethod https://api.github.com/repos/kubevirt/kubevirt/releases/latest).tag_name
Invoke-WebRequest -Uri "https://github.com/kubevirt/kubevirt/releases/download/$ver/virtctl-$ver-windows-amd64.exe" -OutFile "$HOME\bin\virtctl.exe"
```

**4. kubelogin** — скачиваем архив, распаковываем, переименовываем:

```powershell
Invoke-WebRequest -Uri "https://github.com/int128/kubelogin/releases/latest/download/kubelogin_windows_amd64.zip" -OutFile "$HOME\kubelogin.zip"
Expand-Archive -Force "$HOME\kubelogin.zip" "$HOME\kl"
Move-Item -Force "$HOME\kl\kubelogin.exe" "$HOME\bin\kubectl-oidc_login.exe"
Remove-Item -Recurse -Force "$HOME\kubelogin.zip","$HOME\kl"
```

⚠️ **Имя файла обязано быть `kubectl-oidc_login.exe`**, а не `kubelogin.exe`. `kubectl`
находит свои дополнения по имени: всё, что называется `kubectl-<что-то>`, становится
командой `kubectl <что-то>`. Переименуете иначе — логин не заработает, а сообщение об
ошибке будет говорить совсем о другом.

**5. Откройте новое окно PowerShell** — старое про изменившийся PATH не знает — и
переходите к проверке ниже.

### Установка: macOS

**1. kubectl и kubelogin** — через Homebrew:

```bash
brew install kubectl
brew install int128/kubelogin/kubelogin
```

Формула kubelogin сама создаёт второй файл с нужным именем `kubectl-oidc_login`,
переименовывать ничего не надо.

**2. virtctl** — одним файлом с релизов KubeVirt. Команда сама определит номер выпуска
и тип процессора (Apple Silicon или Intel):

```bash
# tag_name — номер последнего выпуска, вытаскиваем его из ответа GitHub
VER=$(curl -sL https://api.github.com/repos/kubevirt/kubevirt/releases/latest \
      | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
# uname -m покажет arm64 на Apple Silicon и x86_64 на Intel
ARCH=$([ "$(uname -m)" = "arm64" ] && echo arm64 || echo amd64)
# /usr/local/bin — системная папка для команд, поэтому sudo
sudo curl -sL -o /usr/local/bin/virtctl \
  "https://github.com/kubevirt/kubevirt/releases/download/$VER/virtctl-$VER-darwin-$ARCH"
sudo chmod +x /usr/local/bin/virtctl   # разрешаем файлу запускаться
```

⚠️ **При первом запуске macOS может отказаться открывать файл** — скачан из интернета и
не подписан. Системные настройки → «Конфиденциальность и безопасность» → внизу кнопка
«Всё равно открыть». Либо снимите пометку заранее:
`sudo xattr -d com.apple.quarantine /usr/local/bin/virtctl`.

### Установка: Linux

**1. kubectl** — по официальной инструкции для вашего дистрибутива:
https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/ (в Ubuntu и Debian это
подключение репозитория и `apt install kubectl`, в Fedora — `dnf install kubernetes-client`).

**2. virtctl:**

```bash
VER=$(curl -sL https://api.github.com/repos/kubevirt/kubevirt/releases/latest \
      | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
sudo curl -sL -o /usr/local/bin/virtctl \
  "https://github.com/kubevirt/kubevirt/releases/download/$VER/virtctl-$VER-linux-amd64"
sudo chmod +x /usr/local/bin/virtctl
```

**3. kubelogin** — архив, распаковка, установка под нужным именем:

```bash
curl -sL -o /tmp/kubelogin.zip \
  https://github.com/int128/kubelogin/releases/latest/download/kubelogin_linux_amd64.zip
unzip -o /tmp/kubelogin.zip -d /tmp/kubelogin
# install кладёт файл на место и сразу выставляет права на запуск.
# Имя обязано быть kubectl-oidc_login — по нему kubectl находит дополнение.
sudo install -m 0755 /tmp/kubelogin/kubelogin /usr/local/bin/kubectl-oidc_login
```

### Проверяем, что всё встало

Одинаково на всех системах. Каждая команда должна напечатать версию или справку, а не
«команда не найдена»:

```bash
kubectl version --client     # версия kubectl, без обращения к кластеру
virtctl version --client     # версия virtctl
kubectl oidc-login --help    # справка; работает только если имя файла правильное
```

Третья команда — заодно проверка того, что дополнение подхватилось. Если она отвечает
`unknown command "oidc-login"`, значит файл лежит не в той папке или назван не так.

### Подключаемся к кластеру

Kubeconfig — файл с адресом кластера и данными для входа. Вы берёте его в дашборде:
`Info` → вкладка `Secrets` → секрет `kubeconfig-tenant-workshopXX`. Дальше его нужно
сохранить на диск и показать `kubectl`, где он лежит, — через переменную `KUBECONFIG`.

**macOS и Linux:**

```bash
# Сохраните содержимое секрета в ~/.kube/workshop любым редактором, затем:
export KUBECONFIG=~/.kube/workshop    # говорим kubectl, какой файл использовать
kubectl config current-context        # покажет имя кластера — значит файл прочитан
kubectl get vminstance -n tenant-workshopXX   # первое обращение: откроется браузер
```

`export` действует до закрытия окна терминала. Чтобы не повторять — допишите ту же
строку в `~/.zshrc` (macOS) или `~/.bashrc` (Linux).

**Windows (PowerShell)** — переменную задаём и на текущее окно, и на будущие:

```powershell
New-Item -ItemType Directory -Force "$HOME\.kube" | Out-Null
# Откроется Блокнот — вставьте туда kubeconfig и сохраните.
# При сохранении тип файла обязательно "Все файлы", иначе Блокнот допишет .txt
notepad "$HOME\.kube\workshop"
# "User" — закрепить переменную для всех будущих окон
[Environment]::SetEnvironmentVariable("KUBECONFIG", "$HOME\.kube\workshop", "User")
# ...а эта строка задаёт её в текущем окне, чтобы не перезапускать PowerShell
$env:KUBECONFIG = "$HOME\.kube\workshop"
kubectl get vminstance -n tenant-workshopXX
```

При первом обращении к кластеру откроется браузер — залогиньтесь как `workshopXX`.
Дальше `kubectl` будет работать молча, пока пропуск не истечёт.

⚠️ **`x509: certificate signed by unknown authority`** — вторая частая ошибка на Windows,
и означает она не проблему с сертификатом, а то, что `kubectl` взял **не тот файл доступа**.

Сервер кластера подписан внутренним центром сертификации Kubernetes, а доверие к нему
лежит внутри вашего kubeconfig, в поле `certificate-authority-data`. Если `kubectl`
запущен без `--kubeconfig` и без заданной переменной, он берёт файл по умолчанию — а там
этого поля нет, и доверять серверу нечем.

Разберитесь по шагам, в PowerShell:

```powershell
# 1. Какой файл kubectl вообще использует
$env:KUBECONFIG
# пусто — значит берётся файл по умолчанию, а не тот, что вам выдали

# 2. Есть ли в вашем файле центр сертификации
Select-String -Path "$HOME\.kube\workshop" -Pattern "certificate-authority-data" -Quiet
# False — файл сохранён неполностью, скачайте секрет из дашборда заново

# 3. Не испортилась ли кодировка при сохранении
Get-Content "$HOME\.kube\workshop" -TotalCount 1
# должно начинаться с apiVersion; квадратики или пустота — файл сохранён в UTF-16
```

Третий пункт — самая коварная ловушка Windows. Блокнот и перенаправление `>` в PowerShell
сохраняют файл в UTF-16, и `kubectl` такой файл не прочитает. Сохранять надо так:

```powershell
# при сохранении в Блокноте: тип файла — «Все файлы», кодировка — UTF-8
# при выводе командой — только так, а не через >
kubectl ... | Out-File -Encoding utf8 "$HOME\.kube\workshop"
```

Когда файл на месте, укажите его — и лучше закрепить, чтобы не повторять в каждом окне:

```powershell
$env:KUBECONFIG = "$HOME\.kube\workshop"
[Environment]::SetEnvironmentVariable("KUBECONFIG", "$HOME\.kube\workshop", "User")
```

⚠️ **`dial tcp [::1]:8080 ... refused`** (или `localhost:8080`) — самая частая ошибка на
этом шаге. Означает она не «кластер недоступен», а «kubectl не нашёл kubeconfig и пошёл
искать кластер у вас на ноутбуке». Причина всегда одна: переменная `KUBECONFIG` не
задана в этом окне или указывает не на тот файл. На Windows `$env:KUBECONFIG` живёт
только в текущем окне — поэтому его и закрепляют через `SetEnvironmentVariable(... "User")`.

