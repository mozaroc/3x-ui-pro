# 3x-ui-pro

Автоматическая установка панели [3x-ui](https://github.com/MHSanaei/3x-ui) с nginx, SSL, Clash-подпиской и диагностикой сети.

- Debian 12 / Ubuntu 24
- Два домена или поддомена (для панели и для REALITY)
- Автоматическое обновление SSL-сертификатов
- Поддержка VLESS+REALITY, VLESS+WebSocket, VLESS+XHTTP, Trojan+gRPC — всё через порт 443

---

## Что устанавливается

| Компонент | Описание |
|-----------|----------|
| 3x-ui | VPN-панель с веб-интерфейсом |
| nginx | Обратный прокси, SNI-роутинг |
| certbot | Let's Encrypt SSL |
| Clash-подписка | Автоматическая выдача `clash.yaml` по User-Agent |
| Диагностика | MTR-трейсер + тест скорости в браузере |
| Фейковый сайт | Случайный HTML-сайт-прикрытие |
| Бэкап | Скрипт резервного копирования |

---

## Установка

**Шаг 1 — скачать скрипт**

```bash
wget -qO x-ui-latest.sh https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-latest.sh
```

**Шаг 2 — запустить**

```bash
bash x-ui-latest.sh -install y -subdomain panel.example.com -reality_domain r.example.com
```

Замените `panel.example.com` на домен панели, `r.example.com` — на домен для REALITY.

---
## Патч

**Шаг 1 — скачать скрипт**

```bash
wget -qO x-ui-latest.sh https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-patch.sh
```

**Шаг 2 — запустить**

```bash
bash x-ui-patch.sh
```

---

## Удаление

```bash
bash x-ui-latest.sh -uninstall y
```

---

## Параметры запуска

| Параметр | Описание |
|----------|----------|
| `-install y` | Установить |
| `-subdomain <домен>` | Домен панели и подписок |
| `-reality_domain <домен>` | Домен назначения для REALITY |
| `-auto_domain y` | Автоопределение домена (без ручного ввода) |
| `-uninstall y` | Полное удаление |

---

## Clash-подписка

Работает через определение User-Agent — один URL, разное поведение:

- **Clash / Mihomo / Stash** → получают `clash.yaml` с готовой конфигурацией
- **Обычный браузер / другие клиенты** → получают стандартную страницу подписки 3x-ui

Ссылку для импорта выводит скрипт после установки.

---

## Бэкап и восстановление

**Установить скрипт бэкапа**

```bash
wget -qO /usr/local/bin/x-ui-backup https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/assets/backup/x-ui-backup.sh
chmod +x /usr/local/bin/x-ui-backup
```

**Создать бэкап**

```bash
x-ui-backup backup
```

**Список бэкапов**

```bash
x-ui-backup list
```

**Восстановить из бэкапа** (на чистом сервере, пакеты ставятся автоматически)

```bash
x-ui-backup restore /var/backups/x-ui/x-ui-backup-20260101-120000.tar.gz
```

Бэкап включает: конфиги nginx, БД панели, бинарник 3x-ui, SSL-сертификаты, веб-контент, systemd-юниты, cron, правила UFW.

---

## Диагностика сети

После установки доступна по ссылке, которую выводит скрипт. Включает:

- MTR-трейс до вашего IP
- Тест скорости загрузки и отдачи (512 МБ файлы)
