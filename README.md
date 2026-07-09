# SSH Hardening Autoconfig (CIS‑aligned)

## RU · Кратко
Скрипты автоматизируют настройку безопасности OpenSSH по рекомендациям CIS. Делают бэкапы, изменяют `sshd_config`, настраивают `TMOUT`, создают баннер, при желании добавляют локальное правило auditd, валидируют конфигурацию и по подтверждению перезапускают службу.

## EN · Summary
Bash scripts that apply CIS‑aligned OpenSSH hardening. They back up files, edit `sshd_config`, set `TMOUT`, create a login banner, optionally add a local auditd rule, validate the configuration, and optionally restart the service.

---

## Содержимое репозитория / Repository layout
- `ssh-autohardening.sh` — базовый non‑TUI вариант с подтверждениями `Y/N`.


- `pgi-ssh-hardening.sh` — TUI‑версия с чекбоксами (whiptail/dialog) и подменю выбора пользователей для `AllowUsers`.
<img width="710" height="617" alt="Screenshot 2025-10-14 110443" src="https://github.com/user-attachments/assets/967fff2d-0cb8-41c9-9231-90e6db5c9a57" />

---

## Требования / Requirements
- bash ≥ 4, Linux с systemd.
- Установленный OpenSSH server (должен существовать `/etc/ssh/sshd_config`).
- Опционально: `auditd` и `augenrules` для локального правила аудита.
- Для TUI: пакет `whiptail` (newt) или `dialog`.

Установка TUI-пакетов:
```bash
# Debian/Ubuntu
sudo apt-get update && sudo apt-get install -y whiptail   # или: sudo apt-get install dialog

# RHEL/Alma/Rocky
sudo dnf install -y newt                                  # или: sudo dnf install dialog
```

---

## Что меняется / Files touched
- `/etc/ssh/sshd_config`
- `/etc/profile.d/99-timeout.sh` (задаёт `TMOUT=900`)
- `/etc/issue.net` (баннер)
- `/etc/audit/rules.d/50-sshd.rules` (если каталог существует и выбран пункт AUDIT)
- Права в `/home/*/.ssh` и `/home/*/.ssh/authorized_keys` (если выбран пункт PERMS)

### Бэкапы / Backups
Перед изменениями каждый затрагиваемый файл копируется рядом с оригиналом как:
```
*.bak.YYYYMMDD-HHMMSS
```

### Откат / Rollback
```bash
# Восстановление и запуск сервиса
sudo cp -a /etc/ssh/sshd_config.bak.20251014-120301 /etc/ssh/sshd_config
sudo systemctl restart sshd || sudo systemctl restart ssh
```

---

## Использование / Usage

### Вариант 1: базовый скрипт (non‑TUI)
```bash
chmod +x ./autossh.sh
sudo bash ./autossh.sh
```

### Вариант 2: TUI‑скрипт с чекбоксами
```bash
chmod +x ./autossh_check.sh
sudo bash ./autossh_check.sh
```
В списке отметьте нужные опции. Если активирован `ALLOW`, появится окно выбора локальных пользователей, которым будет разрешён вход по SSH. Скрипт предупреждает, если список пуст, и предлагает добавить текущего оператора, чтобы исключить самоблокировку.

---

## Что именно настраивается / What is enforced

Базовый набор (CIS‑aligned):
- `PubkeyAuthentication yes`
- `PasswordAuthentication no`
- `PermitRootLogin no`
- `ClientAliveInterval 300`
- `ClientAliveCountMax 0`
- `MaxAuthTries 3`
- `MaxSessions 4`
- `LoginGraceTime 60`
- `X11Forwarding no`, `AllowAgentForwarding no`, `GSSAPIAuthentication no`
- `IgnoreRhosts yes`, `HostbasedAuthentication no`, `PermitEmptyPasswords no`, `PermitUserEnvironment no`, `UsePAM yes`
- `LogLevel INFO` по умолчанию; `VERBOSE` опционально
- Криптонастройки (по умолчанию в скрипте):
  - `Ciphers chacha20-poly1305@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr`
  - `MACs hmac-sha2-512,hmac-sha2-256`
  - `KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group14-sha256`

> Примечание: в FIPS‑режиме исключите chacha20 и оставьте AES+SHA2. Директива `Protocol 2` не задаётся, так как в новых OpenSSH она устарела.

Дополнительно:
- Таймаут неактивной shell‑сессии: `TMOUT=900` через `/etc/profile.d/99-timeout.sh`.
- Баннер предупреждения `/etc/issue.net`.
- Локальное auditd‑правило на изменение `sshd_config` (если выбрано и присутствует auditd).
- Приведение прав в домашних каталогах пользователей для `~/.ssh` и `authorized_keys`.

---

## Валидация и перезапуск / Validation and restart
Перед рестартом выполняется проверка синтаксиса:
```bash
sshd -t -f /etc/ssh/sshd_config
```
При ошибке конфигурации скрипт автоматически откатывает бэкап и выводит причину. Перезапуск службы опциональный и запрашивается отдельно.

---

## Цветовая схема TUI / TUI theming
- Для `whiptail` используется переменная `NEWT_COLORS` (зелёный на чёрном).
- Для `dialog` создаётся временный `DIALOGRC`.  
Цвета можно отключить, удалив/закомментировав соответствующий блок в скрипте.

---

## Частые проблемы / Troubleshooting
- `auditd` не установлен — пункт AUDIT будет пропущен.
- Нет `/etc/ssh/sshd_config` — установите OpenSSH server.
- `sshd -t` сообщает об ошибке — будет выполнен автоматический откат и показана диагностика.
- Нет TUI‑пакетов — скрипт переключится в CLI‑режим с вопросами в консоли.

---

## Поддержка платформ / Tested
Проверено на Debian 12, Ubuntu 22.04/24.04, Rocky/Alma 9 (systemd). SysV init не поддерживается.

---

## Обратная связь / Feedback
Вопросы и предложения приветствуются. Создавайте issue в репозитории.

---

## Автор / Author
Антон Паламарчук · Expice Security  
Email: info@expice.ru

---

## Лицензия / License
MIT License.
