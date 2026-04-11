# OpenWrt + sing-box + VLESS: краткая инструкция

## 1) Где лежат файлы

Основной конфиг sing-box:

```sh
/etc/sing-box/config.json
```

Настройки запуска сервиса:

```sh
/etc/config/sing-box
```

---

## 2) Как редактировать `config.json`

Сначала сделай резервную копию:

```sh
cp /etc/sing-box/config.json /etc/sing-box/config.json.bak
```

Открыть файл:

```sh
vi /etc/sing-box/config.json
```

### Как пользоваться `vi`

- нажать `i` — режим редактирования
- внести изменения
- нажать `Esc`
- ввести `:wq` и Enter — сохранить и выйти
- `:q!` — выйти без сохранения

---

## 3) Как проверить JSON

Проверка конфига:

```sh
sing-box check -c /etc/sing-box/config.json
```

Автоформатирование файла:

```sh
sing-box format -w -c /etc/sing-box/config.json
```

Если `check` не показывает `FATAL`, значит JSON валидный.

---

## 4) Как перезапустить sing-box

```sh
/etc/init.d/sing-box restart
```

Включить автозапуск:

```sh
/etc/init.d/sing-box enable
```

Остановить:

```sh
/etc/init.d/sing-box stop
```

Запустить:

```sh
/etc/init.d/sing-box start
```

---

## 5) Как смотреть логи

Показать последние строки:

```sh
logread -e sing-box
```

Смотреть лог в реальном времени:

```sh
logread -f -e sing-box
```

### Что важно в логах

Если всё хорошо, будут строки примерно такие:

```text
inbound/tun[tun-in]: started at tun0
sing-box started
outbound/vless[vless-out]
```

Если видишь:

```text
outbound/direct[direct]
```

значит трафик пошёл напрямую, а не через VLESS.

---

## 6) Как понять, что VPN работает

Если в логе есть:

```text
outbound/vless[vless-out]
```

значит трафик реально идёт через VLESS.

Если есть:

```text
inbound redirect connection from 192.168.1.106
```

это значит, что именно устройство `192.168.1.106` отправило трафик в туннель.

---

## 7) Как выбрать устройства, которые идут через VPN

В `config.json` ищи блок:

```json
{
  "source_ip_cidr": [
    "192.168.1.106/32"
  ],
  "action": "route",
  "outbound": "vless-out"
}
```

### Смысл

- `192.168.1.106/32` — устройство, которое должно идти через VPN
- `vless-out` — отправка через VLESS

### Несколько устройств

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

Лучше закрепить этим устройствам постоянные IP через DHCP.

---

## 8) Как исключить локальную сеть из VPN

Чтобы роутер, NAS, принтеры и локальные сервисы не ломались, должно быть правило:

```json
{
  "ip_is_private": true,
  "action": "route",
  "outbound": "direct"
}
```

---

## 9) Как исключить сам сервер VLESS из перехвата

Должно быть правило вида:

```json
{
  "ip_cidr": [
    "153.80.184.219/32"
  ],
  "action": "route",
  "outbound": "direct"
}
```

Это нужно, чтобы соединение к самому VLESS-серверу шло напрямую.

---

## 10) Если ошибка `permission denied` на TUN

Нужно:

1. установить TUN-модуль
2. запускать sing-box от `root`

Команды:

```sh
opkg update
opkg install kmod-tun
uci set sing-box.main.user='root'
uci commit sing-box
/etc/init.d/sing-box restart
```

Проверка:

```sh
ls -l /dev/net/tun
lsmod | grep tun
uci show sing-box
```

---

## 11) Полезные команды

Показать текущий конфиг сервиса:

```sh
cat /etc/config/sing-box
```

Показать основной JSON:

```sh
cat /etc/sing-box/config.json
```

Вернуть резервную копию:

```sh
cp /etc/sing-box/config.json.bak /etc/sing-box/config.json
/etc/init.d/sing-box restart
```

---

## 12) Типовой порядок изменений

1. Скопировать резервную копию
2. Открыть `config.json`
3. Изменить IP устройств в `source_ip_cidr`
4. Сохранить файл
5. Проверить:

```sh
sing-box check -c /etc/sing-box/config.json
```

6. Перезапустить:

```sh
/etc/init.d/sing-box restart
```

7. Посмотреть лог:

```sh
logread -f -e sing-box
```

8. Проверить, что появляются строки:

```text
outbound/vless[vless-out]
```

---

## 13) Если что-то сломалось

Самый быстрый откат:

```sh
cp /etc/sing-box/config.json.bak /etc/sing-box/config.json
/etc/init.d/sing-box restart
logread -e sing-box
```

---

## 14) Главное

- `check` — проверяет JSON
- `restart` — применяет конфиг
- `logread -f -e sing-box` — показывает, что реально происходит
- `outbound/vless[vless-out]` — трафик идёт через VPN
- `outbound/direct[direct]` — трафик идёт напрямую
