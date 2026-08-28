## 9. Ставим git

**Последний инструмент — им заберём материалы**

📍 **Где:** на ноутбуке.

Сначала проверьте, вдруг он уже есть: на macOS и в большинстве сборок Linux git
предустановлен.
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
Либо обойдитесь без git — вариантом с Download ZIP ниже.

**Проверяем:**
```
git --version
```

🖱 **Если ставить git не хочется** — он нужен ровно один раз, чтобы скачать папку
с файлами. Можно обойтись браузером: откройте
https://github.com/aenix-org/cozystack-migration-workshop, нажмите зелёную кнопку
**Code → Download ZIP** и распакуйте архив. Дальше всё то же самое, только вместо
`cd cozystack-migration-workshop` заходите в распакованную папку.
