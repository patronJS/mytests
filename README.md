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
bash <(wget -qO- https://raw.githubusercontent.com/patronJS/mytests/refs/heads/main/setup-panel.sh)
```

Скрипт задаст вопрос:

| Вопрос            | Значение       |
| ----------------- | -------------- |
| Enter your domain | Домен для VPS1 |

Устанавливает Docker, XRay, Marzban, Angie. Генерирует ключи x25519, UUID, рандомные пути.

В конце скрипт выведет блок значений — **сохраните его целиком**, он понадобится на следующем шаге:

```
=========================================
 Marzban panel (via SSH tunnel):
   ssh -L 8000:localhost:8000 root@<VPS1_IP>
   http://localhost:8000/<random_path>

 === Values for setup-entry.sh ===
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
bash <(wget -qO- https://raw.githubusercontent.com/patronJS/mytests/refs/heads/main/setup-entry.sh)
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

- **SSH hardening** — создание пользователя, запрет root-входа, аутентификация по ключу, смена порта
- **WARP** — маршрутизация российских сайтов через Cloudflare WARP (вместо прямого выхода с VPS2)

После завершения всё готово к работе — отдельный шаг для связывания серверов не нужен.

---

### Шаг 4. Подключение клиентов

Управление пользователями ведётся через **панель VPS2**. URL и учётные данные выводятся в конце `setup-entry.sh`.

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
# Трафик из whitelist — через цепочку VPS1
VLESS-клиент  → VPS2:443   → XHTTP+REALITY → VPS1:49321 → Интернет (немецкий IP)

# Всё остальное — напрямую с VPS2 (или через WARP)
VLESS-клиент  → VPS2:443   → direct/WARP   → Интернет (российский IP)
```

### Whitelist routing (VPS2)

По умолчанию весь трафик идёт напрямую с VPS2. Только указанные домены/IP маршрутизируются через VPS1 (Германия).

Управление маршрутами — два текстовых файла на VPS2:

| Файл                                     | Формат                | Пример                                                  |
| ---------------------------------------- | --------------------- | ------------------------------------------------------- |
| `/opt/xray-vps-setup/routes/domains.txt` | Один домен на строку  | `netflix.com`, `geosite:netflix`, `regexp:.*\.example$` |
| `/opt/xray-vps-setup/routes/ips.txt`     | IP или CIDR на строку | `8.8.8.8`, `1.0.0.0/24`, `geoip:us`                     |

в файле /opt/xray-vps-setup/routes/domains.txt

geosite:google
geosite:anthropic
geosite:category-ai-!cn
geosite:category-ai-cn
geosite:category-cdn-!cn
geosite:category-cdn-cn
geosite:category-container
geosite:category-dev
geosite:category-dev-cn
geosite:spotify
geosite:stripe
geosite:telegram
geosite:z-library

ifconfig.me

ip.me
openrouter.ai

Далее отдельно Telegram, Instagram (списки берем тут https://github.com/v2fly/domain-list-community)

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
- WARP (опционально) — весь трафик не из whitelist идёт через Cloudflare WARP вместо прямого выхода

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
