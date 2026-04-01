# xray-vps-setup

Каскадный VLESS+REALITY через два VPS с маршрутизацией WireGuard через TPROXY. Обходит DPI, весь трафик выходит с немецкого IP.

## Как это работает

Два сервера: VPS1 (Германия — выходной) и VPS2 (Россия — входной).

```
VPS1 (Германия — exit)               VPS2 (Россия — entry)
┌─────────────────────┐            ┌──────────────────────────┐
│ Marzban panel       │            │ Marzban panel            │
│ (технический,       │            │ (управление клиентами)   │
│  1 пользователь)    │            │                          │
│                     │            │ XRay inbounds:           │
│ XRay inbound        │◄──XHTTP───│  - VLESS+REALITY :443    │
│ XHTTP+REALITY :443  │  +REALITY │  - TPROXY (dokodemo-door)│
│                     │            │                          │
│ Angie (TLS, ACME)   │            │ XRay chain outbound      │
│                     │            │                          │
│ Нет WireGuard       │            │ wg-easy :51820           │
│ Нет NAT             │            │ Angie (TLS, ACME)        │
└─────────────────────┘            └──────────────────────────┘
```

Два способа подключения клиента к VPS2:

- **VLESS+XHTTP+REALITY** (:443) — основной, максимальная защита от DPI, трафик выглядит как обычный HTTPS
- **WireGuard** (:51820) — через wg-easy с web-интерфейсом; WG-трафик прозрачно перехватывается TPROXY и уходит через XRay chain на VPS1

Между VPS2 и VPS1 весь трафик идёт по **XHTTP+REALITY** — отдельного WG-туннеля между серверами нет.

Компоненты:

- **VPS1** — Marzban-панель + XRay XHTTP+REALITY inbound. WireGuard на VPS1 отсутствует
- **VPS2** — Независимая Marzban-панель + XRay (VLESS inbound + TPROXY + chain outbound) + wg-easy

Клиенты создаются в панели VPS2. Оба типа подключений (VLESS и WG) выходят в интернет с IP VPS1 (Германия).

XRay слушает :443 и :51820. Angie (форк nginx) занимается TLS через ACME и проксирует панели на рандомных путях. Для маскировки страницы используется [Confluence](https://github.com/Jolymmiles/confluence-marzban-home).

## Установка

### Что понадобится

- **2 VPS** с Ubuntu 24.04 и root-доступом:
  - VPS1 (Германия) — выходной сервер
  - VPS2 (Россия) — входной сервер, точка подключения клиентов
- **2 домена** (или поддомена), по одному на каждый VPS
- **DNS A-записи** настроены заранее: каждый домен → IP своего VPS
- Порты **80**, **443**, **4123** свободны на обоих серверах

> Скрипты интерактивные и долгие — рекомендуется запускать через `tmux`, чтобы не потерять сессию при обрыве SSH.

---

### Шаг 1. Подготовка DNS

Перед началом убедитесь, что DNS-записи уже распространились:

```bash
# Проверить, что домены указывают на нужные IP:
dig +short vps1.example.com   # должен вернуть IP VPS1
dig +short vps2.example.com   # должен вернуть IP VPS2
```

Если записи ещё не обновились — подождите. Скрипты проверяют DNS и предупредят, если запись не совпадает.

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

Скрипт спросит только **домен VPS1** и всё сделает автоматически:

- Установит Docker, XRay, Angie, Marzban
- Сгенерирует ключи, UUID, рандомные пути

В конце скрипт выведет блок значений — **сохраните его целиком**, он понадобится на следующем шаге:

```
=========================================
 Panel URL:     https://vps1.example.com/<random_path>
 Panel user:    <random>
 Panel pass:    <random>

 === Values for setup-entry.sh ===
 VPS1_DOMAIN:    vps1.example.com
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

| Вопрос                          | Откуда взять                       |
| ------------------------------- | ---------------------------------- |
| Enter your domain               | Домен VPS2                         |
| Enter VPS1 domain               | `VPS1_DOMAIN` из вывода шага 2     |
| Enter VPS1 IP address           | IP-адрес VPS1                      |
| Enter VPS1 public key (PBK)     | `VPS1_PBK` из вывода шага 2        |
| Enter VPS1 short ID             | `VPS1_SHORT_ID` из вывода шага 2   |
| Enter inter-VPS UUID            | `UUID_LINK` из вывода шага 2       |
| Enter XHTTP path                | `XHTTP_PATH` из вывода шага 2      |

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

**WireGuard:**

1. Откройте web-интерфейс wg-easy (URL выводится в конце скрипта)
2. Создайте peer и скачайте конфигурацию

Проверьте IP после подключения на [ipinfo.io](https://ipinfo.io) — должен показать IP VPS1 (Германия).

## Потоки трафика

```
VLESS-клиент  → VPS2:443  → XHTTP+REALITY → VPS1:443 → Интернет
WG-клиент     → VPS2:51820 → TPROXY → XRay chain → VPS1:443 → Интернет
```

Межсерверного WireGuard-туннеля нет — всё межсерверное взаимодействие идёт через XHTTP+REALITY.

## Управление

```bash
# Перезапуск стека (на любом VPS):
docker compose -f /opt/xray-vps-setup/docker-compose.yml down
docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d

# Логи:
docker compose -f /opt/xray-vps-setup/docker-compose.yml logs -f
```

## Важные детали

- Порты 80, 443, 4123 зарезервированы — SSH не может их использовать
- XRay core пригвождён к v26.3.23 (минимум для XHTTP)
- `flow: xtls-rprx-vision` **нельзя** ставить на XHTTP inbound/outbound
- `mode: "stream-one"` зафиксирован в chain outbound (в `auto` есть баг #5635)
- На VPS1 нет WireGuard — ни клиентского, ни туннельного
- WG-клиенты выходят в интернет с немецким IP через TPROXY → XRay chain → VPS1
- Перед запуском скриптов отключите IPv6: `sysctl -w net.ipv6.conf.all.disable_ipv6=1` и `sysctl -w net.ipv6.conf.default.disable_ipv6=1`

## Связь

Issues, PR или мой [тг](https://t.me/Akiyamov).
