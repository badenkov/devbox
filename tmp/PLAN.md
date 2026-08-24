# PLAN

Локальные NixOS-машины на Cloud Hypervisor. Конфиг VM — обычный NixOS-модуль + npins, не flake.

Модель как в `~/Projects/dotfiles/modules/devvm`, но CLI свой, VMM — CH:

- изолированный store в `DEVBOX_CACHE/<name>/guest-store/nix/store` (не хостовый `/nix/store`);
- гость монтирует его virtiofs RO как `/nix/store`; UID/GID host-cache отображаются в `root:root`;
- persist — маленький qcow (`/home`, `/var`);
- бут: `--kernel` + `--initramfs` с хоста, `init=${toplevel}/init`;
- apply: populate store + `switch-to-configuration` по SSH + live host-network policy/port forwards;
  новое ядро — `stop`/`start`.

microvm.nix как продукт не используем. nixbox не тащим.

## Команды

| | |
|---|---|
| `create CONFIG [NAME]` | toplevel, store, persist, ключ |
| `start [NAME]` | virtiofsd + CH в фоне |
| `stop [NAME]` | ACPI shutdown, TAP |
| `apply CONFIG [NAME]` | populate; если running — switch |
| `shell [NAME]` / `exec NAME -- COMMAND` | SSH shell / команда |
| `forward NAME HOST[:GUEST]` | временный localhost → guest SSH tunnel |
| `console [NAME]` / `logs [-f] [NAME]` | serial socket / лог CH |
| `ls` / `status NAME` / `ssh [NAME]` / `rm NAME` | |

Конфиг только у `create` и `apply`. Имя — аргумент или `devbox.name`.

`start` запускает CH в фоне. `console` подключается к serial socket. `exit`/`Ctrl-D` завершают гостевой shell, после чего serial getty снова делает autologin; для отсоединения клиента используется `Ctrl-]` в английской раскладке. Закрытие терминала не выключает VM. TAP и host network policy применяет узкий root-helper `devbox-net`; CH, virtiofsd, Nix и state остаются под обычным пользователем. SSH-пользователь — `dev`.

## Layout

Durable и пригодно для backup — `DEVBOX_STATE/<name>/`, иначе `$XDG_STATE_HOME/devbox`:

```
state.json           # стабильная спека, identity, network policy и declarative forwards
persist.qcow2
ssh/
nix/                 # default, machine, npins, devbox templates, user config tree
```

Восстанавливаемый cache — `DEVBOX_CACHE/<name>/`, иначе `$XDG_CACHE_HOME/devbox`:

```
guest-store/nix/{store,var}/
build/{build.json,gcroots}/
logs/
```

Эфемерный runtime — `DEVBOX_RUNTIME/<name>/`, иначе `$XDG_RUNTIME_DIR/devbox`, fallback `/tmp/devbox-$UID`:

```
runtime.json          # status, pid, virtiofsd_pid, forward_pid
api.sock
console.sock
virtiofs.sock
forward-control.sock
```

Привилегированный сетевой runtime не входит в `DEVBOX_STATE` и backup:

```
/run/devbox-net/<slot>/
dnsmasq.conf
dnsmasq.pid
dnsmasq.log
```

Devshell: `DEVBOX_{STATE,CACHE,RUNTIME}=$PWD/tmp/{state,cache,runtime}`.

`create`/`apply` не меняют каталог исходного config. Config tree копируется в state Nix project; модули devbox рендерятся туда же, `npins` принадлежит project VM. Populate: `cp --reflink=always` на одном btrfs, иначе `nix copy --to`. После удаления cache следующий `start` пересобирает system/store из durable project.

## Репо

```
nix/guest.nix                    # только imports
nix/guest/modules/{options,boot,networking,ssh}.nix
nix/guest/profiles/{qemu,console}.nix
nix/lib/{eval-info,tools,closure-info}.nix
nix/host/devbox.nix              # NixOS host module: sysctl, firewall, sudoers, packages
exe/devbox-net                   # минимальный privileged network helper
lib/devbox/network.rb            # unprivileged policy/forward orchestration
examples/config.nix
```

`eval-info.nix` — JSON `config.devbox` + пути boot для CLI.  
`tools.nix` — cloud-hypervisor, virtiofsd.

Гость: tmpfs `/`, virtiofs `/nix/store`, persist label `persist`, bind `/home` и `/var`. systemd initrd: unit `devbox-persist-dirs`. `system.stateVersion` 26.11. SSH host key на `/var/lib/sshd`.

## Проверено

1. CH v53: `--initrd` → нужно `--initramfs` (уже в коде).
2. После падения CH teardown TAP через `tuntap del` → `TUNSETIFF: Invalid argument`; стейт застревал в `running`. Сейчас teardown — `ip link delete`, статус `stopped` пишется в `ensure`.
3. CH v53 принимает balloon только отдельным `--balloon`; вынесено из `--memory`.
4. TAP создавался multiqueue, но CH получал одну пару очередей (`num_queues=2`); теперь число virtqueues равно `2 * vcpus`, а для одной vCPU TAP создаётся без multiqueue.
5. CH v53 блокирует диск byte-range OFD-lock, не `flock`. `start` проверяет тот же lock до TAP/virtiofsd; `stop` умеет найти процессы после потери runtime. Лог прошлого запуска ротируется в `.previous`.
6. Live `apply` не загружает Nix DB внутри гостя: read-only store и DB подготавливаются на хосте, а по SSH через stdin запускается только root `switch-to-configuration`. Аргументы activation-скрипта нельзя передавать отдельными SSH argv — удалённый shell теряет их границы.
7. Unprivileged host-store виден через virtiofs с владельцем host user и ломает root ownership checks (например, `logrotate-checkconf`). `virtiofsd` запускается read-only с host UID/GID → guest root mapping.

Live boot и serial console работают. `start` фоновый, обычный вход — `shell`, команды — `exec`.

```sh
devbox start example
devbox shell example
devbox exec example -- uname -a
devbox console example
```

Legacy `example` мигрирована в layout v2; `examples/npins` перенесён в durable project и удалён из исходников.

## Host networking — целевая модель

### Identity и адреса

Bridge пока не используется: VM изолированы на L2, у каждой собственный TAP и подсеть.

```
VM slot N: 10.201.N.2
host/TAP:  10.201.N.1
gateway:   10.201.N.1
DNS:       10.201.N.1
TAP:       devboxN
```

Префикс новых машин — `/30`: в каждой подсети нужны только host `.1` и guest `.2`.
Существующие `/24` должны мигрировать без смены адресов либо продолжать работать до
явной миграции. IPv6 пока не маршрутизируется и не должен обходить IPv4 policy.

`slot` — durable источник истины. TAP, host/guest IP и MAC вычисляются из него.
Поля `tap`, `ip`, `host_ip`, `mac` формата v2 читаются для совместимости; после
миграции не должны быть независимыми изменяемыми значениями.

OFD-lock диска всегда проверяется **до** `devbox-net ensure`: потерянный runtime не
должен приводить к изменению TAP/nftables до обнаружения живого CH.

### Guest options

```nix
devbox.network = {
  mode = "allowlist"; # off | allowlist | open
  allowedDomains = [ "github.com" "*.githubusercontent.com" ];
  allowedCIDRs = [ ];
  allowedTCPPorts = [ 80 443 ];
  allowedUDPPorts = [ ];
};

devbox.forwardPorts = [
  {
    bind = "127.0.0.1";
    hostPort = 3000;
    guestPort = 3000;
  }
];
```

Семантика:

- `off` — нет внешнего forwarding;
- `allowlist` — destination должен одновременно соответствовать разрешённому
  domain-derived IP или `allowedCIDRs` и разрешённому TCP/UDP port;
- `open` — исходящий IPv4 разрешён без domain/IP allowlist, но VM→VM и VM→host
  ограничения сохраняются;
- пустой allowlist в `allowlist` означает deny all;
- домен без `*.` включает apex и все его поддомены; ведущий `*.` нормализуется к
  той же suffix-семантике dnsmasq;
- CIDR нужны для явного доступа по IP и к VPN/private networks;
- private, link-local, metadata и `10.201.0.0/16` destinations по умолчанию
  запрещены; исключения только через `allowedCIDRs`;
- DNS из гостя разрешён только на `10.201.N.1:53`; внешний DNS/DoT блокируется.

Domain allowlist — L3/L4 policy, не HTTP security boundary: общий CDN IP позволяет
обратиться к другому hostname на том же IP. Строгая проверка Host/SNI потребовала бы
proxy и пока не входит в scope.

### Default firewall policy

- host → VM разрешён (SSH/debug/forward tunnel);
- VM → internet определяется `mode` и allowlist;
- internet/другие host interfaces → VM: только `established,related`;
- VM → VM запрещён;
- VM → host: DNS, необходимые ICMP и `established,related`; остальные host services
  запрещены;
- NAT: masquerade только для разрешённого traffic из `10.201.0.0/16` наружу.

Одна общая nftables-таблица `inet devbox`, но отдельные chains/sets на slot. Нельзя
создавать отдельную base chain с `policy accept` на каждую VM: `accept` в одной
base chain не отменяет drop в другой, а несколько per-VM chains усложняют порядок.
На NixOS разрешающий forwarding встраивается в штатный nftables firewall через
host module; helper управляет только таблицей/sets devbox и TAP lifecycle.

Все TAP получают отдельную link group (зарезервированный numeric group id), чтобы
общие правила матчились через `iifgroup`/`oifgroup`, а slot-specific policy — через
имя/mark. Docker/iptables compatibility должна быть явной частью host module или
диагностикой, а не скрытым безусловным изменением `DOCKER-USER`.

### DNS и per-VM allowlist

DHCP не нужен: IP/gateway/DNS детерминированы и записываются в guest networkd config.
Dnsmasq используется как DNS proxy и как источник IP для nftables sets.

Из-за разных allowlist и требования live `apply` используется отдельный dnsmasq на
slot, привязанный только к `10.201.N.1:53`. Это позволяет заменить policy одной VM,
не перезапуская DNS остальных. Dnsmasq:

- читает только сгенерированный и провалидированный helper config;
- использует host resolver (`127.0.0.53`, если активен systemd-resolved; иначе
  nameservers host resolv.conf), чтобы сохранялся VPN split DNS;
- в `allowlist` имеет upstream rules только для разрешённых suffix domains;
- через `nftset` добавляет A records в slot-specific IPv4 sets;
- не предоставляет DHCP/TFTP и после bind сбрасывает лишние privileges настолько,
  насколько позволяет обновление nftset;
- не использует публичный DNS fallback вроде `8.8.8.8`.

Перед реализацией проверить поведение `dnsmasq --nftset` для CNAME и TTL. Policy
sets должны истекать/очищаться так, чтобы удалённый domain не оставлял бессрочно
разрешённый IP. При live замене неизменённые domain sets желательно сохранять,
чтобы client DNS cache не вызывал временные отказы новых соединений.

### Privileged helper

`devbox-net` — отдельный immutable executable, не subcommand полного CLI:

```
devbox-net ensure SLOT QUEUES       # TAP, owner from SUDO_UID, address, link group
devbox-net apply-policy SLOT        # validated policy JSON from stdin
devbox-net delete SLOT              # dnsmasq, nft slot state, TAP
devbox-net reconcile                # idempotent repair after host firewall reload
```

Требования:

- никаких `sh -c`, произвольных команд, путей, interface names или IP;
- slot `0..255`, queues/ports/CIDR/domain строго валидируются;
- TAP/IP/MAC/table/set names только вычисляются из slot;
- caller/owner берётся из защищённого `SUDO_UID`, production sudo rule использует
  `NOPASSWD` + `NOSETENV`;
- абсолютные store paths к `ip`, `nft`, `dnsmasq`;
- операции сериализуются lock-файлом и идемпотентны;
- nft changes применяются одной transaction; candidate dnsmasq config сначала
  проверяется `dnsmasq --test`;
- ошибка сохраняет/восстанавливает предыдущую рабочую policy;
- helper не читает и не пишет `DEVBOX_STATE`, `DEVBOX_CACHE` и user project.

В development `Runner#privileged!` запрашивает обычный sudo password. NixOS host
module устанавливает package/helper и выдаёт NOPASSWD только на точный store path
`devbox-net`, включает `net.ipv4.ip_forward=1`, nftables integration и необходимые
packages. Не выдавать NOPASSWD на `ip`, `nft`, `dnsmasq` или `sh`.

### Port forwarding и secure context

Host port публикуется не через DNAT, а через SSH local forwarding:

```
127.0.0.1:HOST_PORT -> SSH -> 127.0.0.1:GUEST_PORT
```

`http://localhost:PORT`, `127.0.0.1` и `*.localhost` считаются браузером potentially
trustworthy origin; порт на secure-context status не влияет.

- ad-hoc `devbox forward NAME 3000` означает `3000:3000` и остаётся attached;
- `devbox forward NAME 8080:3000` публикует guest `3000` на host `8080`;
- declarative `devbox.forwardPorts` стартуют после готовности SSH;
- один SSH process/control socket на VM содержит все declarative `-L`;
- `ExitOnForwardFailure=yes`; конфликт host port — ошибка, не молчаливый skip;
- default bind только `127.0.0.1`; `0.0.0.0` запрещён, пока не появится отдельная
  явно опасная option;
- forward PID/control socket только в runtime; `stop` удаляет forwards до guest
  shutdown; stale runtime восстанавливается по control socket/process discovery.

## Live `apply`: system + network + forwards

`apply` обязан менять network policy и declarative forwards работающей VM без
перезапуска CH. Новый kernel по-прежнему требует `stop`/`start`.

Порядок:

1. Подготовить candidate project во временном staging (с сохранением текущего
   `npins`), evaluate и полностью проверить новую system/network/forward spec без
   изменения durable project/state.
2. Собрать/populate candidate store как сейчас, сохранив предыдущие build metadata
   и toplevel для rollback.
3. Подготовить candidate dnsmasq config и nft transaction; проверить config, CIDR,
   domains, ports и занятость новых host ports.
4. Для running VM сначала установить candidate host policy (старый guest продолжает
   работать с теми же адресами), затем выполнить guest `switch-to-configuration` и
   применить diff declarative SSH forwards. Краткий DNS/forward reconnect допустим,
   VM restart — нет.
5. Перезапустить только dnsmasq данного slot и атомарно заменить его nft
   chains/sets. При любой последующей ошибке восстановить предыдущие dnsmasq config,
   nft policy и forwards; после неудачной guest activation попытаться активировать
   предыдущий toplevel и явно сообщить, если system rollback тоже не удался.
6. Только после полного успеха атомарно заменить durable `nix/` candidate project и
   записать новую spec/build metadata. Не оставлять новый project при старом
   `state.json` или наоборот.

Для stopped VM `apply` сохраняет новую durable network/forward spec, но не создаёт
TAP, dnsmasq, nft slot state или SSH tunnel: всё материализуется следующим `start`.
Изменение `mode`, domains, CIDRs, ports и forwards не требует stop/start.

`apply` не должен брать network policy из исходного config после завершения: как и
system closure, она живёт в автономном `DEVBOX_STATE/<name>/nix` и отражена в
`state.json` для lifecycle/status.

## Следующая реализация

Состояние на 2026-08-23:

- [x] Guest options и export через `eval-info.nix`:
  `devbox.network.{mode,allowedDomains,allowedCIDRs,allowedTCPPorts,allowedUDPPorts}`
  и `devbox.forwardPorts`; добавлена валидация mode, domains, IPv4 CIDR, bind и
  диапазона портов; ведущий `*.` нормализуется при export.
- [x] State format v3: `slot` стал единственным durable источником `tap`, guest/host
  IP и MAC; эти derived-поля больше нельзя независимо записать в `state.json`.
- [x] Новые VM получают `/30`; миграция v2 сохраняет прежние адреса и `/24` через
  durable `network_prefix`, поэтому существующие машины не меняют сеть.
- [x] Guest networkd получает вычисленный prefix и DNS на host TAP; IPv6 RA и
  link-local addressing отключены.
- [x] Network policy и declarative forwards сохраняются в durable state при
  `create`/`apply` и восстанавливаются из автономного Nix project.
- [x] Добавлены unit tests state migration/derived identity и machine spec; реальная
  NixOS evaluation новой option schema прошла.
- [x] Текущие проверки: `bundle exec rake` — 39 tests, 278 assertions, RuboCop без
  замечаний; `nix flake check --no-build` — успешно на x86_64-linux.

### Handoff для новой сессии

Снимок реализации, от которого начат handoff, — HEAD `2693d7a`. После него выполнен
этап 2A: изменены `flake.nix`, `Rakefile`, добавлен
`test/integration/dnsmasq_nftset_test.sh` и обновлён этот план. Privileged helper,
production dnsmasq/nftables policy, SSH forwards и transactional live `apply` ещё
не начаты.

Текущий lifecycle всё ещё напрямую выполняет `sudo sh -c` с `ip` в
`Hypervisor#ensure_tap`/`teardown_tap`. До замены этого кода обязательно сохранить
порядок в `Machine#start`: проверка OFD-lock диска должна происходить раньше любых
вызовов будущего `devbox-net`.

Этап **2A, dnsmasq/nftset research spike** — завершён:

- [x] В dev shell добавлены версии из locked nixpkgs: dnsmasq 2.93 с `nftset`,
  nftables 1.1.6 и dig 9.20.26. В runtime package они пока намеренно не добавлены.
- [x] `bundle exec rake integration:dnsmasq_nftset` запускает harness в отдельном
  unprivileged user+network namespace. Host nftables, production table `inet
  devbox` и TAP не изменяются; cleanup работает при success и failure.
- [x] Прямой A и все адреса multi-A добавляются. Для CNAME dnsmasq добавляет
  конечный A, включая target вне разрешённого suffix и private target. Поэтому
  общий deny private/link-local/metadata диапазонов обязан иметь приоритет над
  совпадением domain-derived set.
- [x] NXDOMAIN ничего не добавляет. Restart/reload dnsmasq и удаление `--nftset`
  не очищают существующие элементы; tighten policy обязан атомарно перестать
  ссылаться на старый set либо явно flush/replace его.
- [x] dnsmasq не переносит DNS TTL в nftables: элемент получает default timeout
  set. Повторный cached ответ и даже новый upstream ответ для того же IP не
  обновляют timeout существующего элемента.

Выбранный contract для production policy: dnsmasq работает с `cache-size=0` и
client-facing `max-ttl=1`; domain sets имеют bounded default timeout. После expiry
следующий DNS lookup снова добавляет IP. Это намеренно предпочитает временный deny
устаревшему разрешению. Конкретный production timeout оформить именованной
константой и покрыть helper tests; значение не должно приходить из user policy.
Неизменённый set можно сохранить при live apply, но удалённый domain получает новый
set/chain без старых элементов. Restart dnsmasq сам по себе не считается cleanup.

Этап **2B, минимальный privileged helper** — завершён:

- [x] Реализован `exe/devbox-net` без shell и unit tests на hostile input,
  validation, serialization и idempotence. Сначала только `ensure SLOT QUEUES` и
  `delete SLOT`; `apply-policy SLOT` и `reconcile` добавлять после зафиксированного
  contract этапа 2A.
- [x] Helper принимает только slot/queue count, вычисляет interface/address/group
  сам и запускает абсолютные пути `ip` без `sh -c`; owner берёт только из
  проверенного `SUDO_UID`.
- [x] До подключения helper к lifecycle покрыты command construction и отказ на
  отсутствующий/невалидный `SUDO_UID`, slot вне `0..255`, queues вне допустимого
  диапазона и лишние argv.

Helper упакован отдельным `packages.devbox-net`: Ruby, библиотека и `ip` в точке
входа — абсолютные store paths. Root-процесс не загружает Thor/основной CLI.
Операции сериализуются через проверенный root-owned `/run/devbox-net/lock`; TAP
получает link group `201`. Допустимый queue count зафиксирован как `1..256`.

Текущие проверки после 2B: `bundle exec rake` — 50 tests, 330 assertions, RuboCop
без замечаний; `nix flake check --no-build` — успешно на x86_64-linux; отдельный
Nix build `packages.devbox-net` и smoke-test отказов executable — успешно.

Этап **3A, host module и общая nftables topology** — завершён:

- [x] Добавлен `nixosModules.devbox` с host packages, `ip_forward=1`, root-owned
  `/run/devbox-net` и точным sudo rule на store path helper с `NOPASSWD:NOSETENV`.
- [x] Включена штатная NixOS nftables `forward` chain с `policy drop`; отдельная
  `inet devbox` выполняется раньше неё, но не пытается обойти её verdict из другой
  base chain.
- [x] Общая topology запрещает VM→VM, guest IPv6, guest→host services и private /
  link-local / metadata destinations по умолчанию. Без активной slot policy входящий
  с TAP и исходящий guest traffic fail closed.
- [x] Зафиксированы per-packet marks: обычный allow `0x0000db01`, явное исключение
  private CIDR `0x0000db02`, DNS/ICMP к своему host TAP `0x0000db03`. NAT применяется
  только к первым двум marks; mark очищается перед каждым slot dispatch, поэтому
  firewall reload не оживляет старое разрешение.
- [x] Docker coexistence оформлен явно: при включённом Docker штатный NixOS forward
  пропускает originating traffic с `docker0`/`br-*` к политике Docker; это можно
  отключить с диагностическим warning.
- [x] Package definitions вынесены в `nix/packages.nix`; flake экспортирует module и
  `checks.<system>.host-module`. Check оценивает NixOS config, sudo contract и собирает
  полный сгенерированный ruleset через sandboxed `nft --check`.

Этап **3B, per-slot policy materialization** — завершён:

- [x] Helper расширен командами `apply-policy SLOT` и `reconcile`: strict JSON
  validation, slot chains/sets, три mark contract, atomic nft transaction и rollback.
- [x] Генерируется и проверяется отдельный dnsmasq config/process на slot, используется
  host resolver без public fallback, domain nft sets обновляются по contract 2A.
- [x] После firewall reload `reconcile` восстанавливает active slot policy;
  отсутствие сохранённой privileged policy остаётся fail closed.

Policy JSON ограничен по размеру, не допускает неизвестные/пропущенные/повторные
ключи и повторно валидирует mode, domains, IPv4 CIDR и ports независимо от Nix
evaluation. Нормализованная policy хранится только в root-owned
`/run/devbox-net/<slot>/policy.json`; это privileged runtime, не durable VM state.

Для каждого поколения policy helper вычисляет только безопасные nft identifiers,
создаёт slot input/forward chains и bounded domain set с именованным timeout 30s.
Вся dynamic topology активных slot-ов заменяется одной nft transaction. Поэтому
tighten немедленно перестаёт ссылаться на старый set, а повторный `reconcile`
идемпотентно восстанавливает topology после firewall reload. Сейчас transaction
пересоздаёт также неизменённые domain sets: их элементы временно теряются, но
`cache-size=0`, `max-ttl=1` и следующий DNS lookup снова наполняют set.

Per-slot dnsmasq привязан к host TAP IP, работает как `devbox-dns`, использует
systemd-resolved stub либо nameservers из host `resolv.conf`, а в allowlist mode
направляет upstream-запросы только для разрешённых suffix. Candidate config сначала
проходит `dnsmasq --test`. При ошибке запуска восстанавливаются предыдущие nft
policy, dnsmasq config/process и сохранённая policy; если `reconcile` не может
поднять DNS, dynamic dispatch очищается fail closed, а сохранённая policy остаётся
для следующей попытки.

Текущие проверки после 3B: `bundle exec rake` — 60 tests, 435 assertions, RuboCop
без замечаний; `integration:net_helper_policy` в отдельном user+network namespace
проверяет allowlist, idempotent reconcile и tighten до off настоящими nft 1.1.6 и
dnsmasq 2.93; `nix flake check --no-build`, build `devbox-net` и host-module check —
успешно на x86_64-linux.

Этап **3C, lifecycle integration privileged helper** — завершён:

- [x] `Hypervisor#ensure_tap`/`teardown_tap` переведены на точный `devbox-net` store
  path без `sudo sh -c`; после `ensure` применять сохранённую policy, а при stop/rm
  вызывать `delete`.
- [x] Сохранён обязательный порядок `Machine#start`: disk OFD-lock раньше любых
  TAP/nft/dnsmasq изменений; startup failure и lost-runtime stop должны удалять
  policy/DNS/TAP через helper.
- [x] Добавлены lifecycle tests на порядок, sudo invocation, rollback CH startup и
  stopped VM без материализации policy до следующего start.

CLI wrapper и dev shell передают `DEVBOX_NET_HELPER` как точный immutable store
path, совпадающий с sudo rule host module. Полный CLI больше не строит shell-команды
для `ip`: `start` вызывает `ensure SLOT QUEUES`, затем передаёт нормализованную
network policy JSON через stdin в `apply-policy SLOT`; `stop` и `rm` вызывают
идемпотентный `delete SLOT`, даже если VM уже считается stopped и TAP не виден.

Весь участок после OFD-lock охвачен startup rollback: ошибка ensure/policy,
virtiofsd или ранний выход CH останавливает virtiofsd, удаляет privileged
policy/dnsmasq/TAP, чистит sockets и возвращает durable/runtime status в stopped.
Runner передаёт policy stdin через direct, noninteractive sudo и interactive sudo
paths; password по-прежнему читается sudo с controlling TTY, а JSON идёт в pipe.

Текущие проверки после 3C: `bundle exec rake` — 67 tests, 460 assertions, RuboCop
без замечаний; `integration:net_helper_policy` — успешно; `nix flake check
--no-build`, build packages `devbox`/`devbox-net` и host-module check — успешно на
x86_64-linux. Smoke-check собранного wrapper подтвердил точный executable helper и
отсутствие загрузки полного CLI в root process.

Этап **4A, SSH forwarding lifecycle** — завершён:

- [x] Реализован один declarative SSH control process/socket на VM с
  `ExitOnForwardFailure=yes`, exact localhost binds и runtime PID/control socket.
- [x] Declarative forwards запускаются после SSH readiness; останавливаются до guest
  shutdown, cleanup восстанавливается при потерянном runtime.
- [x] Добавлен attached `forward NAME HOST[:GUEST]`, validation и tests на занятый
  host port, аргументные границы и cleanup.

Все declarative `-L` одной VM принадлежат одному SSH ControlMaster с точным runtime
socket `forward-control.sock`; PID хранится только в `runtime.json`. Startup ждёт
control socket и проверяет master через `ssh -O check`, поэтому конфликт host port
откатывает уже запущенные CH, virtiofsd и host network. `stop`/`rm` сначала делают
`ssh -O exit`, затем завершают оставшийся tracked либо обнаруженный через точный
control-socket argv процесс. Это работает и когда `runtime.json` либо весь runtime
каталог потерян. Ad-hoc forwarding всегда bind-ится к `127.0.0.1` и через `exec`
остаётся attached к терминалу.

Текущие проверки после 4A: `bundle exec rake` — 74 tests, 503 assertions, RuboCop
без замечаний; `nix flake check --no-build` текущей полной рабочей копии — успешно
на x86_64-linux (проверено через чистый `path:` source, поскольку файлы этапов
3A–3C пока untracked и обычный git flake их не видит).

Этап **4B, transactional live apply** — завершён:

- [x] Подготавливать project/system/spec в staging без изменения durable state до
  полного успеха.
- [x] Для running VM применять candidate host policy, guest activation и diff
  declarative forwards с rollback каждого слоя при ошибке.
- [x] Для stopped VM атомарно сохранять candidate project/spec без materialization
  TAP, dnsmasq, nftables или SSH tunnel.

Candidate Nix project и build gcroots создаются на тех же filesystems в отдельных
staging-каталогах; текущие `nix/`, `build/` и JSON state не меняются во время
evaluation/build/populate. Guest store пополняется аддитивно. Финальный commit
заменяет project/build через rename с восстановимыми backups, а JSON-файлы пишутся
через fsync + atomic rename; ошибка commit восстанавливает предыдущие каталоги и
metadata.

Для running VM порядок зафиксирован как host policy → guest activation → SSH
forward diff → durable commit. ControlMaster сохраняется для неизменённых forwards;
удаления и добавления выполняются через `ssh -O cancel/forward`. Ошибка любого слоя
запускает rollback в обратном порядке. Если rollback guest system либо host policy
сам завершился ошибкой, это явно добавляется к исходной ошибке. Для stopped VM
helper и SSH вообще не вызываются.

Текущие проверки после 4B: `bundle exec rake` — 80 tests, 543 assertions, RuboCop
без замечаний; `nix flake check --no-build` полной чистой `path:`-копии рабочей
директории — успешно на x86_64-linux. Добавлены unit tests на staged stopped apply,
неизменность durable project/state при build failure, порядок live apply и rollback
policy/system/forward diff при занятом новом порте. Candidate state-staging
также получает копию durable `ssh/authorized_key.pub` для evaluation; приватный
ключ в staging не копируется, а committed `machine.nix` сохраняет durable
относительную ссылку.

Live smoke на NixOS host module прошёл для `example`: stale-runtime `stop`,
`start`, SSH `exec`, declarative localhost forward на port 3000 и live `apply` с
активацией нового guest package без restart VM. HTTP response через
forward получен. Packaged CLI дополнительно проверен с Thor 1.4;
`tree` удаляется из command registry без `undef_method` отсутствующего
метода.

Cross-generation dnsmasq cleanup не полагается только на exact executable
store path: helper находит old-generation/orphan dnsmasq только по
`--conf-file` в root-owned каталоге конкретного slot. Посторонний dnsmasq
той же или другой generation не останавливается. Это также
восстанавливает cleanup после утраты `dnsmasq.pid`. Namespace integration
`integration:net_helper_policy` и build `devbox-net` — успешно.

Оставшийся backlog после 4B:

- [ ] Проверить реальное coexistence с Docker host и VPN split DNS; текущий Nix check
  покрывает совместный NixOS ruleset и Docker bridge hooks, но не live traffic.
- [ ] Выполнить интеграционные проверки: несколько одновременных VM, VM isolation,
  open/off/allowlist, hardcoded IP denial, private CIDR denial/allow, DNS CNAME/TTL,
  VPN split DNS, live apply policy tighten/relax, occupied forward port, lost
  runtime, CH startup failure и Docker host.
- [x] Обновить README и example config: описаны host module, network
  modes/allowlist, private CIDR contract, declarative/ad-hoc SSH forwards и
  transactional live `apply`; example показывает policy и localhost-forward.
  Повторные `bundle exec rake` — 80 tests, 543 assertions, RuboCop без
  замечаний; `nix flake check --no-build` — успешно на x86_64-linux.

## Не делаем

- полный qcow с store внутри;
- virtiofs на весь хостовый `/nix/store`;
- microvm.nix / nixbox как обвязка;
- flake-конфиг на каждую VM.
- sleep/snapshot: CH snapshot непереносим, зависит от версии VMM и усложняет runtime.
