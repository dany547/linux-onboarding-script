# Alpine validation and limits

## Target

- Stable branch: Alpine **3.24**; patch checked: **3.24.2**.
- Official release source: https://alpinelinux.org/releases/
- Official artifact metadata:
  https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/latest-releases.yaml
- x86_64 minirootfs SHA256:
  `c5ca053cfe1d85c5b96dff8b9bc57045f7f184a30ffb6b65776409ca90388677`

Do not substitute Alpine edge, mix stable branches, or automatically enable
community repositories. A future stable branch needs its own validation.

## Checks performed during implementation

The official archive was downloaded over HTTPS, checked against the SHA256 in
official metadata and extracted into a new temporary directory. A rootless Linux
user-namespace chroot ran the real Alpine 3.24.2 userspace and BusyBox ash. No
host package manager, system service or firewall configuration was changed.

Inside that disposable rootfs, `apk update` and installation of the following
packages succeeded:

```
openrc docker docker-cli-compose docker-openrc
tailscale tailscale-openrc openssh-server
```

Observed CLI versions: Docker 29.8.2, Compose 5.1.4, Tailscale 1.98.10,
OpenSSH 10.3p1. These are evidence from the tested repository state, not versions
pinned by the onboarding script. The signed APK repositories choose patch versions.

Confirmed OpenRC scripts: `docker`, **`tailscale`** (not `tailscaled`), and `sshd`.

Final independent checks passed on the development host: 208 Debian/Ubuntu
regressions, 37 guided checks, 60 Alpine checks and 4 launcher checks, plus Bash/sh
syntax and ShellCheck. The same 60 Alpine checks and 4 launcher checks also passed
under real Alpine BusyBox ash (Bash was installed only to test the optional legacy
filename forwarding). Without Bash, the launcher suite has 3 applicable checks.

An actual Alpine dry-run with `examples/alpine.conf` printed APK/OpenRC operations
without changing the package DB, repositories, watched SSH/Docker configuration,
runlevel entries or log. An attempted service apply in the unbooted chroot was
refused with exit 3 before APK/log mutation. Service state is reported as unknown,
not stopped/running, when no booted OpenRC state is available.

The CI workflow includes a separate smoke check using the official
`alpine:3.24.2` container and the portable launcher. A workflow definition is not
proof that a remote CI run passed; consult the actual GitHub Actions run.

## Not established by a chroot or mocked tests

- Docker daemon, container networking, cgroups or kernel-module operation.
- OpenRC activation on a normally booted Alpine VM and persistence after reboot.
- Tailscale authentication or VPN/SSH reachability from another machine.
- Public exposure, provider firewall rules, or safety of changing remote access.
- Other CPU architectures or later Alpine stable branches.

The first Alpine backend must preserve existing access by default. Unsupported
policy options must fail before any package/service mutation, rather than silently
pretend to provide Debian/Ubuntu feature parity. In particular, do not replace
security-only unattended upgrades with an unreviewed daily `apk upgrade` job.

## Before recommending unattended production use

Use a disposable, booted Alpine 3.24 VM with provider-console access. Review the
plan; apply only the selected supported components; verify Docker and Compose,
authenticate Tailscale manually, reconnect from a second machine and reboot to
check OpenRC persistence. Repeat the run to check idempotence. Save actual outcomes
and failures separately from mocked test results. Do not run experimental SSH or
firewall changes against a server without an independent recovery path.
