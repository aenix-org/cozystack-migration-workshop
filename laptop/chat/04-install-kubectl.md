## 4. Ставим kubectl

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
