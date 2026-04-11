# xray-vps-setup

Каскадный VLESS+REALITY через два VPS. Обходит DPI, весь трафик выходит с немецкого IP.

## Как это работает

Два сервера: VPS1 (Германия — выходной) и VPS2 (Россия — входной).

```
VPS1 (Германия — exit)               VPS2 (Россия — entry)
┌─────────────────────────────┐    ┌──────────────────────────┐
│ Marzban (SSH only)          │    │ Marzban panel            │
│                             │    │ (управление клиентами)   │
│ XRay :49321                 │    │                          │
│ XHTTP+REALITY              │◄──│ XRay chain outbound      │
│ steal_oneself + own domain  │ XHTTP  │ mode: packet-up          │
│                             │ +REALITY│                          │
│ Angie (TLS, ACME)          │ :49321  │ XRay client inbounds:    │
│                             │    │  - VLESS+REALITY TCP:443 │
└─────────────────────────────┘    │                          │
                                   │ Angie (TLS, ACME)        │
                                   │ Confluence camouflage    │
                                   └──────────────────────────┘
```

Клиенты подключаются к VPS2 через:

- **VLESS+XHTTP+REALITY** (:443) — основной, максимальная защита от DPI, трафик выглядит как обычный HTTPS

Между VPS2 и VPS1 весь трафик идёт по **XHTTP+REALITY**.

Компоненты:

- **VPS1** — Marzban + XRay XHTTP+REALITY inbound на порту 49321 + Angie с собственным доменом (steal_oneself). Панель доступна только через SSH-туннель
- **VPS2** — Независимая Marzban-панель + XRay (VLESS inbound + chain outbound) + Angie (TLS, ACME)

Клиенты создаются в панели VPS2 и выходят в интернет с IP VPS1 (Германия).

## Установка

### Что понадобится

- **2 VPS** с Ubuntu 24.04 и root-доступом:
  - VPS1 (Германия) — выходной сервер
  - VPS2 (Россия) — входной сервер, точка подключения клиентов
- **2 домена** (или поддомена), DNS A-записи для обоих VPS настроены заранее
- На **VPS2** порты **80** и **443** должны быть свободны; на **VPS1** должны быть свободны порты **80** и **49321**

> Скрипты долгие — рекомендуется запускать через `tmux`, чтобы не потерять сессию при обрыве SSH.

---

### Шаг 1. Подготовка DNS

Перед началом убедитесь, что DNS A-записи для обоих VPS распространились:

```bash
dig +short vps1.example.com   # должен вернуть IP VPS1
dig +short vps2.example.com   # должен вернуть IP VPS2
```

Если записи ещё не обновились — подождите.

---

### Шаг 2. Установка VPS1 (Германия — выходной сервер)

Подключитесь по SSH к VPS1 как root:

```bash
apt-get update && apt-get install tmux -y
tmux
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
bash <(wget -qO- https://raw.githubusercontent.com/patronJS/mytests/refs/heads/main/setup-vps1.sh)
```

Скрипт задаст вопросы:

| Вопрос                    | Значение                                           |
| ------------------------- | -------------------------------------------------- |
| Enter your domain         | Домен для VPS1                                     |
| Do you want to harden SSH | `y` — создать нового пользователя, сменить порт    |
| Enter SSH port            | Новый порт для sshd (нельзя 80/443/4123/49321)     |
| Enter SSH public key      | Публичный ключ (`ssh-ed25519 … user@host`)         |

Устанавливает Docker, XRay, Marzban, Angie, **fail2ban**. Генерирует ключи x25519, UUID, рандомные пути. Если выбран SSH hardening — создаёт нового sudo-пользователя, отключает `PermitRootLogin` и `PasswordAuthentication`, применяет дроп-ин с `MaxAuthTries 3` и `LoginGraceTime 30`.

В конце скрипт выведет блок значений — **сохраните его целиком**, он понадобится на следующем шаге:

```
=========================================
 Marzban panel (via SSH tunnel):
   ssh -L 8000:localhost:8000 root@<VPS1_IP>
   http://localhost:8000/<random_path>

 === Values for setup-vps2.sh ===
 VPS1_IP:        <ip>
 VPS1_PBK:       <public_key>
 VPS1_SHORT_ID:  <hex>
 UUID_LINK:      <uuid>
 XHTTP_PATH:     <hex>
=========================================
```

---

### Шаг 3. Установка VPS2 (Россия — входной сервер)

Подключитесь по SSH к VPS2 как root:

```bash
apt-get update && apt-get install tmux -y
tmux
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
bash <(wget -qO- https://raw.githubusercontent.com/patronJS/mytests/refs/heads/main/setup-vps2.sh)
```

Скрипт задаст вопросы — отвечайте, используя данные из вывода шага 2:

| Вопрос                      | Откуда взять                     |
| --------------------------- | -------------------------------- |
| Enter your domain           | Домен VPS2                       |
| Enter VPS1 IP address       | `VPS1_IP` из вывода шага 2       |
| Enter VPS1 public key (PBK) | `VPS1_PBK` из вывода шага 2      |
| Enter VPS1 short ID         | `VPS1_SHORT_ID` из вывода шага 2 |
| Enter inter-VPS UUID        | `UUID_LINK` из вывода шага 2     |
| Enter XHTTP path            | `XHTTP_PATH` из вывода шага 2    |
| Enter VPS1 domain           | `VPS1_DOMAIN` из вывода шага 2   |

Далее скрипт предложит опциональные настройки:

- **SSH hardening** — создание пользователя, запрет root-входа, аутентификация по ключу, смена порта, `MaxAuthTries 3`, `LoginGraceTime 30`

**fail2ban устанавливается автоматически на оба VPS** (jail `sshd`, backend `systemd`, `bantime=1h`, `findtime=10m`, `maxretry=5`). Проверить статус: `fail2ban-client status sshd`, снять бан: `fail2ban-client unban <ip>`.

После завершения всё готово к работе — отдельный шаг для связывания серверов не нужен.

**WARP — опционально, вручную на сервере** (если нужно вывести catch-all через Cloudflare WARP вместо VPS1):

```bash
# Включить: установит cloudflare-warp, зарегистрирует, пропатчит XRay
enable-warp.sh

# Отключить: вернёт catch-all обратно на chain-vps1
disable-warp.sh
```

---

### Шаг 4. Подключение клиентов

Управление пользователями ведётся через **панель VPS2**. URL и учётные данные выводятся в конце `setup-vps2.sh`.

**VLESS:**

1. Откройте панель VPS2
2. Создайте пользователя и получите VLESS-ссылку
3. Вставьте ссылку в клиент:
   - **iOS/macOS**: Streisand, V2Box, FoXray
   - **Android**: V2rayNG, NekoBox
   - **Windows**: Hiddify, Nekoray
   - **Linux**: Nekoray, Hiddify

### Проверка

Подключитесь и откройте [ipinfo.io](https://ipinfo.io) — должен показать IP VPS1 (Германия).

## Потоки трафика

```
# Всё по умолчанию — через цепочку VPS1 (немецкий IP)
VLESS-клиент  → VPS2:443   → XHTTP+REALITY → VPS1:49321 → Интернет (немецкий IP)
# (если включён WARP — catch-all уходит через Cloudflare WARP вместо VPS1)

# Трафик из exclude list — напрямую с VPS2
VLESS-клиент  → VPS2:443   → direct        → Интернет (российский IP)
```

### Exclude-list routing (VPS2)

По умолчанию **весь** трафик заворачивается через VPS1 (Германия). Только домены/IP, перечисленные в списке, выходят напрямую с VPS2 (российский IP) — это нужно для сервисов, которые блокируют иностранные IP (Госуслуги, Сбербанк, Яндекс и т. п.).

Управление маршрутами — два текстовых файла на VPS2:

| Файл                                     | Формат                | Пример                                                  |
| ---------------------------------------- | --------------------- | ------------------------------------------------------- |
| `/opt/xray-vps-setup/routes/domains.txt` | Один домен на строку  | `yandex.ru`, `geosite:category-ru`, `regexp:.*\.ru$`    |
| `/opt/xray-vps-setup/routes/ips.txt`     | IP или CIDR на строку | `77.88.8.0/24`, `geoip:ru`                              |

Пример содержимого `/opt/xray-vps-setup/routes/domains.txt`:

```
geosite:category-ru
geosite:category-gov-ru
geosite:yandex
geosite:vk

gosuslugi.ru
sberbank.ru
tinkoff.ru
```

Готовые списки российских сервисов: https://github.com/v2fly/domain-list-community (категории `category-ru`, `category-gov-ru`, `yandex`, `vk` и т. д.).

После редактирования — применить:

```bash
apply-routes.sh
```

Скрипт пересобирает routing rules в XRay-конфиге и рестартует контейнер.

## Управление

```bash
# Перезапуск стека (на любом VPS):
docker compose -f /opt/xray-vps-setup/docker-compose.yml down
docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d

# Логи:
docker compose -f /opt/xray-vps-setup/docker-compose.yml logs -f

# Редактирование маршрутов (VPS2):
nano /opt/xray-vps-setup/routes/domains.txt
nano /opt/xray-vps-setup/routes/ips.txt
apply-routes.sh
```

## Важные детали

- На VPS2 используются порты **80** и **443**; на VPS1 используются порты **80** и **49321**
- XRay core v26.3.27 (минимум для XHTTP)
- `flow: xtls-rprx-vision` **нельзя** ставить на XHTTP inbound/outbound
- `mode: packet-up` в chain outbound — предотвращает замораживание сессии TSPU при пакетах >15 KB
- `xPaddingBytes: 300-2000` — менее детектируемо, чем дефолтный диапазон 100-1000
- VPS1 использует steal_oneself с собственным доменом; ACME сертификаты генерируются автоматически
- Межсерверный канал `VPS2 -> VPS1` вынесен на нестандартный TCP-порт **49321**: это скрытый служебный линк, ему не требуется маскироваться под публичный HTTPS на `:443`
- **IPv6 полностью отключён** — sysctl на уровне ядра, `apt ForceIPv4`, все wget/curl с флагом `-4`, убраны IPv6-listener из Angie
- WARP (опционально) — catch-all (всё что не в exclude list) идёт через Cloudflare WARP вместо VPS1
- **fail2ban** — автоматически ставится на оба VPS, jail `sshd` (`bantime=1h`, `findtime=10m`, `maxretry=5`), использует systemd journal backend

## Geodata (geosite.dat / geoip.dat)

При установке скрипты скачивают **актуальные** `geosite.dat` и `geoip.dat` из официальных релизов [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community) и [v2fly/geoip](https://github.com/v2fly/geoip), заменяя устаревшие файлы из архива XRay.

На VPS2 настроено **автоматическое обновление** по cron (каждый понедельник в 04:00).

### Ручное обновление geodata

```bash
update-geodata.sh
```

Скрипт скачивает свежие `geosite.dat` и `geoip.dat` и перезапускает XRay.

### Доступные категории geosite

Полный список категорий: [v2fly/domain-list-community/data](https://github.com/v2fly/domain-list-community/tree/master/data)

Каждый файл в `data/` — одна категория. Например, файл `openai` → `geosite:openai`.

Проверить содержимое конкретной категории:

```bash
# Пример: что входит в geosite:category-ai-!cn
curl -s https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/category-ai-\!cn
```
