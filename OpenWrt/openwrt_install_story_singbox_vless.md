# Как я установил sing-box + VLESS на OpenWrt

Ниже — пошаговая инструкция в формате «что я сделал», чтобы на роутере с **OpenWrt 24.10.0** заработал **VLESS через sing-box**, а выбранные устройства в локальной сети шли через VPN.

---

## 1. Исходные данные

У меня:

- прошивка **OpenWrt 24.10.0**
- роутер с локальной сетью `192.168.1.0/24`
- sing-box используется как клиент VLESS
- нужно, чтобы **только некоторые устройства** шли через VPN
- для маршрутизации используется **TUN-режим**

На OpenWrt 24.10.0 используется **`opkg`**, а не `apk`.

---

## 2. Установка пакетов

Сначала я обновил список пакетов и поставил `sing-box`:

```sh
opkg update
opkg install sing-box ca-bundle
```

Потом поставил поддержку TUN, потому что без неё `tun-in` не запускается:

```sh
opkg update
opkg install kmod-tun
```

---

## 3. Включение сервиса

Я включил сервис sing-box:

```sh
uci set sing-box.main.enabled='1'
uci commit sing-box
/etc/init.d/sing-box enable
```

---

## 4. Решение проблемы с правами на TUN

Сначала sing-box падал с ошибкой:

```text
configure tun interface: permission denied
```

Это произошло потому, что сервис запускался не с нужными правами.

Я исправил это так:

```sh
uci set sing-box.main.user='root'
uci commit sing-box
/etc/init.d/sing-box restart
```

После этого `tun0` смог подняться.

Проверить можно так:

```sh
ls -l /dev/net/tun
lsmod | grep tun
uci show sing-box
```

---

## 5. Где лежит основной конфиг

Основной JSON-файл sing-box:

```sh
/etc/sing-box/config.json
```

Перед редактированием я делал резервную копию:

```sh
cp /etc/sing-box/config.json /etc/sing-box/config.json.bak
```

Редактирование файла:

```sh
vi /etc/sing-box/config.json
```

### Как пользоваться `vi`

- нажать `i` — войти в режим редактирования
- внести изменения
- нажать `Esc`
- ввести `:wq` и Enter — сохранить и выйти
- `:q!` — выйти без сохранения

---

## 6. Проблема со старым синтаксисом sing-box

Сначала sing-box ругался на старый формат конфига:

```text
legacy DNS servers is deprecated
legacy special outbounds is deprecated
```

Это значит, что конфиг был написан под старый синтаксис.

Я исправил это так:

- убрал старые специальные `outbounds` типа `dns` и `block`
- перевёл DNS-сервера на новый формат
- заменил старые правила маршрутизации на новый синтаксис `action`

После этого конфиг стал валидным.

---

## 7. Мой VLESS-подключение

Я использовал VLESS URI такого типа:

```text
vless://UUID@SERVER_IP:443?security=reality&type=tcp&sni=HOSTNAME&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID
```

Из этого в конфиге sing-box используются такие параметры:

- `server` — IP или домен сервера
- `server_port` — порт
- `uuid` — UUID клиента
- `network` — `tcp`
- `tls.server_name` — SNI
- `tls.utls.fingerprint` — fingerprint
- `tls.reality.public_key` — public key
- `tls.reality.short_id` — short id

---

## 8. Полный рабочий `config.json`

Ниже пример рабочего конфига, который я использовал как основу:

```json
{
  "log": {
    "level": "info"
  },
  "dns": {
    "servers": [
      {
        "type": "udp",
        "tag": "dns-direct",
        "server": "1.1.1.1",
        "server_port": 53
      },
      {
        "type": "tls",
        "tag": "dns-remote",
        "server": "1.1.1.1",
        "server_port": 853,
        "detour": "vless-out"
      }
    ],
    "rules": [
      {
        "source_ip_cidr": [
          "192.168.1.106/32"
        ],
        "action": "route",
        "server": "dns-remote"
      },
      {
        "action": "route",
        "server": "dns-direct"
      }
    ],
    "final": "dns-direct"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": [
        "172.19.0.1/30"
      ],
      "auto_route": true,
      "auto_redirect": true,
      "strict_route": true
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-out",
      "server": "153.80.184.219",
      "server_port": 443,
      "uuid": "PASTE_FULL_UUID_HERE",
      "network": "tcp",
      "tls": {
        "enabled": true,
        "server_name": "knowlege.trendstack.dev",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "3BqLLxpmq1qYkBA5NMLjaSv4vowEDWhavF2xggVBICo",
          "short_id": "aa15fe94"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": "dns-direct",
    "rules": [
      {
        "action": "sniff"
      },
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "ip_is_private": true,
        "action": "route",
        "outbound": "direct"
      },
      {
        "ip_cidr": [
          "153.80.184.219/32"
        ],
        "action": "route",
        "outbound": "direct"
      },
      {
        "source_ip_cidr": [
          "192.168.1.106/32"
        ],
        "action": "route",
        "outbound": "vless-out"
      },
      {
        "action": "route",
        "outbound": "direct"
      }
    ]
  }
}
```

---

## 9. Как я выбираю устройства, которые идут через VPN

Для этого я использую правило:

```json
{
  "source_ip_cidr": [
    "192.168.1.106/32"
  ],
  "action": "route",
  "outbound": "vless-out"
}
```

Это значит:

- устройство с IP `192.168.1.106` идёт через VLESS
- остальные устройства идут напрямую

Если нужно несколько устройств, я просто добавляю их IP:

```json
{
  "source_ip_cidr": [
    "192.168.1.106/32",
    "192.168.1.107/32",
    "192.168.1.120/32"
  ],
  "action": "route",
  "outbound": "vless-out"
}
```

Лучше заранее закрепить устройствам постоянные IP через DHCP.

---

## 10. Как я проверяю конфиг

После любого изменения я проверяю JSON:

```sh
sing-box check -c /etc/sing-box/config.json
```

И форматирую его:

```sh
sing-box format -w -c /etc/sing-box/config.json
```

Если нет `FATAL`, значит конфиг синтаксически нормальный.

---

## 11. Как я применяю настройки

После проверки я перезапускаю сервис:

```sh
/etc/init.d/sing-box restart
```

Если надо просто запустить:

```sh
/etc/init.d/sing-box start
```

Остановить:

```sh
/etc/init.d/sing-box stop
```

---

## 12. Как я смотрю логи

Показать последние сообщения:

```sh
logread -e sing-box
```

Смотреть в реальном времени:

```sh
logread -f -e sing-box
```

---

## 13. Как понять, что всё работает

Нормальные строки в логе выглядят так:

```text
inbound/tun[tun-in]: started at tun0
sing-box started
```

Если устройство действительно идёт через VPN, в логе будут строки вида:

```text
inbound redirect connection from 192.168.1.106:xxxxx
outbound/vless[vless-out]: outbound connection to ...
```

Это означает:

- трафик пришёл от устройства `192.168.1.106`
- он попал в туннель
- дальше он ушёл через `vless-out`

Если в логе вместо этого есть:

```text
outbound/direct[direct]
```

значит трафик пошёл напрямую, а не через VLESS.

---

## 14. Как я понял, что у меня всё заработало

Сначала у меня были ошибки:

- старый синтаксис sing-box
- `configure tun interface: permission denied`

После исправления конфига и запуска сервиса от `root` в логе появились строки:

```text
inbound/tun[tun-in]: started at tun0
sing-box started
```

А потом для устройства `192.168.1.106` появились строки:

```text
outbound/vless[vless-out]
```

Это и означало, что выбранное устройство уже идёт через VPN.

---

## 15. Быстрый порядок действий при изменениях

Каждый раз я делаю так:

1. делаю бэкап
2. редактирую `config.json`
3. проверяю конфиг:

```sh
sing-box check -c /etc/sing-box/config.json
```

4. перезапускаю сервис:

```sh
/etc/init.d/sing-box restart
```

5. смотрю лог:

```sh
logread -f -e sing-box
```

6. проверяю, что в логе есть:

```text
outbound/vless[vless-out]
```

---

## 16. Быстрый откат, если что-то сломалось

Если после правки всё перестало работать, я возвращаю резервную копию:

```sh
cp /etc/sing-box/config.json.bak /etc/sing-box/config.json
/etc/init.d/sing-box restart
logread -e sing-box
```

---

## 17. Самое главное

Основные команды, которые нужны постоянно:

```sh
vi /etc/sing-box/config.json
sing-box check -c /etc/sing-box/config.json
sing-box format -w -c /etc/sing-box/config.json
/etc/init.d/sing-box restart
logread -f -e sing-box
```

Главные признаки:

- `sing-box started` — сервис запустился
- `started at tun0` — TUN работает
- `outbound/vless[vless-out]` — трафик идёт через VPN
- `outbound/direct[direct]` — трафик идёт напрямую

