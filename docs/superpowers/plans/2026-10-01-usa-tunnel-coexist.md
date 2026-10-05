# USA Tunnel / Split Tunnel Coexistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Both stacks stay deployed on the Synology; the USA stack starts on every boot, the VLESS stack (`synology-split-tunnel`) only by hand, and switching is stop one / start the other in Container Manager.

**Architecture:** The USA stack gets unique container names (`-usa` suffix) and `restart: always`; `synology-split-tunnel` gets `restart: "no"`. Ports stay equal (51820/udp, 51821/tcp), so the second stack cannot start while the first runs. Docs get the new names and a switching section.

**Tech Stack:** Docker Compose, jq, grep (checks only).

**Spec:** `docs/superpowers/specs/2026-09-30-synology-usa-tunnel-openvpn-design.md` (section "Coexistence with synology-split-tunnel", decision 4)

## Global Constraints

- Container names of the USA stack: `wg-easy-usa`, `sing-box-usa`, `openvpn-usa`. Service names stay `wg-easy`, `sing-box`, `openvpn` (`network_mode: "service:wg-easy"`, `depends_on` and `docker compose <cmd> <service>` commands are unchanged).
- Restart policy: USA stack `always` for all three services; `synology-split-tunnel` `"no"` for both services.
- Ports stay 51820/udp and 51821/tcp in both stacks.
- In `synology-split-tunnel/` change only the two `restart:` lines. The file has uncommitted user edits: never stage, revert or stash them; commit only the `restart:` change.
- `install.md` is untracked; it is committed in Task 1 together with its edits.
- Docs stay in Russian; commit messages in English, short conventional subject, no attribution trailers.
- Branch: `feat/usa-tunnel-coexist`.

## Review Focus

1. **A `docker logs/exec/stop/start/restart` command in the docs still uses an old name** (`openvpn`, `sing-box`, `wg-easy`): it fails on the Synology with "No such container". Test: Task 1 grep check.
2. **`docker compose` commands must keep service names** (`--force-recreate sing-box openvpn`, `build --pull openvpn`): renaming them to `-usa` breaks them. Test: Task 1 grep check that these lines are unchanged.
3. **Both stacks created at once** (the user's real setup): no name conflict. Test: Task 2 coexistence check.
4. **Starting the second stack while the first runs** fails on the port, not silently. Test: Task 2 coexistence check.

---

### Task 1: USA stack — names, restart policy, docs

**Files:**
- Modify: `Synology-USA-tunnel/docker-compose.yml` (lines with `container_name:` and `restart:`)
- Modify: `Synology-USA-tunnel/README.md`
- Modify + add to git: `Synology-USA-tunnel/install.md`

**Interfaces:**
- Produces: container names `wg-easy-usa`, `sing-box-usa`, `openvpn-usa`; compose project directory unchanged.

- [ ] **Step 1: Write the failing checks** (run from the repo root)

```bash
cd Synology-USA-tunnel
docker compose config --format json | jq -e '([.services[] | .container_name] | sort) == ["openvpn-usa","sing-box-usa","wg-easy-usa"] and ([.services[] | .restart] | unique) == ["always"]'
grep -nE 'docker (logs|exec|stop|start|restart)( -f)? (openvpn|sing-box|wg-easy)([ `]|$)' README.md install.md
grep -c 'force-recreate sing-box openvpn\|build --pull openvpn' README.md install.md
grep -l 'Переключение USA ↔ VLESS' README.md install.md
cd ..
```

- [ ] **Step 2: Run them to verify they fail**

Expected: `jq` prints `false`; the first grep lists the old-name commands (README lines with `docker logs openvpn`, `docker exec wg-easy wg show`, …; install.md lines with `docker logs openvpn`, `docker restart sing-box`, …); the count grep prints `README.md:2` and `install.md:1`; the last grep prints nothing.

- [ ] **Step 3: Compose file**

In `Synology-USA-tunnel/docker-compose.yml`:
- `container_name: wg-easy` → `container_name: wg-easy-usa`
- `container_name: sing-box` → `container_name: sing-box-usa`
- `container_name: openvpn` → `container_name: openvpn-usa`
- all three `restart: unless-stopped` → `restart: always`
- directly above the `wg-easy` service's `restart: always` line add:

```yaml
    # Always: the USA stack comes back on every DSM boot, even after a manual
    # stop. synology-split-tunnel uses restart "no" and is started by hand.
```

- [ ] **Step 4: README.md**

1. Replace every `docker logs|exec|stop|start|restart` command that names a container: `openvpn` → `openvpn-usa`, `sing-box` → `sing-box-usa`, `wg-easy` → `wg-easy-usa` (lines in "6. Проверка запуска", "7. Тест", "Восстановление", "Диагностика", "Полезные команды"). Keep column alignment of the comments in "Полезные команды". Do NOT change `docker compose …` commands (they use service names) or the image name `usa-tunnel-openvpn`.
2. Replace the section `### 4. Остановить другой стек` (heading through the `wg-data/` paragraph) with:

````markdown
### 4. Остановить другой стек

Этот стек и `synology-split-tunnel` используют одни порты (51820/udp, 51821/tcp), поэтому одновременно работает только один. Имена контейнеров у стеков разные, так что оба можно держать развёрнутыми в Container Manager. Перед запуском остановить стек VLESS:

```bash
cd /volume1/docker/synology-split-tunnel
docker compose stop
```

Чтобы Mikrotik-пир подключался к обоим стекам без перенастройки, ключи WireGuard должны быть одинаковыми: скопировать `wg-data/` из `synology-split-tunnel` в `Synology-USA-tunnel`. Настройки WireGuard (Host, Port, DNS, Allowed IPs, Keepalive) в wg-easy v15 задаются в Web UI и хранятся в `wg-data/`.
````

3. Insert before `## Восстановление`:

````markdown
## Переключение USA ↔ VLESS

Работает один стек: по умолчанию USA. После перезагрузки DSM всегда поднимается USA-стек (`restart: always`), VLESS-стек сам не запускается (`restart: "no"`).

| Куда | Container Manager | Или по SSH |
|------|-------------------|------------|
| USA → VLESS | Проект `Synology-USA-tunnel` → «Остановить», затем `synology-split-tunnel` → «Запустить» | `cd /volume1/docker/Synology-USA-tunnel && docker compose stop && cd ../synology-split-tunnel && docker compose up -d` |
| VLESS → USA | Проект `synology-split-tunnel` → «Остановить», затем `Synology-USA-tunnel` → «Запустить» | `cd /volume1/docker/synology-split-tunnel && docker compose stop && cd ../Synology-USA-tunnel && docker compose up -d` |

Ошибка `port is already allocated` при запуске значит, что второй стек ещё работает: сначала остановить его.

````

- [ ] **Step 5: install.md**

1. Same container-name replacement as README step 4.1 (lines with `docker logs openvpn`, `docker stop/start openvpn`, `docker restart openvpn`, `docker logs sing-box`, `docker restart sing-box`). Keep `docker compose up -d --force-recreate sing-box openvpn` unchanged.
2. Replace the section `## 3. Остановить старый стек` (heading through the `wg-data/` sentence) with:

````markdown
## 3. Остановить VLESS-стек

Оба стека занимают одни порты (51820/udp, 51821/tcp) — работает только один. Имена контейнеров разные, оба стека можно держать развёрнутыми.

```bash
cd /volume1/docker/synology-split-tunnel
docker compose stop
```

Чтобы Mikrotik подключался к обоим стекам без перенастройки, скопировать `wg-data/` из `synology-split-tunnel` в `Synology-USA-tunnel` (одинаковые ключи WireGuard).

Если при запуске ошибка `The container name "/wg-easy" is already in use` — у вас старая версия этого стека; обновить файлы и повторить.
````

3. Insert before `## Mikrotik`:

````markdown
## Переключение USA ↔ VLESS

По умолчанию работает USA; после перезагрузки DSM всегда поднимается USA, VLESS сам не стартует.

- **USA → VLESS:** Container Manager → проект `Synology-USA-tunnel` → «Остановить», затем `synology-split-tunnel` → «Запустить».
- **VLESS → USA:** наоборот.
- `port is already allocated` при запуске — второй стек ещё работает, сначала остановить его.

````

4. Replace the table row `| Вернуться на старый стек | … |` with:

```markdown
| Переключиться на VLESS и обратно | См. «Переключение USA ↔ VLESS» выше |
```

- [ ] **Step 6: Run the checks to verify they pass**

Run the Step 1 commands again.
Expected: `jq` prints `true`; the first grep prints nothing (exit 1); the count grep prints `README.md:2` and `install.md:1` (service-name commands unchanged); the last grep prints `README.md` and `install.md`. Also `(cd Synology-USA-tunnel && docker compose config -q) && echo COMPOSE_OK` prints `COMPOSE_OK`.

- [ ] **Step 7: Commit**

```bash
git add Synology-USA-tunnel/docker-compose.yml Synology-USA-tunnel/README.md Synology-USA-tunnel/install.md
git diff --cached --stat
git commit -m "feat(usa-tunnel): unique container names and always restart for stack switching"
```

Expected `--stat`: exactly those three files.

---

### Task 2: split-tunnel never autostarts + coexistence check

**Files:**
- Modify: `synology-split-tunnel/docker-compose.yml` (only the two `restart:` lines; the file has uncommitted user edits)

**Interfaces:**
- Consumes: Task 1 compose (container names `*-usa`).

- [ ] **Step 1: Write the failing check** (repo root)

```bash
(cd synology-split-tunnel && docker compose config --format json | jq -e '([.services[] | .restart] | unique) == ["no"]')
```

- [ ] **Step 2: Run it to verify it fails**

Expected: `false` (both services are `unless-stopped`).

- [ ] **Step 3: Change the restart lines in the working tree**

In `synology-split-tunnel/docker-compose.yml` replace both `restart: unless-stopped` with `restart: "no"`, and directly above the `wg-easy` service's `restart:` line add:

```yaml
    # Never autostart: started by hand only. Synology-USA-tunnel (restart
    # always) is the default stack; both publish the same ports.
```

Touch nothing else in the file.

- [ ] **Step 4: Run the check to verify it passes**

Run the Step 1 command. Expected: `true`.

- [ ] **Step 5: Coexistence check** (scratch copies; no secrets copied, nothing created in the repo)

```bash
S=$(mktemp -d)
mkdir -p "$S/split/scripts" "$S/usa/scripts"
cp synology-split-tunnel/docker-compose.yml "$S/split/"
cp Synology-USA-tunnel/docker-compose.yml "$S/usa/"
cp -R Synology-USA-tunnel/openvpn-client "$S/usa/"
(cd "$S/split" && docker compose -p coexist-split create) >/dev/null 2>&1
(cd "$S/usa" && docker compose -p coexist-usa create) >/dev/null 2>&1
docker ps -a --format '{{.Names}}' | grep -E '^(wg-easy|sing-box|openvpn)(-usa)?$' | sort
docker start wg-easy >/dev/null && docker start wg-easy-usa 2>&1 | grep -o 'port is already allocated' | head -1
(cd "$S/usa" && docker compose -p coexist-usa down) >/dev/null 2>&1
(cd "$S/split" && docker compose -p coexist-split down) >/dev/null 2>&1
docker ps -a --format '{{.Names}}' | grep -E '^(wg-easy|sing-box|openvpn)(-usa)?$' || echo CLEAN
```

Expected: five names `openvpn-usa`, `sing-box`, `sing-box-usa`, `wg-easy`, `wg-easy-usa` (no name conflict); `port is already allocated`; `CLEAN`.
Precondition: no containers with these names exist on the machine (`docker ps -a`); if they do, stop and ask.

- [ ] **Step 6: Commit only the restart change**

The working-tree file also holds the user's uncommitted edits. Stage HEAD's version plus only the restart change, leave the working tree as is:

```bash
F=synology-split-tunnel/docker-compose.yml
T=$(mktemp)
git show HEAD:$F | python3 -c '
import sys
s = sys.stdin.read()
assert s.count("    restart: unless-stopped\n") == 2
s = s.replace("    restart: unless-stopped\n", "    # Never autostart: started by hand only. Synology-USA-tunnel (restart\n    # always) is the default stack; both publish the same ports.\n    restart: \"no\"\n", 1)
s = s.replace("    restart: unless-stopped\n", "    restart: \"no\"\n", 1)
sys.stdout.write(s)' > "$T"
git update-index --cacheinfo 100644,"$(git hash-object -w "$T")",$F
git diff --cached
git commit -m "feat(split-tunnel): never autostart; USA stack is the default"
git diff $F
```

Expected: `git diff --cached` shows only the comment and the two `restart:` lines; after the commit, `git diff $F` shows only the user's earlier edits (WG_* removal, `ip_forward=0`, `|| exit 1`), no `restart:` lines.
