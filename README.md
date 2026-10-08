# win-auto-update

Одна задача Планировщика, которая раз в день обновляет на Windows-машине всё сразу: программы из
winget, программы «не из winget» (последний релиз на GitHub), Windows Update — и саму себя.
Ничего не спрашивает, ничего не показывает, не перезагружает компьютер. Что сделала — в журнале.

Сделано для своих машин: ноутбук и стационарный ПК должны сами держать свежими PowerShell, Tabby,
MAX, Claude Usage Widget, домашний VPN-kit и обновления Windows, а не ждать, пока кто-то нажмёт «Обновить».

## Что обновляется

| Шаг | Что делает |
|---|---|
| Сам kit | смотрит последний релиз `gp131313/win-auto-update`; если новее — скачивает, сверяет SHA256, подменяет скрипты и запускает проход заново |
| winget | `winget upgrade --all --silent`; Id из `exclude.txt` закреплены (`winget pin --blocking`) и не трогаются никогда; при ошибке — вторая попытка через минуту |
| GitHub-релизы | для каждой записи `GitHubApps` в `config.json`: если программа установлена и тег последнего релиза новее установленной версии — скачивает файл релиза, сверяет его с `SHA256SUMS.txt` того же релиза (если есть) и ставит тихо |
| Windows Update | ищет обновления (`IsInstalled=0`, тип Software), скачивает, устанавливает. Обновления функций (новая версия Windows) и драйверы — выключены по умолчанию. Если нужна перезагрузка — пишет файл `REBOOT-REQUIRED` рядом со скриптом и строку в журнал, но сам не перезагружает |

Из коробки в `config.json` описаны:

- **Claude Usage Widget** — `ClaudeUsageWidget-Setup-Silent.exe`, в ту же папку, где он стоит;
- **Home VPN Kit** — `HomeVpnKit-Setup-Silent.exe`, в ту же папку (настройки и пароль VPN установщик сохраняет сам). Обновляется только установка, сделанная установщиком kit'а (есть запись в «Приложениях»); «ручные» копии скриптов не трогаются;
- **TrayPingMonitor-VPN** — zip: индикатор останавливается, exe подменяется, индикатор запускается снова;
- **Tabby** — `tabby-<версия>-setup-x64.exe /S /currentuser` (Tabby, поставленный своим установщиком, winget не видит);
- **TDM** — не GitHub, а лента electron-builder (`"Feed": ".../latest.yml"`): версия, имя файла и SHA512 берутся
  из `latest.yml`, установка `tdm-<версия>.exe /S /currentuser`.

Чего нет на машине — пропускается («not installed - skipped»). PowerShell 7, MAX, Telegram Desktop, 7-Zip и всё
остальное «обычное» идёт через winget.

## Установка

Нужны Windows 10/11 и учётная запись с правами администратора (запрос UAC будет один раз).

**Одной строкой** в PowerShell (скачает последний релиз, сверит SHA256 и запустит `Install.cmd`):

```powershell
irm https://raw.githubusercontent.com/gp131313/win-auto-update/main/get.ps1 | iex
```

**Архив.** Скачать `win-auto-update-*.zip` из [Releases](../../releases), распаковать, дважды щёлкнуть `Install.cmd`.

Установщик кладёт скрипты в `%ProgramFiles%\WinAutoUpdate` (запись туда — только у администраторов:
файлы выполняются с правами администратора), регистрирует задачу **Win Auto Update** — при входе
в Windows через 10 минут и ежедневно в 12:00, с наивысшими правами, без мелькающего окна консоли
(`conhost --headless`), — закрепляет исключения winget и добавляет запись в «Параметры → Приложения».
Старая задача «Winget Auto Update» (если была) удаляется, её `exclude.txt` переносится.

Ключи `Install.cmd` (и `install.ps1`):

```
Install.cmd -RunNow              сразу запустить первый проход
Install.cmd -At 03:00            другое время ежедневного запуска
Install.cmd -InstallDir D:\upd   другая папка
Install.cmd -Check               показать, что будет сделано, ничего не меняя
```

Для `get.ps1` ключи передаются через переменную: `$env:WAU_ARGS = '-RunNow'` перед строкой `irm … | iex`.

Удаление — «Параметры» → «Приложения» → **Win Auto Update** или `Uninstall.cmd`. Закрепления winget остаются
(`winget pin list`, `winget pin remove --id <Id>`).

## Настройка

- `exclude.txt` — Id пакетов winget, которые обновлять нельзя (по одному в строке, `#` — комментарий).
  По умолчанию: Syncthing (winget не знает его версию), KeePass (обновление закрывает KeePass и ключи KeeAgent),
  Claude Desktop (обновляется сам), OpenSSH (сервер удалённого управления не должен сбрасываться).
- `config.json`:

```json
{
  "SelfUpdate": true,
  "Winget": true,
  "WindowsUpdate": { "Enabled": true, "Drivers": false, "FeatureUpgrades": false },
  "GitHubApps": [
    {
      "Name": "Tabby",
      "Repo": "Eugeny/tabby",
      "Asset": "^tabby-.*-setup-x64\\.exe$",
      "Installed": { "Type": "File", "Path": "%LOCALAPPDATA%\\Programs\\Tabby\\Tabby.exe" },
      "Install": { "Type": "Exe", "Args": "/S /currentuser" }
    }
  ]
}
```

Запись `GitHubApps`: источник — `Repo` (релизы GitHub) или `Feed` (URL `latest.yml` electron-builder);
`Asset` — регулярное выражение по имени файла релиза; `Installed` — как узнать, что
стоит и какой версии: `Registry` (ключ Uninstall, поля `DisplayVersion` и `InstallLocation`), `RegistryName`
(поиск по `DisplayName` во всех ветках Uninstall) или `File` (версия exe); `Install` — `Exe` (запуск файла
с `Args`; `DirArg` подставляет папку установки, `{dir}`) или `Zip` (распаковать поверх `Exe`, перезапустить).
`"Enabled": false` выключает запись. При обновлении kit'а ваши `config.json` и `exclude.txt` не затираются,
новые версии по умолчанию ложатся рядом как `*.default`.

`"DownloadDir"` — куда класть скачанные установщики (по умолчанию `%LOCALAPPDATA%\WinAutoUpdate\download`).
Если антивирус (например, Kaspersky) «держит» скрипты и установщики, запущенные из AppData или Program Files,
поставьте kit в доверенную антивирусу папку (`Install.cmd -InstallDir C:\Trusted\WinAutoUpdate`) и укажите
`"DownloadDir": "C:\\Trusted\\WinAutoUpdate\\download"`.

## Журнал и ручной запуск

Журнал — `logs\update-<дата>.log` в папке установки, хранится 60 дней. Один полный проход в день
(`last-run.txt`); запустить ещё раз:

```powershell
powershell -ExecutionPolicy Bypass -File "C:\Program Files\WinAutoUpdate\Update-Apps.ps1" -Force
```

Ключи: `-NoSelfUpdate`, `-NoWinget`, `-NoGitHubApps`, `-NoWindowsUpdate`. Скрипт нужно запускать от администратора
(из задачи так и происходит). Загрузки — `%LOCALAPPDATA%\WinAutoUpdate\download`, старше недели удаляются.

## Ограничения

- Компьютер никогда не перезагружается сам: после Windows Update смотрите `REBOOT-REQUIRED` и журнал.
- Программы, которые ставятся «для пользователя» (виджет, Tabby), обновляются из задачи с правами администратора
  той же учётной записи; виджет после обновления до следующего входа в Windows работает с повышенными правами.
- Обновление Home VPN Kit на несколько секунд перезапускает туннель.
- winget иногда не может скачать пакет через VPN (`InternetOpenUrl() failed`) — проход повторится завтра.
- Неподписанный API GitHub ограничен 60 запросами в час с одного адреса; kit делает 5–6.
- Установщик, который не завершился за 30 минут, kit перестаёт ждать (сам процесс не трогает) и идёт дальше.

## Поддержать

Если kit пригодился — можно кинуть на кофе: Dogecoin `D7z9UaBsmcV7EqJo5Y5fdLG9xUNw47dNgr` ([DONATE.md](DONATE.md)).

## Лицензия

MIT.

## English

One scheduled task that keeps a Windows machine up to date once a day, silently and without rebooting:
`winget upgrade --all` (with a pin list in `exclude.txt`), apps that are not in winget (latest GitHub release
of each entry in `config.json`, SHA256-checked against the release's `SHA256SUMS.txt`), Windows Update
(download and install, feature upgrades and drivers off by default, `REBOOT-REQUIRED` file when a reboot is
pending) and the kit itself. Install with `irm https://raw.githubusercontent.com/gp131313/win-auto-update/main/get.ps1 | iex`
or unpack the release zip and run `Install.cmd`; remove via Settings → Apps → Win Auto Update. Log:
`logs\update-<date>.log` in the install folder. MIT license.
