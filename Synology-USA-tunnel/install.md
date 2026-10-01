# Установка USA-туннеля на Synology — кратко

Цепочка: ПК из `vpn-clients` → Mikrotik → WireGuard → Synology → VLESS → OpenVPN (США) → интернет.
Подробности и диагностика — в [README.md](README.md).

## 1. Подготовить файлы (на своём компьютере)

**VLESS** — в `sing-box/config.json` заменить 5 плейсхолдеров:
`<YOUR_VPS_IP>`, `<YOUR_UUID>`, `<YOUR_SNI>`, `<YOUR_REALITY_PUBLIC_KEY>`, `<YOUR_SHORT_ID>`.

**OpenVPN** — в папку `openvpn/` положить:

- ровно **один** профиль `*.ovpn` (имя любое);
- `cred.txt` — если в профиле есть `auth-user-pass`. Две строки: логин, пароль;
- файлы, на которые профиль ссылается по относительному пути (`ca.crt`, `client.key` и т.п.), если они есть.

Требования к профилю (иначе контейнер не стартует, причина — в `docker logs openvpn-usa`):

- `proto tcp` — UDP не работает;
- в `remote` — **IPv4-адрес**, не имя хоста. Узнать IP: `dig +short vpn.example.com`;
- без блоков `<connection>` и директивы `config`.

## 2. Скопировать на Synology

Скопировать папку `Synology-USA-tunnel/` (без `tests/`) в `/volume1/docker/Synology-USA-tunnel`.
Затем по SSH (под администратором, `sudo -i`):

```bash
cd /volume1/docker/Synology-USA-tunnel
chmod +x scripts/*.sh openvpn-client/*.sh
chmod 600 sing-box/config.json openvpn/*
```

## 3. Остановить VLESS-стек

Оба стека занимают одни порты (51820/udp, 51821/tcp) — работает только один. Имена контейнеров разные, оба стека можно держать развёрнутыми.

```bash
cd /volume1/docker/synology-split-tunnel
docker compose stop
```

Один раз пересоздать VLESS-стек, чтобы он перестал стартовать сам: скопировать на Synology обновлённый `synology-split-tunnel/docker-compose.yml` (там `restart: "no"`) и выполнить

```bash
cd /volume1/docker/synology-split-tunnel
docker compose up --no-start    # пересоздаёт контейнеры, не запуская их
```

После запуска (шаг 4) проверить: `no` у VLESS-контейнеров, `always` у USA:

```bash
docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' wg-easy sing-box wg-easy-usa sing-box-usa openvpn-usa
```

Чтобы Mikrotik подключался к обоим стекам без перенастройки, скопировать `wg-data/` из `synology-split-tunnel` в `Synology-USA-tunnel` (одинаковые ключи WireGuard).

Если при запуске ошибка `The container name "/wg-easy" is already in use` — у вас старая версия этого стека; обновить файлы и повторить.

## 4. Запустить

```bash
cd /volume1/docker/Synology-USA-tunnel
docker compose up -d --build
```

## 5. Проверить

```bash
docker logs openvpn-usa
```

В логе должны быть строки (без `ERROR`):

```
[routing] kill switch: wg0 traffic blocked unless tun0 is up
[routing] using iptables-legacy
[routing] iptables rules applied
[routing] setup complete
... Initialization Sequence Completed
[route-up] table 100: default dev tun0
```

С ПК из `vpn-clients`:

```bash
curl -s https://ifconfig.me   # должен быть IP OpenVPN-сервера в США
```

Kill switch: `docker stop openvpn-usa` → на ПК нет интернета; `docker start openvpn-usa` → через 10–60 с интернет и американский IP возвращаются.

## Переключение USA ↔ VLESS

По умолчанию работает USA; после перезагрузки DSM всегда поднимается USA, VLESS сам не стартует.

- **USA → VLESS:** Container Manager → проект `Synology-USA-tunnel` → «Остановить», затем `synology-split-tunnel` → «Запустить».
- **VLESS → USA:** наоборот.
- `port is already allocated` при запуске — второй стек ещё работает, сначала остановить его.

## Mikrotik

Если WG-туннель уже работал со старым стеком, ничего менять не нужно. Обязателен MSS clamping (команды — в README, раздел «Настройка Mikrotik»).

## Частые ситуации

| Ситуация | Что сделать |
|----------|-------------|
| В логе `[openvpn] ERROR: ...` | Исправить профиль по тексту ошибки, затем `docker restart openvpn-usa` |
| В логе `AUTH_FAILED` | Неверный логин/пароль в `openvpn/cred.txt` |
| Нет строки `[route-up]`, повторяются подключения к `127.0.0.1:1080` | Проблема с VLESS: `docker logs sing-box-usa`, проверить `sing-box/config.json` |
| `[routing] ERROR: iptables not found` / `cannot add iptables rules` | Ядро DSM не поддерживает нужный netfilter — см. README, «Диагностика» |
| Перезапустили только wg-easy | `docker compose up -d --force-recreate sing-box openvpn` |
| Поменяли профиль или `cred.txt` | `docker restart openvpn-usa` |
| Поменяли `sing-box/config.json` | `docker restart sing-box-usa` |
| Переключиться на VLESS и обратно | См. «Переключение USA ↔ VLESS» выше |
