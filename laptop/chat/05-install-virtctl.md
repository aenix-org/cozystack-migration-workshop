## 5. Ставим virtctl

**virtctl — управление виртуалками**

⚠️ **Внимание: ставим не самую свежую, а ту, что в кластере.** Клиент новее сервера
меняет синтаксис команд, и половина вопросов на прошлых воркшопах была именно из-за этого.
В нашем кластере **v1.8.4** — она и указана во всех блоках ниже. Не меняйте её на latest.

**macOS**
```bash
VER=v1.8.4
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
VER=v1.8.4
ARCH=$([ "$(uname -m)" = "aarch64" ] && echo arm64 || echo amd64)
curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${VER}/virtctl-${VER}-linux-${ARCH}"
chmod +x virtctl
sudo mv virtctl /usr/local/bin/
```

**Windows** (PowerShell, запускать от обычного пользователя)
```powershell
$ver = "v1.8.4"
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

**Про имя машины в командах.** С клиентом v1.8.4 машина указывается по голому имени,
без приставки: `vm-instance-app-1`. Если у вас всё же встал клиент поновее и он отвечает
`target must contain type and name separated by '/'` — добавьте приставку **`vmi/`**:
`vmi/vm-instance-app-1`.

⚠️ Приставка именно `vmi/`, не `vm/`. С `vm/` придёт отказ по правам
(`cannot get resource "virtualmachines/portforward"`): участнику выданы права
на запущенные экземпляры машин, а не на их описания.
