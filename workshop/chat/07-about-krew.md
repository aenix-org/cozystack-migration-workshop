## 7. Про krew — и почему мы им не пользуемся

**Короткий ответ: не ставьте его сегодня**

krew — менеджер плагинов для kubectl, и им можно поставить те же virtctl и kubelogin.
Но на прошлых воркшопах именно он съел больше всего времени, особенно на Windows.
Если вы сделали шаги 3 и 4 — **у вас уже всё есть, этот пост пропускайте**.

Читайте дальше, только если krew у вас уже стоит или очень хочется.

⚠️ **Три грабли Windows, все встречались вживую:**
• **PATH не обновился в текущем окне.** Самое частое. Лечится прямо в той же сессии:
  `$env:Path += ";$HOME\.krew\bin"`
• **krew.exe не доустановился** — SmartScreen или антивирус его прибили. Проверить:
  `Test-Path "$HOME\.krew\bin\kubectl-krew.exe"`
• **Админское и обычное окно PowerShell — это разные миры.** У них разные `$HOME`
  и разный пользовательский PATH. Поставили от администратора, запускаете обычным —
  плагин не найдётся никогда. Ставьте и запускайте в одном и том же обычном окне.

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
