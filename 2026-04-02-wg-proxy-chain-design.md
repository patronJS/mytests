# WireGuard + tun2socks + mihomo Proxy Chain

## Обзор

Full-tunnel VPN-цепочка: весь трафик двух ПК в LAN проходит через MikroTik по WireGuard-туннелю на Synology NAS, где проксируется через mihomo (VLESS) в интернет.

**Целевые ПК:** `192.168.88.21`, `192.168.88.6`

## Топология сети

```
┌─────────────┐     LAN      ┌──────────────┐    WG tunnel    ┌──────────────────────────────────────────┐
│  PC (.21)   │──────────────▶│              │────────────────▶│           Synology NAS (.20)             │
│  PC (.6)    │──────────────▶│  MikroTik    │                 │                                          │
│             │               │  RouterOS v7 │                 │  ┌─────────┐    ┌──────────┐   ┌───────┐ │
│             │               │              │                 │  │ wg-easy │───▶│tun2socks │──▶│mihomo │ │
│             │               │  192.168.88.1│                 │  │  (WG)   │    │  (tun0)  │   │SOCKS5 │ │
└─────────────┘               └──────────────┘                 │  └─────────┘    └──────────┘   └───┬───┘ │
                                                               │                                    │     │
                                                               │  192.168.88.20                     │     │
                                                               └────────────────────────────────────┼─────┘
                                                                                                    │
                                                                                              VLESS (TCP)
                                                                                                    │
                                                                                                    ▼
                                                                                           ┌──────────────┐
                                                                                           │ VPS (VLESS)  │
                                                                                           │5.129.201.31  │
                                                                                           │  :15127      │
                                                                                           └──────────────┘
                                                                                                    │
                                                                                                    ▼
                                                                                                Интернет
```

## Путь трафика

```
ПК (192.168.88.21 или .6)
  │
  │ Весь трафик (full tunnel)
  ▼
MikroTik — помечает трафик от .21 и .6 routing mark "via-wg"
  │
  │ WireGuard-туннель (UDP :51820)
  ▼
Контейнер wg-easy (Synology, интерфейс wg0, подсеть 10.8.0.0/24)
  │
  │ ip rule: трафик из wg0 → таблица маршрутов 100 → default via tun0
  ▼
Контейнер tun2socks (общий network namespace с wg-easy)
  │
  │ Инкапсулирует IP-пакеты в SOCKS5-поток
  ▼
mihomo (192.168.88.20:1182, SOCKS5-прокси)
  │
  │ VLESS over TLS + Reality
  ▼
VPS 5.129.201.31:15127 → Интернет
```

## Компоненты

### 1. mihomo (уже запущен)

Существующий Docker-контейнер на Synology. Изменения не требуются.

**Основные порты:**

- `1182` — SOCKS5-прокси
- `1180` — HTTP-прокси

**Конфиг прокси:**

- Протокол: VLESS
- Сервер: `5.129.201.31:15127`
- TLS: Reality (public-key, short-id)
- SNI: `yandex.ru`
- Fingerprint: firefox
- Режим: rule → весь трафик через `vless-server`

### 2. wg-easy (новый контейнер)

WireGuard-сервер с Web UI. MikroTik подключается как пир.

**Сеть:**

- Порт хоста: `51820/udp` (WireGuard)
- Порт хоста: `51821/tcp` (Web UI)
- Подсеть WG: `10.8.0.0/24`
- Адрес пира MikroTik: `10.8.0.2`

**Конфиг Docker:**

```yaml
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy
    container_name: wg-easy
    environment:
      - LANG=en
      - WG_HOST=192.168.88.20
      - WG_PORT=51820
      - WG_DEFAULT_DNS=1.1.1.1
      - WG_ALLOWED_IPS=0.0.0.0/0
      - WG_PERSISTENT_KEEPALIVE=25
    volumes:
      - ./wg-data:/etc/wireguard
      - ./scripts/setup-routing.sh:/iptables/setup-routing.sh:ro
    ports:
      - "51820:51820/udp"
      - "51821:51821/tcp"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
```

### 3. tun2socks (новый контейнер)

Мост между L3 (IP) трафиком WireGuard и L4 (SOCKS5) прокси mihomo. Нативно обрабатывает TCP и UDP.

**Почему tun2socks, а не redsocks:**

- Нативная поддержка UDP (redsocks — только TCP)
- DNS (UDP) проходит без костылей с конвертацией
- Один бинарник, без сложных цепочек iptables

**Конфиг Docker:**

```yaml
tun2socks:
  image: xjasonlyu/tun2socks:latest
  container_name: tun2socks
  volumes:
    - /dev/net/tun:/dev/net/tun
    - ./scripts/setup-routing.sh:/iptables/setup-routing.sh:ro
  cap_add:
    - NET_ADMIN
  network_mode: "service:wg-easy"
  depends_on:
    - wg-easy
  restart: unless-stopped
  entrypoint:
    - /bin/sh
    - -c
    - |
      sleep 5 && /iptables/setup-routing.sh &
      tun2socks -device tun0 -proxy socks5://192.168.88.20:1182 -interface eth0 -loglevel info
```

**Критично: `network_mode: "service:wg-easy"`** — tun2socks разделяет network namespace с wg-easy, получая доступ к интерфейсу `wg0` и возможность настраивать правила маршрутизации.

### 4. Скрипт маршрутизации (setup-routing.sh)

Выполняется внутри общего network namespace. Настраивает policy routing: трафик WG-клиентов идёт через tun0, а собственное SOCKS5-соединение tun2socks к mihomo идёт напрямую через eth0 (предотвращение петли маршрутизации).

```bash
#!/bin/sh
set -e

# Ждём интерфейс wg0
while ! ip link show wg0 >/dev/null 2>&1; do
    echo "[routing] waiting for wg0..."
    sleep 2
done

echo "[routing] wg0 is up, configuring routes..."

# Ждём создания tun0 контейнером tun2socks
while ! ip link show tun0 >/dev/null 2>&1; do
    echo "[routing] waiting for tun0..."
    sleep 2
done

# Назначаем IP на tun0
ip addr add 198.18.0.1/15 dev tun0 2>/dev/null || true
ip link set tun0 up 2>/dev/null || true

# Маршрут к mihomo (SOCKS5) — напрямую через eth0, НЕ через tun0
GATEWAY=$(ip route | grep default | awk '{print $3}')
ip route add 192.168.88.20/32 via $GATEWAY dev eth0 2>/dev/null || true

# Policy routing: трафик из wg0 использует таблицу 100
ip rule add iif wg0 table 100 priority 100 2>/dev/null || true

# Таблица 100: маршрут по умолчанию через tun0
ip route add default dev tun0 table 100 2>/dev/null || true

# NAT для исходящего трафика через tun0
iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE

echo "[routing] done — WG client traffic → tun0 → SOCKS5 → mihomo"
```

**Ключевые решения по маршрутизации:**

- `ip rule add iif wg0 table 100` — только пакеты от WG-клиентов используют прокси-маршрут
- `ip route add 192.168.88.20/32 via $GATEWAY dev eth0` — предотвращает петлю: tun2socks достигает mihomo напрямую
- `iptables MASQUERADE on tun0` — NAT для IP-адресов WG-клиентов
- Full tunnel: в таблице 100 НЕТ обратных маршрутов для локальных подсетей

### 5. MikroTik RouterOS v7

Нативная поддержка WireGuard. Подключается как пир к wg-easy. Использует policy-based routing (mangle + таблица маршрутов) для отправки трафика двух конкретных IP через WG-туннель.

```routeros
# ── Интерфейс WireGuard ──
/interface wireguard add name=wg-tunnel listen-port=0 \
    private-key="<сгенерировать: wg genkey>"

# ── Пир: Synology wg-easy ──
# Взять public-key из Web UI wg-easy (http://192.168.88.20:51821)
/interface wireguard peers add interface=wg-tunnel \
    public-key="<из wg-easy>" \
    endpoint-address=192.168.88.20 \
    endpoint-port=51820 \
    allowed-address=0.0.0.0/0 \
    persistent-keepalive=25s

# ── IP на WG-интерфейсе ──
# Адрес, назначенный wg-easy (проверить в Web UI)
/ip address add address=10.8.0.2/24 interface=wg-tunnel

# ── Таблица маршрутов для VPN-трафика ──
/routing table add name=via-wg fib

# ── Маршрут по умолчанию через WG-туннель ──
/ip route add dst-address=0.0.0.0/0 gateway=wg-tunnel routing-table=via-wg

# ── Список адресов: ПК, идущие через VPN ──
/ip firewall address-list add list=vpn-clients address=192.168.88.21
/ip firewall address-list add list=vpn-clients address=192.168.88.6

# ── Mangle: пометка маршрутов для VPN-клиентов ──
/ip firewall mangle add chain=prerouting \
    src-address-list=vpn-clients \
    action=mark-routing \
    new-routing-mark=via-wg \
    passthrough=yes

# ── Правило маршрутизации ──
/routing rule add action=lookup-only-in-table \
    table=via-wg \
    src-address=192.168.88.0/24 \
    routing-mark=via-wg

# ── NAT для WG-трафика ──
/ip firewall nat add chain=srcnat \
    out-interface=wg-tunnel \
    action=masquerade

# ── Блокировка QUIC для VPN-клиентов (КРИТИЧНО — предотвращает утечку IP) ──
# QUIC (HTTP/3) использует UDP:443. tun2socks не корректно обрабатывает
# SOCKS5 UDP ASSOCIATE для QUIC, что приводит к утечке UDP-пакетов
# мимо туннеля. Блокировка QUIC заставляет браузеры использовать HTTP/2 (TCP),
# который корректно проходит через tun2socks → mihomo → VLESS.
/ip firewall filter add chain=forward \
    src-address-list=vpn-clients \
    protocol=udp dst-port=443 \
    action=drop \
    comment="Block QUIC for VPN clients (force TCP, prevent UDP leak)"
```

**Добавление/удаление ПК:** достаточно отредактировать список адресов `vpn-clients` — правила mangle и маршрутизации менять не нужно.

## Полный docker-compose.yml

Расположение на Synology: `/volume1/docker/wg-proxy/docker-compose.yml`

```yaml
version: "3.8"

services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy
    container_name: wg-easy
    environment:
      - LANG=en
      - WG_HOST=192.168.88.20
      - WG_PORT=51820
      - WG_DEFAULT_DNS=1.1.1.1
      - WG_ALLOWED_IPS=0.0.0.0/0
      - WG_PERSISTENT_KEEPALIVE=25
    volumes:
      - ./wg-data:/etc/wireguard
      - ./scripts/setup-routing.sh:/iptables/setup-routing.sh:ro
    ports:
      - "51820:51820/udp"
      - "51821:51821/tcp"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped

  tun2socks:
    image: xjasonlyu/tun2socks:latest
    container_name: tun2socks
    volumes:
      - /dev/net/tun:/dev/net/tun
      - ./scripts/setup-routing.sh:/iptables/setup-routing.sh:ro
    cap_add:
      - NET_ADMIN
    network_mode: "service:wg-easy"
    depends_on:
      - wg-easy
    restart: unless-stopped
    entrypoint:
      - /bin/sh
      - -c
      - |
        sleep 5 && /iptables/setup-routing.sh &
        tun2socks -device tun0 -proxy socks5://192.168.88.20:1182 -interface eth0 -loglevel info
```

## Структура файлов на Synology

```
/volume1/docker/wg-proxy/
├── docker-compose.yml
├── scripts/
│   └── setup-routing.sh    # chmod +x
└── wg-data/                # создаётся автоматически wg-easy
```

## Порядок развёртывания

1. **Создать структуру каталогов на Synology:**

   ```bash
   mkdir -p /volume1/docker/wg-proxy/scripts
   mkdir -p /volume1/docker/wg-proxy/wg-data
   ```

2. **Скопировать файлы:**
   - `docker-compose.yml` → `/volume1/docker/wg-proxy/`
   - `setup-routing.sh` → `/volume1/docker/wg-proxy/scripts/`

   ```bash
   chmod +x /volume1/docker/wg-proxy/scripts/setup-routing.sh
   ```

3. **Запустить контейнеры:**

   ```bash
   cd /volume1/docker/wg-proxy
   docker-compose up -d
   ```

4. **Создать WG-клиента в Web UI wg-easy:**
   - Открыть `http://192.168.88.20:51821`
   - Создать нового клиента (например, "mikrotik")
   - Записать **public key** и **IP клиента** (10.8.0.2)

5. **Настроить MikroTik:**
   - Сгенерировать private key: `wg genkey` (или через CLI MikroTik)
   - Применить команды RouterOS из раздела 5
   - Использовать public key из шага 4

6. **Настроить DNS на целевых ПК (КРИТИЧНО — предотвращает DNS leak):**
   - На каждом ПК (`192.168.88.21`, `192.168.88.6`) задать DNS-серверы на уровне системы/соединения:
     - Основной: `1.1.1.1`
     - Резервный: `1.0.0.1`
   - **НЕ использовать MikroTik (`192.168.88.1`) как DNS** — MikroTik резолвит DNS локально (output chain), минуя mangle-правила WG-туннеля, что приводит к утечке DNS-запросов к провайдеру
   - При указании DNS-серверов напрямую запросы идут от IP ПК → mangle их ловит → трафик идёт через WG → tun2socks → mihomo → VLESS → резолвится за рубежом. DNS-резолвер видит только IP VPS, а не домашний IP
   - **Windows:** Параметры → Сеть и Интернет → адаптер → DNS → Вручную → `1.1.1.1`, `1.0.0.1`
   - **macOS:** Системные настройки → Сеть → адаптер → DNS → `1.1.1.1`, `1.0.0.1`
   - **Linux:** редактировать `/etc/resolv.conf` или соединение NetworkManager: `dns=1.1.1.1;1.0.0.1`

7. **Проверка:**
   - С ПК `192.168.88.21` или `.6` открыть `https://ifconfig.me`
   - Ожидаемый результат: IP VLESS-сервера (`5.129.201.31`) или его выходной IP
   - Проверить `https://dnsleaktest.com` — НЕ должно быть локальных/провайдерских DNS-серверов
   - Проверить `https://browserleaks.com/webrtc` — убедиться, что нет утечки реального IP через WebRTC

## MikroTik + AdGuard DNS Family (DoH)

Шифрованный DNS со встроенной фильтрацией рекламы, трекеров и adult-контента для всех клиентов LAN. DoH не позволяет провайдеру видеть DNS-запросы.

### Шаг 1 — Временный DNS для bootstrap

```routeros
/ip dns set servers=94.140.14.15,94.140.15.16 use-doh-server="" verify-doh-cert=no
```

### Шаг 2 — Импорт CA-сертификатов

```routeros
/tool fetch url="https://curl.se/ca/cacert.pem" dst-path=cacert.pem
/certificate import file-name=cacert.pem passphrase=""
```

Дождаться сообщения `certificates-imported: 144` (или около того).

### Шаг 3 — Включить DoH

```routeros
/ip dns set \
  use-doh-server=https://family.adguard-dns.com/dns-query \
  verify-doh-cert=yes \
  servers=94.140.14.15,94.140.15.16 \
  allow-remote-requests=yes
```

> `servers` с plain IP оставляем — это bootstrap + fallback. DoH используется как приоритетный резолвер.

### Шаг 4 — Принудительный редирект DNS для НЕ-VPN клиентов (защита от обхода)

```routeros
/ip firewall nat add chain=dstnat protocol=udp dst-port=53 \
    src-address-list=!vpn-clients \
    action=redirect to-ports=53 comment="Force DNS (non-VPN)"
/ip firewall nat add chain=dstnat protocol=tcp dst-port=53 \
    src-address-list=!vpn-clients \
    action=redirect to-ports=53 comment="Force DNS (non-VPN)"
```

> DNS-запросы от обычных LAN-клиентов (даже с хардкодом `8.8.8.8`) перехватываются и резолвятся MikroTik'ом через DoH. VPN-клиенты (`.21`, `.6`) **исключены** — их DNS идёт через WG-туннель → tun2socks → mihomo → VLESS → VPS, чтобы DNS-резолвер видел IP VPS, а не домашний IP.

### Шаг 5 — Проверка

```routeros
/ping google.com count=3
/ip dns cache print
```

### Итоговый конфиг: `/ip dns print`

```
servers: 94.140.14.15,94.140.15.16
use-doh-server: https://family.adguard-dns.com/dns-query
verify-doh-cert: yes
allow-remote-requests: yes
```

Конфигурация переживает перезагрузку роутера.

**Разделение DNS для VPN и обычных клиентов:**
- Обычные LAN-клиенты → DNS перехватывается MikroTik'ом → AdGuard DoH (шифрованный, с фильтрацией)
- VPN-клиенты (`.21`, `.6`) → DNS идёт через WG-туннель → tun2socks → mihomo → VLESS → VPS → резолвится на выходном узле. Это гарантирует, что DNS-резолвер видит IP VPS, а не домашний IP, и Google/сайты корректно определяют геолокацию по VPS

## Диагностика

| Симптом                                           | Что проверить                                                                                                |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| WG-туннель поднят, но интернета нет               | `docker logs tun2socks` — убедиться, что есть сообщение "[routing] done"                                     |
| Петля маршрутизации (нет связи)                   | Проверить наличие маршрута `192.168.88.20/32 via $GATEWAY dev eth0`                                          |
| DNS не резолвится                                 | Проверить, пропускает ли tun2socks UDP; попробовать `WG_DEFAULT_DNS=8.8.8.8`                                 |
| DNS leak (сайты определяют реальное расположение) | ПК должны использовать `1.1.1.1` / `1.0.0.1` как DNS, НЕ MikroTik — проверить на `dnsleaktest.com` |
| QUIC/UDP leak (Google показывает Россию, ifconfig.me — Германию) | Проверить наличие правила `drop UDP:443` для vpn-clients в `/ip firewall filter`; QUIC утекает мимо tun2socks |
| Работает только один ПК                           | Проверить, что оба IP в списке `vpn-clients` на MikroTik                                                     |
| Web UI wg-easy недоступен                         | Проверить, не блокирует ли файрвол Synology порт `51821`                                                     |
| Не проходит WG handshake на MikroTik              | Проверить совпадение endpoint, порта и public keys на обеих сторонах                                         |

## Заметки по безопасности

- Web UI wg-easy (`51821/tcp`) по умолчанию без авторизации — ограничить доступ файрволом Synology или задать переменную `PASSWORD`
- SOCKS5 mihomo (`1182`) открыт в LAN (`bind-address: '*'`) — допустимо для доверенной сети, но стоит учитывать
- VLESS Reality обеспечивает надёжное шифрование и устойчивость к цензуре
- Ключи WireGuard хранятся в `./wg-data/` — защитить эту директорию
