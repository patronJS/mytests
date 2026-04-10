# Full-Tunnel VPN (Synology + Mikrotik)

Весь трафик vpn-clients через VLESS+REALITY прокси на VPS.

## Архитектура

```
LAN-клиенты
  |
  | трафик от устройств из address-list vpn-clients
  v
Mikrotik (mangle: mark via-wg)
  |
  | WireGuard-туннель (UDP :51820)
  v
Synology NAS (192.168.88.20)
  |
  v
wg-easy (WG-сервер, интерфейс wg0)
  |
  | policy routing: iif wg0 -> table 100 -> default via tun0
  v
sing-box (интерфейс tun0, stack: system, общий network namespace с wg-easy)
  |
  | весь трафик --> VLESS+REALITY --> VPS --> Интернет
```

### Компоненты

| Контейнер | Образ | Назначение |
|-----------|-------|------------|
| wg-easy | `ghcr.io/wg-easy/wg-easy:15.2.2` | WireGuard-сервер + Web UI |
| sing-box | `ghcr.io/sagernet/sing-box:v1.13.6` | TUN-прокси, весь трафик через VLESS |

## Структура файлов

```
synology-split-tunnel/
├── docker-compose.yml
├── sing-box/
│   └── config.json          # <-- подставить VLESS credentials
├── scripts/
│   ├── setup-routing.sh     # policy routing (wg0 → tun0)
│   └── ip6tables-stub.sh    # заглушка для Synology DSM
└── wg-data/                 # создаётся автоматически wg-easy
```

## Установка

### 1. Заполнить VLESS credentials

Отредактировать `sing-box/config.json` — заменить 4 плейсхолдера:

```json
"server": "<YOUR_VPS_IP>",
"uuid": "<YOUR_UUID>",
"public_key": "<YOUR_REALITY_PUBLIC_KEY>",
"short_id": "<YOUR_SHORT_ID>"
```

Значения взять из панели Marzban или существующего конфига.

### 2. Скопировать на Synology

```bash
mkdir -p /volume1/docker/synology-split-tunnel

# scp, rsync или Synology File Station — любой способ
# Результат:
# /volume1/docker/synology-split-tunnel/docker-compose.yml
# /volume1/docker/synology-split-tunnel/sing-box/config.json
# /volume1/docker/synology-split-tunnel/scripts/setup-routing.sh
# /volume1/docker/synology-split-tunnel/scripts/ip6tables-stub.sh

chmod +x /volume1/docker/synology-split-tunnel/scripts/setup-routing.sh
chmod +x /volume1/docker/synology-split-tunnel/scripts/ip6tables-stub.sh
```

### 3. Остановить старый стек (если запущен)

```bash
cd /volume1/docker/synology-split-tunnel
docker compose down
```

При миграции со старой связки `tun2socks + mihomo` сохранить `./wg-data/` — там WireGuard-ключи. Mikrotik-пир переподключится без перенастройки.

### 4. Запуск

```bash
cd /volume1/docker/synology-split-tunnel
docker compose up -d
```

### 5. Проверка запуска

```bash
docker logs sing-box

# Ожидаемый вывод:
# [routing] wg0 is up
# [routing] iptables rules applied
# [routing] table 100: LAN via wg0, waiting for tun0...
# [routing] setup complete
# [routing] default route set to tun0 — full proxy mode
```

### 6. Тест с ПК из vpn-clients

```bash
# Должен вернуть IP VPS (не провайдера)
curl -s https://ifconfig.me

# Проверка DNS — не должно быть DNS провайдера
# Открыть https://dnsleaktest.com
```

## Настройка Mikrotik

Если WG-туннель уже настроен — **менять ничего не нужно**.

```routeros
# Проверить что всё на месте:
/ip firewall address-list print where list=vpn-clients
/ip firewall mangle print where new-routing-mark=via-wg
/interface wireguard print
```

### MSS clamping (обязательно)

Без MSS clamping сайты грузятся медленно или не грузятся вовсе из-за фрагментации пакетов в WG-туннеле.

```routeros
/ip firewall mangle add chain=forward protocol=tcp tcp-flags=syn out-interface=wg-tunnel action=change-mss new-mss=clamp-to-pmtu passthrough=yes comment="MSS clamp WG out"
/ip firewall mangle add chain=forward protocol=tcp tcp-flags=syn in-interface=wg-tunnel action=change-mss new-mss=clamp-to-pmtu passthrough=yes comment="MSS clamp WG in"
```

### Исключение сервисов из туннеля

Некоторые сервисы (корпоративные VPN, банковские приложения и т.д.) не работают через цепочку прокси из-за MTU или гео-ограничений. Их нужно пускать напрямую, минуя WG-туннель.

Правило ставится **перед** `via-wg` (параметр `place-before=3`):

```routeros
# Исключить IP из туннеля (трафик пойдёт напрямую)
/ip firewall mangle add chain=prerouting action=accept dst-address=89.175.46.105 src-address-list=vpn-clients comment="HSE VPN direct" place-before=3

# Можно добавить несколько адресов или подсети
/ip firewall mangle add chain=prerouting action=accept dst-address=1.2.3.0/24 src-address-list=vpn-clients comment="Bank direct" place-before=3
```

Проверить порядок правил:
```routeros
/ip firewall mangle print
# accept-правила должны стоять ДО правила с mark-routing via-wg
```

### Управление списком vpn-clients

```routeros
# Добавить устройство
/ip firewall address-list add list=vpn-clients address=192.168.88.100

# Удалить устройство
/ip firewall address-list remove [find where list=vpn-clients address=192.168.88.100]

# Показать текущий список
/ip firewall address-list print where list=vpn-clients
```

### Настройка Mikrotik с нуля

См. [../docs/](../docs/) — полная конфигурация WireGuard + mangle.

## Диагностика

| Симптом | Что проверить |
|---------|---------------|
| sing-box не запускается | `docker logs sing-box` — ошибка в config.json |
| Нет интернета у vpn-clients | `docker logs sing-box` — есть ли `default route set to tun0` |
| Сайты не открываются | MSS clamping на Mikrotik (см. выше) |
| Медленная загрузка | Проверить CPU Synology; MSS clamping; `stack: system` в config.json |
| VPN/сервис поверх туннеля не работает | Исключить IP из туннеля (см. «Исключение сервисов») |
| VPS недоступен | VLESS credentials в config.json |
| WG handshake не проходит | Сверить ключи в wg-easy Web UI и peer на Mikrotik |
| Web UI wg-easy недоступен | `http://192.168.88.20:51821` (только из LAN) |

### Полезные команды

```bash
# Логи sing-box
docker logs -f sing-box

# Статус WG-туннеля
docker exec wg-easy wg show

# Policy routing внутри контейнера
docker exec sing-box ip rule list
docker exec sing-box ip route show table 100

# Перезапустить sing-box (после изменения конфига)
docker restart sing-box
```

## Безопасность

- Web UI wg-easy (`51821/tcp`) доступен только из LAN
- VLESS credentials в `config.json` — ограничить права: `chmod 600`
- WireGuard-ключи в `./wg-data/` — ограничить доступ к директории
