# Сообщения для чата воркшопа

Каждый блок — отдельное сообщение. Отправляйте перед соответствующей частью практики,
не всё сразу: иначе народ убежит вперёд и застрянет там, где вы ещё не рассказали, зачем это.

Везде, где встречается `workshopXX`, участник подставляет свой номер: `workshop03`,
`workshop07` и так далее. Номер я выдам лично каждому вместе с паролем.

---

## 1 · Перед началом: что понадобится

**Готовимся к работе**

Управлять кластером будем с ваших ноутбуков. Нужны четыре утилиты — поставим их прямо
сейчас, дальше они пригодятся на каждом шаге.

• `kubectl` — основной инструмент. Через него создаём виртуальные машины, диски, базы.
• `virtctl` — всё, что касается виртуалок: консоль, SSH, проброс порта.
• `kubelogin` — вход по вашей учётной записи через браузер.
• `git` — им заберём папку с готовыми файлами воркшопа.

Следующими сообщениями — команды под каждую операционную систему.
Ставьте, потом отпишитесь в чат, если что-то не встало.

---

## 2 · Ставим kubectl

**kubectl — под вашу систему**

**macOS**
```bash
brew install kubectl
```
Без Homebrew:
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/darwin/arm64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```
На компьютерах с процессором Intel замените `arm64` на `amd64`.

**Linux**
```bash
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
```

**Windows** (PowerShell)
```powershell
winget install -e --id Kubernetes.kubectl
```
После установки закройте и откройте PowerShell заново, иначе команда не найдётся.

⚠️ **Если Windows ответила «Имя "winget" не распознано»** — значит, в вашей сборке нет
«Установщика приложений», такое бывает на Windows 10. Ничего страшного, ставим напрямую.
Копируйте блок целиком:
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ver = (Invoke-WebRequest -UseBasicParsing https://dl.k8s.io/release/stable.txt).Content.Trim()
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri "https://dl.k8s.io/release/$ver/bin/windows/amd64/kubectl.exe" -OutFile "$HOME\bin\kubectl.exe"
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\bin", "User")
```
Затем обязательно закройте окно PowerShell и откройте новое.

Эта же папка `$HOME\bin` пригодится дальше — в неё лягут virtctl и kubelogin,
и в PATH она уже добавлена.

**Проверка — везде одинаковая:**
```
kubectl version --client
```

---

## 3 · Ставим virtctl

**virtctl — управление виртуалками**

Копируйте блок целиком под свою систему. Ничего выбирать и скачивать руками не нужно:
команда сама определит версию и архитектуру.

**macOS**
```bash
VER=$(curl -s https://api.github.com/repos/kubevirt/kubevirt/releases/latest | grep '"tag_name"' | cut -d '"' -f 4)
ARCH=$([ "$(uname -m)" = "arm64" ] && echo arm64 || echo amd64)
curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VER}/virtctl-${VER}-darwin-${ARCH}"
chmod +x virtctl
sudo mv virtctl /usr/local/bin/
```
Если macOS ругается «не удалось проверить разработчика»:
```bash
sudo xattr -d com.apple.quarantine /usr/local/bin/virtctl
```

**Linux**
```bash
VER=$(curl -s https://api.github.com/repos/kubevirt/kubevirt/releases/latest | grep '"tag_name"' | cut -d '"' -f 4)
ARCH=$([ "$(uname -m)" = "aarch64" ] && echo arm64 || echo amd64)
curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VER}/virtctl-${VER}-linux-${ARCH}"
chmod +x virtctl
sudo mv virtctl /usr/local/bin/
```

**Windows** (PowerShell, запускать от обычного пользователя)
```powershell
$ver = (Invoke-RestMethod https://api.github.com/repos/kubevirt/kubevirt/releases/latest).tag_name
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -Uri "https://github.com/kubevirt/kubevirt/releases/download/$ver/virtctl-$ver-windows-amd64.exe" -OutFile "$HOME\bin\virtctl.exe"
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\bin", "User")
```
После этого **закройте окно PowerShell и откройте новое** — иначе новый PATH не подхватится.

**Проверяем (везде одинаково):**
```
virtctl version
```
Должна появиться строчка `Client Version:` с номером. Ругань на отсутствие связи
с сервером на этом шаге нормальна — мы к нему ещё не подключались.

⚠️ **Одно правило на все команды virtctl.** Машину всегда называем с приставкой `vmi/`:
`vmi/vm-instance-app-1`, а не просто `vm-instance-app-1`. Без неё virtctl отвечает
`target must contain type and name separated by '/'`. Причина в правах: под учётной
записью участника доступ выдан на запущенные экземпляры машин, а не на их описания,
поэтому тип надо указывать явно.

---

## 4 · Ставим kubelogin

**kubelogin — вход по учётной записи**

Без него `kubectl` не сможет открыть браузер для логина и будет отвечать ошибкой
авторизации. Файл обязательно должен называться `kubectl-oidc_login` — под этим именем
kubectl находит его как плагин.

**macOS**
```bash
brew install int128/kubelogin/kubelogin
```
Без Homebrew:
```bash
ARCH=$([ "$(uname -m)" = "arm64" ] && echo arm64 || echo amd64)
curl -L -o kubelogin.zip "https://github.com/int128/kubelogin/releases/latest/download/kubelogin_darwin_${ARCH}.zip"
unzip -o kubelogin.zip kubelogin
chmod +x kubelogin
sudo mv kubelogin /usr/local/bin/kubectl-oidc_login
rm kubelogin.zip
```

**Linux**
```bash
ARCH=$([ "$(uname -m)" = "aarch64" ] && echo arm64 || echo amd64)
curl -L -o kubelogin.zip "https://github.com/int128/kubelogin/releases/latest/download/kubelogin_linux_${ARCH}.zip"
unzip -o kubelogin.zip kubelogin
chmod +x kubelogin
sudo mv kubelogin /usr/local/bin/kubectl-oidc_login
rm kubelogin.zip
```

**Windows** (PowerShell)
```powershell
New-Item -ItemType Directory -Force "$HOME\bin" | Out-Null
Invoke-WebRequest -Uri "https://github.com/int128/kubelogin/releases/latest/download/kubelogin_windows_amd64.zip" -OutFile "$HOME\kubelogin.zip"
Expand-Archive -Force "$HOME\kubelogin.zip" "$HOME\kubelogin-tmp"
Move-Item -Force "$HOME\kubelogin-tmp\kubelogin.exe" "$HOME\bin\kubectl-oidc_login.exe"
Remove-Item -Recurse -Force "$HOME\kubelogin.zip","$HOME\kubelogin-tmp"
```
(папка `$HOME\bin` уже создана и добавлена в PATH на прошлом шаге)

**Проверяем:**
```
kubectl oidc-login --help
```
Если вывелась справка — плагин на месте и kubectl его видит.

---

## 4a · Необязательно: то же самое через krew

**Для тех, кто предпочитает менеджер плагинов**

Если предыдущие два шага уже сделаны — этот пропускайте, он ставит то же самое другим
способом. Смысл krew в том, что дальше плагины обновляются одной командой.

**macOS и Linux** — копируйте блок целиком, он сам определит систему:
```bash
set -x; cd "$(mktemp -d)" &&
OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64$/arm64/')" &&
curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew-${OS}_${ARCH}.tar.gz" &&
tar zxvf "krew-${OS}_${ARCH}.tar.gz" &&
./"krew-${OS}_${ARCH}" install krew
```
Затем добавьте krew в PATH — строчку надо дописать в свой профиль, иначе она забудется
при следующем запуске терминала:
```bash
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.zshrc   # для zsh, это по умолчанию в macOS
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> ~/.bashrc  # для bash, обычно Linux
source ~/.zshrc    # или source ~/.bashrc
```

**Windows** (PowerShell)
```powershell
Invoke-WebRequest -Uri "https://github.com/kubernetes-sigs/krew/releases/latest/download/krew.exe" -OutFile "$HOME\krew.exe"
& "$HOME\krew.exe" install krew
$old = [Environment]::GetEnvironmentVariable("Path","User")
[Environment]::SetEnvironmentVariable("Path", "$old;$HOME\.krew\bin", "User")
Remove-Item "$HOME\krew.exe"
```
Снова закройте и откройте PowerShell.

**Ставим плагины:**
```bash
kubectl krew install virt
kubectl krew install oidc-login
```

⚠️ Важное отличие: при установке через krew команда называется иначе —
`kubectl virt console …` вместо `virtctl console …`. Дальше в инструкциях я пишу
`virtctl` — если ставили через krew, мысленно подставляйте `kubectl virt`.
Чтобы не путаться, можно сделать короткий псевдоним:
```bash
alias virtctl="kubectl virt"
```

---

## 5 · Заходим в кластер

**Подключаемся к своему тенанту**

📍 **Где:** дашборд открываем в браузере, команды выполняем на ноутбуке.

1. Откройте дашборд: **https://dashboard.workshop.aenix.io**
2. Логин — `workshopXX`, пароль скажу голосом.
3. В дашборде: **Info → вкладка Secrets → `kubeconfig-tenant-workshopXX`**. Нажмите *Reveal*,
   скопируйте содержимое.
4. Сохраните в файл и укажите на него переменную:

**macOS и Linux**
```bash
mkdir -p ~/.kube
nano ~/.kube/workshop      # вставьте скопированное, сохраните
export KUBECONFIG=~/.kube/workshop
```

**Windows** (PowerShell)
```powershell
notepad $HOME\.kube\workshop   # вставьте, сохраните
$env:KUBECONFIG = "$HOME\.kube\workshop"
```

**Проверяем:**
```
kubectl get vminstance -n tenant-workshopXX
```
Откроется браузер — залогиньтесь как `workshopXX`. После этого команда должна ответить
`No resources found`. Это правильный ответ: машин пока нет, но кластер вас узнал.

⚠️ Две вещи, на которых спотыкаются чаще всего:
• `KUBECONFIG` должен указывать ровно на тот файл, куда вы вставили конфиг.
• `kubectl get vm` и `kubectl get vmi` работать не будут — под вашей учётной записью
  доступен `vminstance`. Так и задумано.

---

## 5a · Ставим git

**Последний инструмент — им заберём материалы**

📍 **Где:** на ноутбуке.

Сначала проверьте, вдруг он уже есть — на macOS и в большинстве сборок Linux git стоит
из коробки:
```
git --version
```
Если ответила версия — пропускайте это сообщение.

**macOS.** Проще всего дождаться системного окошка: наберите `git --version`, и если
git не установлен, macOS сама предложит поставить инструменты разработчика. Соглашайтесь.
Либо явно:
```bash
xcode-select --install
```
С Homebrew:
```bash
brew install git
```

**Linux** — зависит от семейства дистрибутива:
```bash
sudo apt-get update && sudo apt-get install -y git    # Debian, Ubuntu
sudo dnf install -y git                               # Fedora, RHEL, CentOS Stream
```

**Windows** (PowerShell):
```powershell
winget install -e --id Git.Git
```
Затем закройте и откройте PowerShell заново, иначе команда не найдётся.

⚠️ **Если `winget` не найден** — git ставится обычным установщиком: откройте
https://git-scm.com/download/win, скачайте файл, запустите и жмите «Далее» на всех
шагах, ничего менять не надо. После установки — новое окно PowerShell.
Либо просто обойдитесь без git, вариантом с Download ZIP ниже.

**Проверяем:**
```
git --version
```

🖱 **Если ставить git не хочется** — он нужен ровно один раз, чтобы скачать папку
с файлами. Можно обойтись браузером: откройте
https://github.com/aenix-org/cozystack-migration-workshop, нажмите зелёную кнопку
**Code → Download ZIP** и распакуйте архив. Дальше всё то же самое, только вместо
`cd cozystack-migration-workshop` заходите в распакованную папку.

---

## 6 · Забираем материалы и подставляем свой номер

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
cd cozystack-migration-workshop
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
cd ~/cozystack-migration-workshop
```
На Windows путь тот же: `cd $HOME\cozystack-migration-workshop`.
Проверить, где вы сейчас: `pwd` (в PowerShell тоже работает).

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
Пока просто знайте, что она вас там ждёт.

---

## 6a · Карта файлов: что где лежит и где запускается

**Прочитайте один раз — дальше не будете гадать**

В репозитории два типа файлов, и живут они в разных местах. Это главное, что стоит
усвоить до начала практики.

**Манифесты — `manifests/*.yaml`. Применяются с вашего ноутбука.**
Это описание того, что создать в кластере. Команда всегда одна: `kubectl apply -f <файл>`.

• `01-bucket.yaml` — хранилище под образ · шаг 1
• `02-conversion-vm.yaml` — машина-конвертер · шаг 2
• `03-app-vm.yaml` — ваша виртуалка · шаг 4 (сюда руками вписывается presigned-ссылка)
• `04-managed.yaml` — Postgres и Kafka из каталога · шаг 5

**Скрипты — `scripts/*`. Запускаются не у вас, а внутри виртуалок.**
На ноутбуке они вам не нужны вообще.

• `convert.sh` — внутри машины-конвертера · шаг 3
• `netfix-dhcp.sh` — внутри вашей виртуалки · шаг 6
• `connect-managed.sh` — внутри вашей виртуалки · шаг 7
• `orders-schema.sql` — таблица для базы, изнутри виртуалки · шаг 8 (её мы наберём запросом,
  файл — чтобы посмотреть, что именно создаётся)

**Как скрипт попадает внутрь виртуалки — и почему по-разному.**

В **машине-конвертере** есть сеть, поэтому она скачивает файл сама. Репозиторий
открытый, ключи не нужны:
```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/scripts/convert.sh
```

В **вашей виртуалке сети сначала нет вообще** — она и есть та поломка, которую мы чиним
на шаге 6. Скачать туда нечего и нечем, файлы через консоль не передаются. Поэтому
`netfix-dhcp.sh` и `connect-managed.sh` вы не качаете, а **набираете руками**: команд
там по две-три, я дам их в чате готовыми. Сами файлы в репозитории — это то же самое,
но подробно и с комментариями: удобно перечитать потом, когда будете повторять
у себя.

⚠️ **Тонкость, из-за которой всё ломается.** Замену `tenant-workshopXX` на свой номер вы делали
на ноутбуке. Файл, скачанный внутри машины-конвертера, приходит свежий, с заглушками —
значения в него вписываются заново, руками.

---

## 7 · Шаг 1: своё хранилище

**Создаём бакет под образ**

📍 **Где:** на своём ноутбуке, в папке склонированного репозитория.

Образ диска весит несколько гигабайт. Его надо куда-то положить, чтобы кластер потом
забрал файл по ссылке. Для этого — объектное хранилище, тот же принцип, что у S3.

```bash
kubectl apply -f manifests/01-bucket.yaml
kubectl get bucket -n tenant-workshopXX
```

Дождитесь, пока бакет перейдёт в рабочее состояние.

Манифест создаёт бакет с именем **`my-images`** и одним пользователем — `app`.
В дашборде он появится в разделе **Bucket**.

🖱 **Через дашборд:** **Bucket → Deploy new**, имя `my-images`. Только обязательно
**сразу добавьте пользователя `app` в секцию `users`**, ещё до создания. Если создать
пустой бакет и дописать пользователя потом через Edit, бакет останется в половинчатом
состоянии и заливка образа упадёт. В манифесте это уже учтено.

**Теперь забираем ключи от бакета — они понадобятся через два шага.**

Бакет закрыт, и чтобы что-то в него положить, нужны его собственные ключи доступа.
Они в дашборде: **Bucket → `my-images` → вкладка Secrets → секрет
`bucket-my-images-app-credentials`**. Разверните его — увидите четыре значения,
у каждого кнопки *Reveal* (показать) и *Copy* (скопировать).

**Что с ними делать прямо сейчас: скопируйте три из них в блокнот** — в любой, хоть
в заметки, хоть в черновик сообщения самому себе:

• `bucketName`
• `accessKey`
• `secretKey`

Четвёртое, `endpoint`, записывать не нужно — оно у всех одинаковое и уже вписано
в скрипт.

**Куда они пойдут.** На шаге 3 вы откроете в машине-конвертере файл `convert.sh`,
а в нём — блок «ВСТАВЬТЕ СВОИ ЗНАЧЕНИЯ» из трёх строк:

```
BUCKET="ВСТАВЬТЕ_bucketName"
ACCESS_KEY="ВСТАВЬТЕ_accessKey"
SECRET_KEY="ВСТАВЬТЕ_secretKey"
```

Ровно эти три значения туда и вставите, каждое в свои кавычки. Больше они нигде
не понадобятся: скрипт сам зальёт готовый образ в ваш бакет и сам сделает ссылку на него.

⚠️ Секретный ключ — это пароль от вашего хранилища. В общий чат его не присылайте,
даже когда просите помощи. Если что-то не сходится, напишите мне лично.

⚠️ Если решите поменять `endpoint` на свой: в дашборде он показан без схемы
(`s3.workshop.aenix.io`), а в скрипт вписывается **с** `https://` в начале.
Не поставите — заливка молча не пройдёт.

---

## 8 · Шаг 2: машина-конвертер

**Поднимаем виртуалку, в которой будем конвертировать**

📍 **Где:** на ноутбуке.

Конвертация — тяжёлая операция со своими инструментами. Проще поднять временную машину,
сделать дело внутри и погасить, чем ставить всё это себе на ноутбук.

```bash
kubectl apply -f manifests/02-conversion-vm.yaml
kubectl get vminstance -n tenant-workshopXX -w
```

Ждём состояния `Running` (нажмите Ctrl+C, чтобы выйти из слежения). Заходим внутрь:

```bash
virtctl ssh --namespace=tenant-workshopXX ubuntu@vmi/vm-instance-convert
```
Логин и пароль — `ubuntu` / `ubuntu`.

**Что именно создала эта команда.** В файле описаны два объекта, поэтому в дашборде
появятся две записи, а не одна:

• **VM Disk** с именем `convert-tools` — диск на 25Gi, клонированный из каталожного
  образа `ubuntu-20.04`
• **VM Instance** с именем `convert` — сама машина, которая этот диск подключает

Виртуалка без диска не бывает — поэтому диск всегда создаётся первым и отдельным
объектом. Запомните это, на шаге 4 будет ровно та же пара.

⚠️ И сразу про имена, иначе будете путаться. Объект в дашборде называется `convert`,
а машина, которую он поднимает, внутри кластера зовётся **`vm-instance-convert`** —
с приставкой. Поэтому в дашборде вы ищете `convert`, а в командах `virtctl` пишете
`vm-instance-convert`.

🖱 **Через дашборд:** создаёте те же два объекта руками, по очереди.
**1)** **VM Disk → Deploy new**: имя `convert-tools`, source = **image**, образ
`ubuntu-20.04`, размер `25Gi`, storage class `replicated`.
**2)** **VM Instance → Deploy new**: имя `convert`, instance type `u1.large`,
profile `ubuntu`, в списке дисков выбираете `convert-tools` — тот, что создали
шагом раньше. Зайти внутрь можно там же кнопкой **VNC**, тогда ни ssh, ни virtctl
не нужны, всё в браузере.

⚠️ Диск делайте не меньше 25Gi: если он меньше образа, клон не пройдёт, а потом диск
зависает в состоянии Terminating и мешается.

⚠️ В манифесте намеренно указан образ **ubuntu-20.04**, не меняйте его.
На 24.04 машина не загружается, а на 22.04 конвертация спотыкается о старую базу
пакетов внутри CentOS 7. Мы это проверили, чтобы вы не проверяли.

---

## 9 · Шаг 3: конвертация образа

**Превращаем образ VMware в образ для KVM**

📍 **Где:** внутри машины-конвертера, куда вы только что зашли по ssh. Не на ноутбуке.

📄 Работаем со `scripts/convert.sh`. У этой машины сеть есть, поэтому она скачает
файл сама — копировать через буфер не нужно.

Забираем скрипт с гитхаба прямо в машину:
```bash
curl -fsSLO https://raw.githubusercontent.com/aenix-org/cozystack-migration-workshop/master/scripts/convert.sh
```

Открываем его:
```bash
nano convert.sh
```

**Вот и пригодились три значения, которые вы записали в блокнот на шаге 1.** В начале
файла есть блок «ВСТАВЬТЕ СВОИ ЗНАЧЕНИЯ» — замените в нём заглушки на свои, оставив
кавычки на месте:

```
BUCKET="имя-вашего-бакета"
ACCESS_KEY="ваш-accessKey"
SECRET_KEY="ваш-secretKey"
```

Строку `S3_ENDPOINT` и ссылку на исходный образ не трогайте — они уже правильные
и одинаковые у всех.

Сохранить в nano: `Ctrl+O`, затем `Enter`, затем `Ctrl+X` для выхода. Проверить, что
заглушек не осталось:
```bash
grep ВСТАВЬТЕ convert.sh || echo "всё заполнено, можно запускать"
```

Запускаем — обязательно через `sudo`, скрипту нужны права root:
```bash
sudo bash convert.sh
```

Что происходит внутри: скрипт скачивает исходный образ, запускает `virt-v2v`,
сжимает результат и заливает его в ваш бакет.

Самое важное делает `virt-v2v`: он не просто меняет формат файла, а подкладывает
внутрь гостевой системы драйверы virtio и правит загрузчик. Без этого машина
на новом гипервизоре просто не стартует.

⏳ **Это займёт около пяти минут.** На нашем стенде нет вложенной виртуализации,
поэтому конвертация идёт в режиме эмуляции. Прогресс виден в консоли — не закрывайте её.

В конце скрипт напечатает **presigned-ссылку** на ваш образ — ищите в выводе строку,
начинающуюся со слова `Share:`, ссылка идёт сразу за ним.

**Что с ней делать:** скопируйте её в тот же блокнот. На следующем шаге вы вернётесь
на ноутбук, откроете `manifests/03-app-vm.yaml` и вставите её в поле `url` — туда, где
сейчас стоит заглушка `ВСТАВЬТЕ_PRESIGNED_URL`. Та самая, про которую я предупреждал,
когда мы подставляли номера.

Это временная подписанная ссылка: хранилище наружу не открыто, а ссылку вы сделали
своими же ключами. Она живёт неделю — на воркшоп и на эксперименты после хватит
с запасом.

---

## 10 · Шаг 4: ваша виртуальная машина

**Поднимаем машину из собственного образа**

📍 **Где:** на ноутбуке.

Откройте `manifests/03-app-vm.yaml` и вставьте presigned-ссылку в поле `url`.
Затем примените:

```bash
kubectl apply -f manifests/03-app-vm.yaml
kubectl get vminstance -n tenant-workshopXX -w
```

Сначала кластер скачает образ по ссылке и разложит его по репликам — это займёт минуту-другую.
Потом машина запустится.

Заходим внутрь:
```bash
virtctl console --namespace=tenant-workshopXX vmi/vm-instance-app-1
```
Логин и пароль — `root` / `cozydemo`. Выйти из консоли: `Ctrl+]`.

**Здесь та же пара объектов, что и с машиной-конвертером**, только диск берётся
не из каталога, а качается по вашей ссылке:

• **VM Disk** `app-1` — 10Gi, source = http, тот самый presigned-URL
• **VM Instance** `app-1` — профиль `centos.7`, instance type `u1.medium`

Имена совпадают, и это нормально: диск и машина — разные типы объектов. В командах
`virtctl` машина, как и в прошлый раз, зовётся с приставкой: **`vm-instance-app-1`**.

🖱 **Через дашборд:** **1)** **VM Disk → Deploy new**: имя `app-1`, source = **http**,
в поле URL — presigned-ссылка, размер `10Gi`, storage class `replicated`.
**2)** **VM Instance → Deploy new**: имя `app-1`, instance type `u1.medium`,
profile `centos.7`, диск — `app-1`. Консоль — кнопка **VNC** на странице машины.

Обратите внимание, что вы только что сделали: описали виртуальную машину текстом
и применили его одной командой. Этот файл можно положить в репозиторий и поднять
сотню таких же машин, не сделав ни одного клика.

---

## 11 · Шаг 5: база и очередь из каталога

**Поднимаем управляемые Postgres и Kafka**

📍 **Где:** на ноутбуке.

В исходной системе база и очередь жили на отдельных виртуалках с CentOS 7. Их мы
**не везём** — вместо них берём сервисы платформы. Патчить устаревшую операционную
систему больше не ваша работа.

```bash
kubectl apply -f manifests/04-managed.yaml
kubectl get postgres,kafka -n tenant-workshopXX
```

Поднимаются они не мгновенно — пока ждёте, посмотрите в дашборде, что именно создалось.

**Что создалось:** объект **Postgres** с именем `db` — внутри база `orders`
и пользователь `orders` — и объект **Kafka** с именем `kafka` с топиком `orders`.
Имена не меняйте: на них рассчитаны адреса ниже и команды следующих шагов.

🖱 **Через дашборд:** это самый наглядный шаг для мышки. Каталог платформы —
**Postgres → Deploy new**: имя `db`, одна реплика, в секции users пользователь
`orders`, в секции databases база `orders`. Затем **Kafka → Deploy new**: имя `kafka`,
одна реплика, топик `orders`.

**Записывать ничего не надо, но вот адреса — они пригодятся на шаге 7.** Изнутри
кластера база и очередь доступны по именам:

• Postgres — `postgres-db-rw.tenant-workshopXX.svc.cozy.local:5432`
• Kafka — `kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local:9092`

Именно эти две строки через два шага заменят собой прибитые адреса `192.168.10.30`
и `192.168.10.40` в конфиге приложения. Я пришлю их готовыми командами, свой номер
подставите вместо `XX`.

Запомните саму разницу: раньше приложение ходило по прибитому адресу, теперь — по имени.
Адрес может смениться, имя останется.

---

## 12 · Шаг 6: чиним сеть внутри машины

**Сначала сеть, потом всё остальное**

📍 **Где:** внутри вашей виртуалки, в консоли. Не на ноутбуке.

📄 Это содержимое `scripts/netfix-dhcp.sh` из репозитория. **Скачивать его в машину
не надо и не получится** — сети у неё пока нет, она и есть наша поломка. Команды
набираем руками, их две. Файл в репозитории — чтобы перечитать потом.

Приложение сейчас не работает, и это не поломка стенда. Внутри образа осталось прошлое:
статический адрес из сети VMware и шлюз, которого здесь нет. Машина держится за них
и не видит ни кластерного DNS, ни соседей.

Зайдите в машину через консоль — с ноутбука:
```bash
virtctl console --namespace=tenant-workshopXX vmi/vm-instance-app-1
```
🖱 **Или мышкой:** в дашборде откройте свою машину и нажмите **VNC** — это та же
консоль, только в браузере. Оба пути идут через API кластера и работают даже сейчас,
когда сеть внутри машины сломана.

Дальше — внутри машины (это CentOS, сеть настраивается здесь, а не в netplan):
```bash
sed -i 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/; /^IPADDR/d; /^GATEWAY/d; /^NETMASK/d; /^PREFIX/d; /^DNS/d' /etc/sysconfig/network-scripts/ifcfg-eth0
```
Проверьте глазами, что получилось:
```bash
cat /etc/sysconfig/network-scripts/ifcfg-eth0
```
Должна остаться строка `BOOTPROTO=dhcp`, а строк с адресом и шлюзом быть не должно.
Если правите вручную через `nano` — результат тот же, просто дольше.

Теперь машину надо перезапустить:
```bash
reboot
```
🖱 **Или мышкой:** в дашборде на странице машины кнопка **Restart**.

После перезагрузки проверьте, что адрес стал кластерным:
```bash
ip -4 addr show eth0
```
Должно быть что-то вида `10.244.x.x`. Значит, машина в сети кластера и видит его DNS.

⚠️ Порядок важен: пока адрес старый, имена сервисов не разрешаются, и править конфиг
приложения бессмысленно.

---

## 13 · Шаг 7: переключаем приложение на управляемые сервисы

**Меняем прибитые адреса на имена**

📍 **Где:** внутри вашей виртуалки, после перезагрузки.

📄 Это содержимое `scripts/connect-managed.sh`. Тоже набираем руками — по той же
причине, и потому что команд всего три.

Внутри машины откройте конфиг приложения:
```bash
cat /etc/orders/application.properties
```
Вы увидите те самые `192.168.10.30` и `192.168.10.40`. Это боль любой легаси-системы:
никто уже не помнит, почему именно эти адреса.

Замените их на имена сервисов (подставьте свой номер вместо `XX`):
```bash
sed -i 's|192.168.10.30|postgres-db-rw.tenant-workshopXX.svc.cozy.local|g' /etc/orders/application.properties
sed -i 's|192.168.10.40|kafka-kafka-kafka-bootstrap.tenant-workshopXX.svc.cozy.local|g' /etc/orders/application.properties
systemctl restart orders-api
```
(двумя командами, а не одной с переносом: перенос строки при копировании из чата
часто теряется, и команда выполняется наполовину)

Проверяем:
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/actuator/health
```
`200` — приложение видит и базу, и очередь. Если `503` — вернитесь на шаг с сетью,
скорее всего адрес не сменился.

---

## 14 · Шаг 8: создаём таблицу в базе

**База пустая — приложению нужна схема**

📍 **Где:** внутри вашей виртуалки — она уже видит базу по имени, отдельный клиент
на ноутбуке не нужен.

📄 Это `scripts/orders-schema.sql` из репозитория. Скачивать не будем — таблица
одна, наберём запросом.

Здесь нужны два действия, а не одно. Сначала владельцу базы выдаётся право
создавать таблицы, и только потом создаётся сама таблица. Пропустите первое —
получите ошибку на втором.

Проверьте, есть ли клиент базы в машине:
```bash
command -v psql || echo "psql нет"
```
Если нет — ставим. И сразу предупреждаю: у CentOS 7 закончилась поддержка, штатные
репозитории переехали, поэтому `yum install -y postgresql` может не найти пакет.
Если так и вышло — не боритесь, скажите мне: те же две команды выполним из
машины-конвертера, она в той же сети и видит базу так же.

```bash
# шаг 1 — право на схему (пароль суперпользователя даст ведущий)
PGPASSWORD='<пароль-суперпользователя>' psql -h postgres-db-rw -U postgres -d orders \
  -c 'GRANT CREATE,USAGE ON SCHEMA public TO orders'

# шаг 2 — сама таблица (пароль роли orders задан в манифесте, он ниже)
PGPASSWORD='Orders2019!' psql -h postgres-db-rw -U orders -d orders \
  -c 'CREATE TABLE IF NOT EXISTS orders (id BIGSERIAL PRIMARY KEY, item TEXT NOT NULL, status TEXT NOT NULL DEFAULT '"'"'NEW'"'"', created_by TEXT, processed_by TEXT, created_at TIMESTAMPTZ NOT NULL DEFAULT now(), processed_at TIMESTAMPTZ)'
```

Пароль роли `orders` — `Orders2019!`, он прописан прямо в `manifests/04-managed.yaml`,
искать его нигде не надо. Если поднимали базу мышкой и задали свой — подставьте свой.
Он же лежит в дашборде: **Postgres → `db` → Secrets → `postgres-db-app`**.

Отдельно нужен пароль суперпользователя — только для первой команды, с грантом.
Его скажу я, в секретах тенанта его нет.

Почему это отдельный шаг: проверка здоровья приложения смотрит только на подключение
к базе. Она честно ответит `200` даже без таблицы — а вот заказ создать не получится.

---

## 15 · Шаг 9: проверяем всю цепочку

**Момент истины**

📍 **Где:** на ноутбуке.

Пробрасываем порт приложения к себе:
```bash
virtctl port-forward --namespace=tenant-workshopXX vmi/vm-instance-app-1 8088:8080
```
Окно с этой командой не закрывайте: туннель живёт, пока она работает.

Если virtctl ругается на разницу версий клиента и кластера — это предупреждение,
а не ошибка, работать не мешает.

Если проброс всё равно не поднимается, тот же туннель делается через под машины:
```bash
kubectl get pod -n tenant-workshopXX -l vm.kubevirt.io/name=vm-instance-app-1
kubectl port-forward -n tenant-workshopXX <имя-пода-из-вывода> 8088:8080
```

В другом окне терминала:
```bash
# здоровье
curl -s http://localhost:8088/actuator/health

# создаём заказ
curl -s -X POST http://localhost:8088/api/orders \
  -H 'Content-Type: application/json' -d '{"item":"test"}'

# смотрим, что он записался
curl -s http://localhost:8088/api/orders
```

Если заказ создался — вы прошли путь целиком. Приложение приехало из VMware, работает
в кластере, пишет в управляемую базу и отправляет события в управляемую очередь.

🎉 Полчаса назад эта система жила на ESXi.

---

## 16 · Если что-то не работает

**Короткий список того, обо что спотыкаются**

• **Приложение недоступно снаружи.** В мигрированном CentOS обычно виноват встроенный
  межсетевой экран — он закрывает порт 8080:
  ```bash
  systemctl stop firewalld
  ```

• **`kubectl` отвечает «forbidden».** Проверьте, что обращаетесь к своему пространству:
  `-n tenant-workshopXX`. И помните, что доступен `vminstance`, а не `vm` или `vmi`.

• **Заказ не создаётся, а здоровье при этом `200`.** Не создана таблица — вернитесь
  к сообщению про схему базы.

• **Диск завис в состоянии Terminating.** Скорее всего размер диска меньше образа.
  Для ubuntu-20.04 нужно не меньше 25Gi.

• **Ничего не помогает.** Пишите сюда, разберём вместе. Это нормальная часть работы,
  а не повод для неловкости — на реальной миграции будет то же самое, только в три часа ночи.

---

## 17 · После воркшопа

**Что остаётся у вас**

• **Окружение — на месяц.** Тенант ваш, ломайте и пересобирайте что угодно.
  Попробуйте то, на что сегодня не хватило времени: поднять Redis, сделать копию
  виртуалки, потрогать живую миграцию.
• **Этот чат — тоже на месяц.** Вопрос через две недели — обычное дело.
• **Домашние лабораторные и сертификат.** Задания пришлю отдельным сообщением.
  Сертификат — то, что можно показать руководителю: в компании есть человек,
  который умеет это руками.

Спасибо за работу. Если захотите разобрать свой парк — напишите мне лично,
посмотрим, что поедет как есть, что заменится сервисами, а что честно стоит
оставить на месте.
