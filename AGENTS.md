# AGENTS

Ruby CLI напрямую управляет Cloud Hypervisor; `microvm.nix` не используется.

- `lib/devbox/machine.rb` — lifecycle; `hypervisor.rb` — CH, TAP, virtiofsd; `state.rb` — layout; `nix.rb` — evaluation/build.
- Backup: только `DEVBOX_STATE`. Cache пересобирается, runtime эфемерен.
- Исходный config не менять: автономный проект находится в `DEVBOX_STATE/<name>/nix`.
- Проверять disk OFD-lock до изменения TAP. Потерянный runtime восстанавливает `stop`.
- Проверки: `bundle exec rake` и `nix flake check --no-build`.
