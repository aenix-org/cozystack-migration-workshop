## 8. Заходим в кластер

**Подключаемся к своему тенанту**

📍 **Где:** дашборд открываем в браузере, команды выполняем на ноутбуке.

**Ваши доступы:**
```
дашборд: https://dashboard.workshop.aenix.io
логин:   workshopXX      ← ваш номер, скажу лично
пароль:  ...             ← скажу лично
```

1. Откройте дашборд по ссылке выше.
2. Войдите под своим логином.
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

⚠️ **`x509: certificate signed by unknown authority`** — вторая частая ошибка, почти
всегда на Windows. Означает она не проблему с сертификатом, а то, что `kubectl` взял
**не тот файл доступа**: доверие к внутреннему центру сертификации кластера лежит в вашем
kubeconfig, в поле `certificate-authority-data`, и в файле по умолчанию его нет.

Разбираемся по шагам, в PowerShell:
```powershell
$env:KUBECONFIG
# пусто — значит берётся файл по умолчанию, а не тот, что вам выдали

Select-String -Path "$HOME\.kube\workshop" -Pattern "certificate-authority-data" -Quiet
# False — файл сохранён неполностью, скачайте секрет из дашборда заново

Get-Content "$HOME\.kube\workshop" -TotalCount 1
# должно начинаться с apiVersion; квадратики или пустота — файл в UTF-16
```

Третий пункт — самая коварная ловушка Windows. Блокнот и перенаправление `>` сохраняют
файл в **UTF-16**, а `kubectl` такой файл не читает. Сохранять только в UTF-8: в Блокноте
тип файла «Все файлы», а из команды — через `Out-File -Encoding utf8`, не через `>`.
