# xray-vps-setup

Каскадный VLESS+REALITY через два VPS с WireGuard-туннелем. Обходит DPI, работает через XHTTP.

## Как это работает

Два сервера: VPS1 (выходной, Германия) и VPS2 (входной, Москва).

```
                         VPS2 (Москва)                      VPS1 (Германия)
                        ┌─────────────┐                    ┌──────────────┐
Клиент ──VLESS:443────► │ XRay        │ ──XHTTP+REALITY──► │ XRay         │ ──► Интернет
                        │             │                    │              │
Клиент ──WG:51820─────► │ wg-easy     │ ──WG-туннель:51830─►│ WG-туннель   │ ──► Интернет
                        └─────────────┘                    └──────────────┘
```

Два способа подключения клиента к VPS2:
- **VLESS+XHTTP+REALITY** (:443) — основной, максимальная защита от DPI, трафик выглядит как обычный HTTPS на обоих участках
- **WireGuard** (:51820) — опционально, через wg-easy с удобным web-интерфейсом. Шифрование есть, но протокол WireGuard детектируется DPI. Можно не использовать

Между VPS2 и VPS1 весь трафик идёт через:
- **XHTTP+REALITY** — для VLESS-клиентов (chain outbound через steal_oneself)
- **WG-туннель** (:51830) — для WireGuard-клиентов (p2p, policy routing)

Компоненты:
- **VPS1** — Marzban-панель + XRay XHTTP+REALITY inbound + WireGuard-туннель + NAT
- **VPS2** — Marzban-нода + XRay steal_oneself + chain outbound + wg-easy (опционально)

XRay слушает :443, обрабатывает VLESS с REALITY. Angie (форк nginx) занимается TLS-сертификатами через ACME и проксирует панель Marzban на рандомных путях. Для маскировки страницы используется [Confluence](https://github.com/Jolymmiles/confluence-marzban-home).

## Установка

### Что понадобится

- **2 VPS** с Ubuntu 24.04 и root-доступом:
  - VPS1 (Германия) — выходной сервер, панель управления
  - VPS2 (Москва) — входной сервер, точка подключения клиентов
- **2 домена** (или поддомена), по одному на каждый VPS
- **DNS A-записи** настроены заранее: каждый домен → IP своего VPS
- Порты **80** и **443** свободны на обоих серверах

> Скрипты интерактивные и долгие — `tmux` устанавливается на каждом шаге, чтобы не потерять сессию при обрыве SSH.

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

### Шаг 2. Установка VPS1 (Германия — панель)

Подключитесь по SSH к VPS1 как root:

```bash
apt-get update && apt-get install tmux -y
tmux
bash <(wget -qO- https://raw.githubusercontent.com/Akiyamov/xray-vps-setup/refs/heads/main/setup-panel.sh)
```

Скрипт спросит только **домен VPS1** и всё сделает автоматически:
- Установит Docker, XRay, Angie, Marzban, WireGuard
- Сгенерирует ключи, пароли, рандомные пути
- Настроит iptables и запустит стек

В конце скрипт выведет блок значений — **сохраните его целиком**, он понадобится на следующем шаге:

```
=========================================
 Panel URL: https://vps1.example.com/<random_path>
 Panel user: <random>
 Panel pass: <random>

 === Values for setup-node.sh ===
 PANEL_PBK:      <public_key>
 PANEL_SHORT_ID: <hex>
 UUID_LINK:      <uuid>
 XHTTP_PATH:     <hex>
 WG_TUNNEL_PBK:  <wireguard_public_key>
=========================================
```

---

### Шаг 3. Установка VPS2 (Москва — нода)

Подключитесь по SSH к VPS2 как root:

```bash
apt-get update && apt-get install tmux -y
tmux
bash <(wget -qO- https://raw.githubusercontent.com/Akiyamov/xray-vps-setup/refs/heads/main/setup-node.sh)
```

Скрипт задаст вопросы — отвечайте, используя данные из вывода шага 2:

| Вопрос | Откуда взять |
|--------|-------------|
| Enter your domain | Домен VPS2 |
| Enter VPS1 panel domain | Домен VPS1 |
| Enter VPS1 IP address | IP-адрес VPS1 |
| Enter VPS1 public key (PBK) | `PANEL_PBK` из вывода шага 2 |
| Enter VPS1 short ID | `PANEL_SHORT_ID` из вывода шага 2 |
| Enter inter-VPS UUID | `UUID_LINK` из вывода шага 2 |
| Enter XHTTP path | `XHTTP_PATH` из вывода шага 2 |
| Enter VPS1 WG tunnel public key | `WG_TUNNEL_PBK` из вывода шага 2 |
| Enter panel admin username | `Panel user` из вывода шага 2 |
| Enter panel admin password | `Panel pass` из вывода шага 2 |

Далее скрипт предложит опциональные настройки:

- **SSH hardening** — создание пользователя, запрет root-входа, аутентификация по ключу, смена порта
- **WARP** — маршрутизация российских сайтов через Cloudflare WARP

В конце скрипт выведет:

```
=========================================
 VLESS+XHTTP+REALITY (primary):
 vless://...

 VLESS+REALITY TCP (fallback):
 vless://...

 WireGuard UI: https://vps2.example.com/<random_path>/
 WG admin password: <random>

 === Run on VPS1 ===
 setup-panel.sh --add-wg-peer <WG_PBK> <VPS2_IP>
=========================================
```

**Сохраните VLESS-ссылки** — их нужно будет добавить в клиент.

---

### Шаг 4. Связать WG-туннель (обратно на VPS1)

Вернитесь на VPS1 и выполните команду из вывода шага 3:

```bash
bash setup-panel.sh --add-wg-peer <VPS2_WG_PBK> <VPS2_IP>
```

Скрипт добавит peer в WireGuard-туннель и проверит связность пингом.

---

### Шаг 5. Проверка

```bash
# На VPS1 — проверить туннель до VPS2:
ping 10.9.0.2

# На VPS2 — проверить туннель до VPS1:
ping 10.9.0.1
```

Если пинг проходит — туннель работает. Если нет — убедитесь, что порт **51830/udp** открыт на обоих серверах.

---

### Шаг 6. Подключение клиента

1. Скопируйте **VLESS-ссылку** из вывода шага 3
2. Вставьте в клиент:
   - **iOS/macOS**: Streisand, V2Box, FoXray
   - **Android**: V2rayNG, NekoBox
   - **Windows**: Hiddify, Nekoray
   - **Linux**: Nekoray, Hiddify
3. Подключитесь и проверьте IP на [ipinfo.io](https://ipinfo.io) — должен показать IP VPS1 (Германия)

> **VLESS+XHTTP+REALITY** — основная ссылка, максимальная защита от DPI.
> **VLESS+REALITY TCP** — запасная, если клиент не поддерживает XHTTP.
> **WireGuard** (опционально) — конфигурации создаются через web-интерфейс wg-easy.

## Подключение клиента

Скрипт `setup-node.sh` выдаёт готовые VLESS-ссылки:

- **VLESS+XHTTP+REALITY** (основной) — для клиентов с поддержкой XHTTP
- **VLESS+REALITY TCP** (fallback) — для остальных клиентов

WireGuard-конфигурации создаются через web-интерфейс wg-easy.

## Управление

```bash
# Перезапуск стека (на любом VPS):
docker compose -f /opt/xray-vps-setup/docker-compose.yml down
docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d

# Логи:
docker compose -f /opt/xray-vps-setup/docker-compose.yml logs -f
```

## Добавляем подписку и поддержку Mihomo

```bash
bash <(wget -qO- https://github.com/legiz-ru/marz-sub/raw/main/marz-sub.sh)
```

После этого перезапустите стек:

```bash
docker compose -f /opt/xray-vps-setup/docker-compose.yml down && docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d
```

## Важные детали

- Порты 80, 443, 4123 зарезервированы — SSH не может их использовать
- XRay core пригвождён к v26.3.23 (минимум для XHTTP)
- `flow: xtls-rprx-vision` **нельзя** ставить на XHTTP inbound/outbound
- WG-туннель VPS2 использует `Table = off`, чтобы wg-quick не перехватывал маршруты хоста
- NAT только на VPS1; VPS2 использует policy routing без MASQUERADE
- marzban-node запускается **после** получения ssl_client_cert.pem с панели

## Связь

Issues, PR или мой [тг](https://t.me/Akiyamov).
