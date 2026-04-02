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
- Порты **80**, **443** свободны на обоих VPS; порт **49321** свободен на VPS1

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

| Вопрос           | Значение            |
| ---------------- | ------------------- |
| Enter your domain | Домен для VPS1      |

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

Далее скрипт предложит опциональные настройки:

- **SSH hardening** — создание пользователя, запрет root-входа, аутентификация по ключу, смена порта
- **WARP** — маршрутизация российских сайтов через Cloudflare WARP

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
VLESS-клиент  → VPS2:443   → XHTTP+REALITY → VPS1:49321 → Интернет
```

## Управление

```bash
# Перезапуск стека (на любом VPS):
docker compose -f /opt/xray-vps-setup/docker-compose.yml down
docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d

# Логи:
docker compose -f /opt/xray-vps-setup/docker-compose.yml logs -f
```

## Важные детали

- Порты 80 и 443 зарезервированы на обоих VPS; порт 49321 — на VPS1 для межсерверного соединения
- XRay core v26.3.27 (минимум для XHTTP)
- `flow: xtls-rprx-vision` **нельзя** ставить на XHTTP inbound/outbound
- `mode: packet-up` в chain outbound — предотвращает замораживание сессии TSPU при пакетах >15 KB
- `xPaddingBytes: 300-2000` — менее детектируемо, чем дефолтный диапазон 100-1000
- VPS1 использует steal_oneself с собственным доменом; ACME сертификаты генерируются автоматически
- IPv6 необходимо отключить до запуска скриптов
