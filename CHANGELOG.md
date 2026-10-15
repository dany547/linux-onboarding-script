# Changelog

Versions follow Semantic Versioning. Git tags use the `vMAJOR.MINOR.PATCH` format.
A version in this file is not a claim of production or real-VM validation.

## 2.7.1

- Translate all Debian/Ubuntu errors, warnings, progress messages, prompts, help,
  plan/verification/final summaries and generated explanatory text into English.
- Preserve CLI flags, config keys, command behavior, exit codes, placeholders and
  the legacy `da` yes-answer alias. Internal comments/test descriptions may remain
  Romanian; the script's user interface is English.
- Update exact output assertions and add an English wizard-output regression.
- Validation: 208 legacy checks and 37 guided checks passed; Bash syntax and
  ShellCheck passed. No live setup or VM behavior changed or newly validated.

## 2.7.0

First guided-setup increment; not the completion of the full upgrade plan.

- Add `--inspect`: read-only package/service inventory, inferred LAN and SSH facts,
  configuration-file existence, virtualization and reboot marker. No root or log
  creation; unknown public/provider/VPN reachability is explicitly reported.
- Add opt-in `--wizard` with preserve/omit defaults for services, SSH, firewall
  and full-upgrade; `--wizard --dry-run` previews those same choices.
- Preserve explicit component choices from CLI/config in interactive mode.
- Add `--no-ssh` (`MANAGE_SSH=no`) and `--no-firewall`
  (`SKIP_FIREWALL=yes`). Skipping UFW also skips its Fail2Ban integration.
- Omit openssh-server/UFW installation when those components are not managed.
- Fail closed on EOF and reject contradictory access-policy selections.
- In conservative/preserve modes, ask needrestart to list rather than automatically
  restart unrelated services. Package maintainer scripts can still restart services.
- Add focused guided-setup regression tests and extend CI.

Compatibility: existing non-interactive defaults remain unchanged. Explicit user/key
provisioning still runs with `--no-ssh`; this flag preserves sshd configuration,
not separately requested account changes. Package operations still install base
dependencies, and full-upgrade (when explicitly selected in the wizard, or left
at legacy defaults) can upgrade preserved components.

Remaining: timed SSH/firewall rollback and new-connection confirmation, durable
resume/locking, saved wizard plans, advanced/back/help navigation, complete host
health and conflicting firewall ownership checks. Real-VM validation has not run.
Published to GitHub via SSH after HTTPS credential/scope restrictions were
identified. Release commits use the GitHub noreply address.

## 2.6.0

Imported the previously unpublished local `2.6.0-c7a` implementation as the
versioned baseline, replacing the older GitHub script.

- Debian 12/13 and Ubuntu 22.04/24.04 support and distribution checks.
- Configuration files, explicit CLI controls and non-mutating dry-run planning.
- Official Docker/Tailscale repositories and Docker configuration merging.
- SSH access guards, key-only policy validation and managed administrator setup.
- Automated security update configuration and Fail2Ban checks.
- Regression fixtures, example configurations and a real-VM testing checklist.
- English README and a staged guided-setup upgrade plan.

Known limitations: interactive component questions can override explicit feature
choices; SSH/UFW are not independently optional; no timed SSH/firewall rollback
transaction. Existing hosts require careful plan review. VM validation remains
manual; see `docs/TEST-VM.md`.
