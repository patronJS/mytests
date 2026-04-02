# Design: steal_oneself на обоих VPS + удаление WireGuard

**Дата:** 2026-04-02
**Статус:** Reviewed (Codex CLI review applied)
**Цель:** (1) Устранить ASN mismatch на обоих VPS, переведя VPS1 на steal_oneself с собственным доменом. (2) Полностью убрать WireGuard из архитектуры.

## Контекст и мотивация

### steal_oneself

**Проблема:** Сейчас VPS1 использует `dest: "dl.google.com:443"` в REALITY. Трафик VPS2 (Россия) → VPS1 (Германия) проходит через ТСПУ, который видит SNI=`dl.google.com` на IP из ASN Hetzner — явная аномалия.

**Решение:** Собственный домен на VPS1 + steal_oneself. SNI/IP/сертификат совпадают — никакой аномалии.

**Исследование (2024-2026):**
- ТСПУ проверяет соответствие SNI и ASN/CIDR сервера (не DNS-резолвацию, а принадлежность IP)
- steal_oneself убирает ASN mismatch полностью
- Заглушка (Confluence) на корне домена добавляет правдоподобность при active probing

### Удаление WireGuard

WireGuard (wg-easy + TPROXY) не работает и удаляется полностью. Клиенты используют только VLESS+REALITY напрямую.

## Верификация: сертификаты и нестандартный порт

Проверено перед финализацией спеки:

1. **ACME HTTP-01 на порту 80 при сервисе на 49321** — работает. Let's Encrypt HTTP-01 использует **только порт 80**. Порт 443 не участвует в валидации. Angie получает сертификат через порт 80.

2. **TLS-сертификат на нестандартном порту** — сертификаты не содержат номер порта (только доменное имя в SAN/CN). Один и тот же LE-сертификат валиден на любом порту. REALITY-клиент проверяет HMAC-подпись, а не CA chain — порт не влияет.

3. **Active probing на VPS1:49321** — пробер видит Confluence заглушку. REALITY пересылает все не-REALITY подключения на `dest` (Angie). Камуфляж работает на нестандартном порту.

## Архитектура: что меняется

### VPS1 (exit, Германия) — ИЗМЕНЕНИЯ

**Было:**
- Только Marzban, никакого веб-сервера
- REALITY dest: `dl.google.com:443` на порту 49321
- Порты: 49321 (XHTTP+REALITY) + SSH
- Панель: SSH-туннель на 8000

**Стало:**
- Marzban + **Angie** (TLS-терминация, ACME, заглушка)
- REALITY dest: `127.0.0.1:4123` (steal_oneself) на порту 49321
- serverNames: `["$VPS1_DOMAIN"]`
- Порты: 49321 (XHTTP+REALITY) + **80** (ACME HTTP-01) + SSH
- Панель: SSH-туннель на 8000 (без изменений)
- Заглушка: Confluence на `https://$VPS1_DOMAIN:49321/` (через REALITY fallback → Angie)

### VPS2 (entry, Россия) — ИЗМЕНЕНИЯ

- steal_oneself на собственном домене — **без изменений** (уже работает)
- chain outbound: `serverName` меняется с `"dl.google.com"` на `"$VPS1_DOMAIN"`
- **WireGuard полностью удалён** (wg-easy, TPROXY, dokodemo-door)
- Заглушка Confluence — **без изменений**
- Angie: убран location для WG UI

## Детали реализации VPS1

### 1. Новый шаблон: `panel-angie`

Angie-конфиг для VPS1, аналогичный `node-angie` но проще (нет WG UI, нет Marzban proxy — панель через SSH-туннель):

```nginx
user angie;
worker_processes auto;
error_log /var/log/angie/error.log notice;

events {
    worker_connections 1024;
}

http {
    server_tokens off;
    access_log off;

    resolver 1.1.1.1;
    acme_client vless https://acme-v02.api.letsencrypt.org/directory;

    # Default: reject unknown SNI
    # ВАЖНО: proxy_protocol должен быть на ОБОИХ серверах, т.к. xver:1
    # отправляет PROXY header на все подключения к этому сокету
    server {
        listen 127.0.0.1:4123 ssl proxy_protocol default_server;
        ssl_reject_handshake on;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_session_timeout 1h;
        ssl_session_cache shared:SSL:10m;
    }

    # Main: steal_oneself target
    server {
        listen 127.0.0.1:4123 ssl proxy_protocol;
        http2 on;

        set_real_ip_from 127.0.0.1;
        real_ip_header proxy_protocol;

        server_name $VPS1_DOMAIN;

        acme vless;
        ssl_certificate $acme_cert_vless;
        ssl_certificate_key $acme_cert_key_vless;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers TLS13_AES_128_GCM_SHA256:TLS13_AES_256_GCM_SHA384:TLS13_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;
        ssl_prefer_server_ciphers on;

        ssl_stapling on;
        ssl_stapling_verify on;
        resolver 1.1.1.1 valid=60s;
        resolver_timeout 2s;

        location / {
            root /tmp;
            index index.html;
        }
    }

    # Порт 80: ACME HTTP-01 challenge + заглушка для камуфляжа
    # НЕ редиректим на https://$host/ — на VPS1 порт 443 закрыт (сервис на 49321)
    # Вместо этого отдаём заглушку напрямую, а ACME перехватывает /.well-known/acme-challenge/
    server {
        listen 80;
        listen [::]:80;

        location / {
            root /tmp;
            index index.html;
        }
    }
}
```

**Ключевые отличия от `node-angie` (VPS2):**
- Нет location для Marzban — панель доступна только через SSH-туннель
- Нет location для WG UI — WireGuard удалён
- Только корень `/` → Confluence заглушка
- Порт 80 нужен **только для ACME HTTP-01 challenge**, не для пользователей

### 2. Изменения в `panel-xray`

```diff
  "realitySettings": {
-   "dest": "dl.google.com:443",
+   "dest": "127.0.0.1:4123",
-   "xver": 0,
+   "xver": 1,
-   "serverNames": ["dl.google.com"],
+   "serverNames": ["$VPS1_DOMAIN"],
    "privateKey": "$XRAY_PIK",
    "publicKey": "$XRAY_PBK",
    "shortIds": [$SHORT_IDS]
  }
```

- `dest` → локальный Angie (steal_oneself)
- `xver: 1` → proxy protocol для передачи client IP в Angie
- `serverNames` → собственный домен VPS1

### 3. Изменения в `compose-panel`

Добавить Angie контейнер:

```yaml
services:
  angie:
    image: docker.angie.software/angie:minimal
    container_name: angie
    restart: always
    network_mode: host
    volumes:
      - angie-data:/var/lib/angie
      - ./angie.conf:/etc/angie/angie.conf:ro
      - ./index.html:/tmp/index.html:ro

  marzban:
    # ... без изменений ...

volumes:
  angie-data:
    driver: local
    external: false
    name: angie-data
  marzban_lib:
    driver: local
```

### 4. Изменения в `setup-panel.sh`

| Что | Детали |
|-----|--------|
| Запрос домена | Добавить prompt `Enter VPS1 domain:` + DNS-валидация (как в `setup-entry.sh`) |
| Переменная | `export VPS1_DOMAIN=...` + `export VLESS_DOMAIN="$VPS1_DOMAIN"` (marzban template использует `$VLESS_DOMAIN` для subscription URL) |
| Зависимости | Добавить `idn dnsutils` в `apt-get install` |
| Шаблоны | Скачать `panel-angie` → `./angie.conf`, `confluence` → `./index.html` |
| envsubst | `panel-angie`: подставить `$VPS1_DOMAIN` |
| iptables | Добавить порт 80 (`iptables_add INPUT -p tcp -m tcp --dport 80 -j ACCEPT`) |
| Output | Добавить `VPS1_DOMAIN` в вывод для `setup-entry.sh` |

## Детали реализации VPS2: удаление WireGuard

### 5. Изменения в `setup-entry.sh`

**Добавить:**

| Что | Детали |
|-----|--------|
| Новый prompt | `Enter VPS1 domain:` → `export VPS1_DOMAIN` |
| envsubst node-xray | Добавить `$VPS1_DOMAIN` в список переменных |
| Валидация | Добавить проверку формата домена (не IP) |

**Удалить:**

| Что | Детали |
|-----|--------|
| WG_ADMIN_PASS | Генерация пароля WG |
| bcrypt/WG_ADMIN_HASH | Хеширование пароля + pip3 install bcrypt |
| WG_UI_PATH | Генерация пути WG UI |
| WG UI output | Строки про WireGuard UI в финальном выводе |
| iptables 41820 | Правило для WG UDP порта |
| iptables-legacy switch | `update-alternatives --set iptables /usr/sbin/iptables-legacy` (строка 16) — был нужен для TPROXY. Без WG можно убрать |
| ip_forward | Оценить: `net.ipv4.ip_forward=1` (строка 151) — был нужен для WG routing. Без WG может быть не нужен (XRay работает в userspace) |
| WARP prompt | `configure_warp_input` и `warp_install` (опционально — обсудить отдельно) |

### 6. Изменения в `node-xray` (шаблон VPS2)

```diff
  # chain outbound realitySettings:
  "realitySettings": {
-   "serverName": "dl.google.com",
+   "serverName": "$VPS1_DOMAIN",
    "fingerprint": "chrome",
    "publicKey": "$VPS1_PBK",
    "shortId": "$VPS1_SHORT_ID"
  }
```

**Удалить `sockopt.mark: 255`** из chain outbound — он был нужен только для обхода WG TPROXY (чтобы трафик XRay не зацикливался). Без WG mark не нужен, и это позволяет убрать `CAP_NET_ADMIN` из marzban контейнера:
```diff
  "streamSettings": {
    ...
-   "sockopt": {
-     "mark": 255
-   }
  }
```

**Удалить inbound `tproxy-in`** (dokodemo-door для WG TPROXY):
```diff
- {
-   "tag": "tproxy-in",
-   "port": 12345,
-   "protocol": "dokodemo-door",
-   "settings": {
-     "network": "tcp,udp",
-     "followRedirect": true
-   },
-   "streamSettings": {
-     "sockopt": {
-       "tproxy": "tproxy"
-     }
-   },
-   "sniffing": {
-     "enabled": true,
-     "destOverride": ["http", "tls"]
-   }
- }
```

**Обновить routing rule** — убрать `"tproxy-in"` из `inboundTag`:
```diff
- {"inboundTag": ["reality-tcp", "xhttp-in", "tproxy-in"], "outboundTag": "chain-vps1"}
+ {"inboundTag": ["reality-tcp", "xhttp-in"], "outboundTag": "chain-vps1"}
```

### 7. Изменения в `node-angie` (шаблон VPS2)

**Исправить proxy_protocol mismatch** (существующий баг, найден при ревью):
```diff
  server {
-     listen                  127.0.0.1:4123 ssl default_server;
+     listen                  127.0.0.1:4123 ssl proxy_protocol default_server;
      ssl_reject_handshake    on;
```
Без этого фикса: `xver: 1` отправляет PROXY header на все подключения к сокету, а default_server без `proxy_protocol` не ожидает его — возможны ошибки при reject unknown SNI.

**Удалить `map $http_upgrade $connection_upgrade`** — использовался только WG UI proxy, Marzban не требует WebSocket upgrade.

**Удалить `map $proxy_protocol_addr` и `map $http_forwarded`** — оценить, используются ли они ещё. Если нет — удалить для чистоты.

**Удалить location WG UI:**
```diff
- location ^~ /$WG_UI_PATH/ {
-     proxy_pass http://127.0.0.1:51821/;
-     proxy_set_header Host $host;
-     proxy_set_header X-Real-IP $remote_addr;
-     proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
-     proxy_set_header Upgrade $http_upgrade;
-     proxy_set_header Connection $connection_upgrade;
- }
```

Убрать `map $http_upgrade $connection_upgrade` — он больше не используется (Marzban proxy не требует WebSocket upgrade).

### 8. Изменения в `compose-cascade-node` (шаблон VPS2)

**Удалить wg-easy сервис целиком:**
```diff
- wg-easy:
-   image: ghcr.io/wg-easy/wg-easy:14
-   container_name: wg-easy
-   ... (весь блок)
```

**Удалить volume `wg-data`.**

**Убрать WG-related переменные** из envsubst (`$WG_ADMIN_HASH`, `$WG_UI_PATH`).

**Убрать `cap_add: NET_ADMIN`** из marzban (был нужен для TPROXY — без WG не нужен).

## Поток данных после изменений

```
Client → VPS2:443 (VLESS+REALITY, SNI=$VLESS_DOMAIN)
         ↓ XRay steal → 127.0.0.1:4123 (Angie, cert=$VLESS_DOMAIN) ✓ SNI/IP match
         ↓
         XHTTP chain outbound → VPS1:49321 (REALITY, SNI=$VPS1_DOMAIN)
         ↓ XRay steal → 127.0.0.1:4123 (Angie, cert=$VPS1_DOMAIN) ✓ SNI/IP match
         ↓
         freedom → Internet (German IP)
```

**Active probing:**
- VPS2:443 → Confluence login page
- VPS1:49321 → Confluence login page (через REALITY fallback → Angie → index.html)

**WireGuard flow — УДАЛЁН:**
```
- Client → VPS2:51820 (WireGuard) → TPROXY → XRay chain → VPS1 — УДАЛЕНО
```

## Заглушка Confluence

Используется существующий шаблон `confluence` без изменений на обоих VPS. Единственная подстановка — через `envsubst` (если есть переменные в шаблоне).

## Порты

| VPS | Порт | Назначение | Публичный? |
|-----|------|-----------|------------|
| VPS1 | 49321 | XHTTP+REALITY (steal_oneself) | Да |
| VPS1 | 80 | ACME HTTP-01 challenge | Да (только для Let's Encrypt) |
| VPS1 | 8000 | Marzban panel | Нет (SSH tunnel) |
| VPS1 | SSH | SSH | Да |
| VPS2 | 443 | VLESS+REALITY (steal_oneself) | Да |
| VPS2 | 80 | ACME HTTP-01 / redirect | Да |
| VPS2 | 8000 | Marzban panel | Нет (через Angie) |

## Затрагиваемые файлы

| Файл | Действие |
|------|---------|
| `setup-panel.sh` | Изменить: домен, DNS-валидация, шаблоны Angie/Confluence, iptables порт 80 |
| `setup-entry.sh` | Изменить: prompt VPS1_DOMAIN, убрать WG-related код, envsubst |
| `templates_for_script/panel-xray` | Изменить: dest, xver, serverNames |
| `templates_for_script/panel-angie` | **Создать**: Angie-конфиг для VPS1 |
| `templates_for_script/compose-panel` | Изменить: добавить Angie контейнер + volume |
| `templates_for_script/node-xray` | Изменить: serverName в chain outbound, удалить tproxy-in inbound |
| `templates_for_script/node-angie` | Изменить: удалить WG UI location + неиспользуемый map |
| `templates_for_script/compose-cascade-node` | Изменить: удалить wg-easy сервис + volume |
| `templates_for_script/confluence` | Без изменений |
| `CLAUDE.md` | Обновить: архитектура, порты, удалить WG references |
| `README.md` | Обновить: инструкции установки, убрать WG |

## Требования к доменам

- **2 домена** (можно субдомены одного): один для VPS1, один для VPS2
- A-записи должны указывать на соответствующие IP
- Регистратор: зарубежный (рекомендация)
- Зона `.com`, `.org`, `.net` или другая международная (не `.ru`)

## Риски и mitigation

| Риск | Mitigation |
|------|-----------|
| Домен VPS1 заблокируют по SNI | Сменить домен, перезапустить скрипт — downtime минуты |
| ACME HTTP-01 не пройдёт (порт 80 закрыт) | Скрипт открывает порт 80 в iptables до запуска Angie |
| Порт 80 на VPS1 — лишняя поверхность | Только 301 redirect + ACME, никаких сервисов |
| VPS2 chain outbound с SNI домена VPS1 — ТСПУ видит | SNI/IP совпадают, нет аномалии |
| Без WG нет fallback-канала | VLESS+REALITY — основной и единственный канал. При необходимости WG можно вернуть позже |

## Что НЕ входит в scope

- Миграция существующих установок (только новые деплои)
- CDN/Cloudflare интеграция
- DNS-01 ACME challenge (используем HTTP-01)
- Изменение транспорта (XHTTP остаётся)
- Изменение порта 49321
- WARP интеграция (обсудить отдельно, если нужна)
