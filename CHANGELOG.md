# Changelog

Versions follow Semantic Versioning. Git tags use the `vMAJOR.MINOR.PATCH` format.
A version in this file is not a claim of production or real-VM validation.

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
