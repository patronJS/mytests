# USA-туннель (Synology + Mikrotik): WireGuard → VLESS → OpenVPN

Трафик устройств из address-list `vpn-clients` выходит в интернет с OpenVPN-сервера в США.
Соединение OpenVPN идёт внутри VLESS+REALITY: провайдер и DPI видят только TLS до VLESS-сервера.

## Архитектура

```
ПК (vpn-clients) → Mikrotik → WireGuard → Synology → VLESS-сервер → OpenVPN-сервер (США) → Интернет
```

Внутри Synology (все контейнеры в одном network namespace wg-easy):

```
wg0 ──ip rule iif wg0──▶ table 100: default dev tun0      (ставит route-up.sh после подключения)
                                    unreachable default    (kill switch, есть всегда)
        │ MASQUERADE -o tun0
        ▼
openvpn (tun0) ──TCP через SOCKS 127.0.0.1:1080──▶ sing-box ──VLESS+REALITY──▶ eth0
```

OpenVPN не меняет основную таблицу маршрутизации: маршрут sing-box до VLESS-сервера остаётся через `eth0`.
В `tun0` уходит только трафик, пришедший из `wg0`. Нет `tun0` — трафик из `wg0` блокируется (kill switch), мимо цепочки он не уходит.

| Кто | Что видит |
|-----|-----------|
| Провайдер / DPI | TLS до VLESS-сервера |
| VLESS-сервер | зашифрованный поток OpenVPN до сервера в США |
| OpenVPN-сервер | трафик клиентов с IP VLESS-сервера |
| Сайты | IP OpenVPN-сервера (США) |

### Контейнеры

| Контейнер | Образ | Назначение |
|-----------|-------|------------|
| wg-easy | `ghcr.io/wg-easy/wg-easy:15.2.2` | WireGuard-сервер + Web UI |
| sing-box | `ghcr.io/sagernet/sing-box:v1.13.6` | SOCKS `127.0.0.1:1080` → VLESS+REALITY |
| openvpn | собирается из `openvpn-client/` | OpenVPN-клиент (`tun0`), kill switch и policy routing |

## Структура файлов

```
Synology-USA-tunnel/
├── docker-compose.yml
├── sing-box/config.json        # <-- подставить VLESS credentials
├── openvpn/                    # <-- положить профиль OpenVPN (не коммитится)
│   ├── <любое-имя>.ovpn        #     ровно один профиль
│   └── cred.txt                #     логин и пароль, если профиль требует auth-user-pass
├── openvpn-client/             # образ OpenVPN-клиента (Dockerfile, entrypoint.sh, route-up.sh)
├── scripts/
│   ├── setup-routing.sh        # kill switch, форвардинг, NAT, LAN-маршруты
│   └── ip6tables-stub.sh       # заглушка для Synology DSM
├── tests/                      # локальные тесты (Docker), на Synology не нужны
└── wg-data/                    # создаётся wg-easy (ключи WireGuard)
```

## Установка

### 1. Заполнить VLESS credentials

В `sing-box/config.json` заменить 5 плейсхолдеров:

```json
"server": "<YOUR_VPS_IP>",
"uuid": "<YOUR_UUID>",
"server_name": "<YOUR_SNI>",
"public_key": "<YOUR_REALITY_PUBLIC_KEY>",
"short_id": "<YOUR_SHORT_ID>"
```

Значения взять из панели Marzban или существующего конфига. Если VLESS-сервер требует `flow`, добавить его в outbound.

### 2. Положить профиль OpenVPN

В `openvpn/` положить **ровно один** файл `*.ovpn` и всё, на что он ссылается по относительному пути (`ca.crt`, `client.key` и т.п.). Если в профиле есть строка `auth-user-pass`, рядом положить `cred.txt` из двух строк:

```
логин
пароль
```

Требования к профилю (иначе контейнер `openvpn` не стартует и пишет `ERROR` в лог):

- **Только TCP**: `proto tcp` (или `tcp-client`, `tcp4-client`) либо суффикс `tcp` в каждой строке `remote`. UDP через SOCKS-прокси не работает.
- **`remote` только с IPv4-адресом**. Имя хоста пришлось бы резолвить через DNS провайдера, мимо VLESS. Заменить имя на IP: `dig +short vpn.example.com`.
- Без блоков `<connection>` и директивы `config`.

Сам файл не меняется. При старте из него собирается `/tmp/run.ovpn`: удаляются `dev`, `dev-type`, `up`, `down`, `script-security`, `route-up`, `redirect-gateway`, `socks-proxy`, `http-proxy`, `auth-user-pass`; добавляются `dev tun0`, `dev-type tun`, `socks-proxy 127.0.0.1 1080`, `route-nopull`, `route-noexec`, `script-security 2`, `route-up /route-up.sh` и `auth-user-pass /openvpn/cred.txt`. Маршруты, которые присылает сервер или которые записаны в профиле, игнорируются.

### 3. Скопировать на Synology

```bash
mkdir -p /volume1/docker/Synology-USA-tunnel

# scp, rsync или Synology File Station — всю папку Synology-USA-tunnel/ (tests/ можно не копировать)

cd /volume1/docker/Synology-USA-tunnel
chmod +x scripts/*.sh openvpn-client/*.sh
chmod 600 sing-box/config.json openvpn/*
```

### 4. Остановить другой стек

Этот стек и `synology-split-tunnel` используют одни порты (51820/udp, 51821/tcp), поэтому одновременно работает только один. Имена контейнеров у стеков разные, так что оба можно держать развёрнутыми в Container Manager. Перед запуском остановить стек VLESS:

```bash
cd /volume1/docker/synology-split-tunnel
docker compose stop
```

Политика перезапуска задаётся при создании контейнера, поэтому уже развёрнутый VLESS-стек нужно один раз пересоздать: скопировать на Synology обновлённый `synology-split-tunnel/docker-compose.yml` (там `restart: "no"`) и выполнить

```bash
cd /volume1/docker/synology-split-tunnel
docker compose up --no-start    # пересоздаёт контейнеры, не запуская их
```

Проверка после запуска USA-стека (шаг 5) — `no` у двух VLESS-контейнеров и `always` у трёх USA-контейнеров:

```bash
docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' wg-easy sing-box wg-easy-usa sing-box-usa openvpn-usa
```

Чтобы Mikrotik-пир подключался к обоим стекам без перенастройки, ключи WireGuard должны быть одинаковыми: скопировать `wg-data/` из `synology-split-tunnel` в `Synology-USA-tunnel`. Настройки WireGuard (Host, Port, DNS, Allowed IPs, Keepalive) в wg-easy v15 задаются в Web UI и хранятся в `wg-data/`.

### 5. Запуск

```bash
cd /volume1/docker/Synology-USA-tunnel
docker compose up -d --build
```

### 6. Проверка запуска

```bash
docker logs openvpn-usa

# Ожидаемый вывод (фрагменты):
# [routing] kill switch: wg0 traffic blocked unless tun0 is up
# [routing] wg0 is up
# [routing] using iptables-legacy
# [routing] iptables rules applied
# [routing] setup complete
# [openvpn] profile: /openvpn/<имя>.ovpn
# ... Initialization Sequence Completed
# [route-up] table 100: default dev tun0
```

### 7. Тест с ПК из vpn-clients

```bash
# Должен вернуть IP OpenVPN-сервера в США (не провайдера и не VLESS-сервера)
curl -s https://ifconfig.me
```

Проверка kill switch:

```bash
docker stop openvpn-usa   # на ПК интернета нет
docker start openvpn-usa  # через 10–60 с интернет вернулся, IP снова американский
docker stop sing-box-usa  # на ПК интернета нет
docker start sing-box-usa # OpenVPN переподключается сам (до нескольких минут)
```

## Переключение USA ↔ VLESS

Работает один стек: по умолчанию USA. После перезагрузки DSM всегда поднимается USA-стек (`restart: always`), VLESS-стек сам не запускается (`restart: "no"`).

| Куда | Container Manager | Или по SSH |
|------|-------------------|------------|
| USA → VLESS | Проект `Synology-USA-tunnel` → «Остановить», затем `synology-split-tunnel` → «Запустить» | `cd /volume1/docker/Synology-USA-tunnel && docker compose stop && cd ../synology-split-tunnel && docker compose up -d` |
| VLESS → USA | Проект `synology-split-tunnel` → «Остановить», затем `Synology-USA-tunnel` → «Запустить» | `cd /volume1/docker/synology-split-tunnel && docker compose stop && cd ../Synology-USA-tunnel && docker compose up -d` |

Ошибка `port is already allocated` при запуске значит, что второй стек ещё работает: сначала остановить его.

## Восстановление

| Ситуация | Команда |
|----------|---------|
| Перезапущен или пересоздан только wg-easy (обновление образа, `up` только для wg-easy) | `docker compose up -d --force-recreate sing-box openvpn` — sing-box и openvpn остаются в старом namespace, а в новом форвардинг выключен |
| Изменён профиль или `cred.txt` | `docker restart openvpn-usa` |
| Изменён `sing-box/config.json` | `docker restart sing-box-usa` (OpenVPN переподключится сам) |
| Обновить образ OpenVPN-клиента | `docker compose build --pull openvpn && docker compose up -d openvpn` |

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
| `openvpn` перезапускается, в логе `[openvpn] ERROR: ...` | Профиль отклонён, причина в сообщении: UDP, имя хоста в `remote`, `<connection>`, `config`, нет `cred.txt`, ноль или несколько `.ovpn` |
| В логе `AUTH_FAILED` | Логин/пароль в `openvpn/cred.txt` |
| Нет строки `[route-up]`, в логе повторяются попытки подключения к `127.0.0.1:1080` | sing-box или VLESS: `docker logs sing-box-usa`, credentials в `config.json` |
| `[routing] ERROR: iptables not found` или `cannot add iptables rules` | Ядро DSM не поддерживает нужный netfilter. Проверить: `docker run --rm --privileged --entrypoint iptables-legacy usa-tunnel-openvpn -t nat -S` |
| Нет интернета у vpn-clients, в логе всё без ошибок | `docker exec openvpn-usa ip route show table 100` — должна быть строка `default dev tun0`. Без неё трафик блокируется kill switch (намеренно) |
| Сайты не открываются или грузятся частично | MSS clamping на Mikrotik (см. выше) |
| Медленно | TCP внутри TCP (OpenVPN/TCP через VLESS) проседает при потерях — это свойство схемы. Проверить MSS clamping и CPU Synology |
| WG handshake не проходит | Сверить ключи в wg-easy Web UI и peer на Mikrotik |
| Web UI wg-easy недоступен | `http://192.168.88.20:51821` (только из LAN) |

### Полезные команды

```bash
docker logs -f openvpn-usa                      # kill switch, OpenVPN, route-up
docker logs -f sing-box-usa                     # VLESS
docker exec wg-easy-usa wg show                 # WireGuard
docker exec openvpn-usa ip rule show            # должно быть: iif wg0 lookup 100
docker exec openvpn-usa ip route show table 100 # default dev tun0 + unreachable default
docker exec openvpn-usa cat /tmp/run.ovpn       # профиль, с которым запущен OpenVPN
```

## Безопасность

- `openvpn/` и заполненный `sing-box/config.json` содержат секреты: `chmod 600`, в git не коммитятся (`openvpn/*` в `.gitignore`, в репозитории `config.json` только с плейсхолдерами).
- SOCKS-порт sing-box слушает только `127.0.0.1`: из `wg0` и LAN он недоступен.
- DNS клиентов не перехватывается: запросы идут на резолвер, настроенный на устройстве.
- Web UI wg-easy (`51821/tcp`) доступен только из LAN; ключи WireGuard в `wg-data/` — ограничить доступ к директории.
