# Guided setup upgrade plan

Status: staged implementation in progress. The confirmed target is
https://github.com/dany547/linux-onboarding-script (`main`), cloned into
`/home/dan/CODE/linux-onboarding-script`. The user approved importing the extended
local baseline and replacing the README with English documentation. Original
files in `/home/dan/CODE/scripts` remain untouched.

## Current increment

- `v2.6.0`: local baseline imported, English README, SemVer changelog/tag and CI;
  baseline regression suite passed (208 checks).
- `v2.7.0`: explicit component choice precedence fixed, opt-in conservative wizard,
  read-only inventory, independent SSH/firewall preservation, EOF/conflict guards,
  no-op selection without APT and focused regression coverage.
- Published `main`, `v2.6.0` and `v2.7.0` via the existing GitHub SSH identity.
  HTTPS attempts used unsuitable credentials/scopes; no additional OAuth scope
  or account permission was needed. Release authors use GitHub noreply email.
- `v2.7.1`: all script-owned user-facing text translated to English, with the
  208 legacy checks retained and 37 guided checks passing.
- `v2.8.0`: additive POSIX launcher and limited Alpine 3.24.x APK/OpenRC backend
  for explicit Docker/Compose/Tailscale choices. SSH/firewall/auth/users/automatic
  updates remain preserve-only on Alpine; unsupported requests fail early.
  See `ALPINE-VALIDATION.md` for actual userspace/package evidence and VM gaps.
- Remaining stages below are a roadmap, not implemented promises. Timed access
  rollback, reconnection proof, durable plans/resume/locking and full host-health
  and firewall-backend checks are not implemented; no real-VM validation performed.

## Goal

Make setup easy for beginners and safe to rerun on existing Debian/Ubuntu hosts.
Automatically discover facts; ask users for intent. Never treat incomplete network
or service detection as permission to change access or overwrite configuration.

## Existing behavior and impact

- `debian-setup.sh`: interactive feature questions currently override explicit
  component settings; SSH/UFW and base packages are not individually optional.
- `tests/run.sh`: regression suite for CLI/config, access guards and configuration.
- `examples/*.conf`: existing automation contracts that must remain documented.
- `README.md`: replace Romanian documentation with accurate English documentation
  after implementation, using targeted edits where feasible.
- `docs/TEST-VM.md`: extend real-host validation, separate from mocked tests.

Compatibility policy: preserve existing unattended defaults; introduce safer
behavior through additive guided-setup flags. Explicit CLI/config choices must
never be silently replaced by wizard answers. Breaking changes require an
explicit migration plan and a major version; never silently reinterpret fleet
configuration.

## Stage 1 — Configuration precedence and explicit choices

- Track whether a choice came from CLI, config, wizard or default.
- Enforce CLI > config > wizard > default regardless of CLI argument order.
- Ask only about unspecified choices. Explicit `--no-*` must never be reversed.
- Define component actions: preserve, install/configure, omit. Omit does not
  uninstall, stop or disable an existing service.
- Add independent controls for SSH, firewall and system upgrade.
- Specify which base dependencies remain necessary for selected actions.
- Validate contradictory choices before any mutation.

Acceptance: table-driven tests for precedence, repeated flags, config files,
interactive answers, dry-run and unattended execution; preserved components
produce no related package, repository, configuration or service mutations.

## Stage 2 — Read-only discovery

- Inventory OS, architecture, virtualization, privileges and container restrictions.
- Check dpkg/APT health, disk space and reboot-required indicators.
- Separate installed, enabled, running and configured service states.
- Inventory SSH listeners/effective configuration, current session source,
  interfaces, routes, VPN state and firewall backends.
- Report provenance and confidence: confirmed, inferred, unknown/conflicting.
- Never infer public exposure from private addressing or absence of UFW.
- Avoid changing APT, creating system logs or touching configuration during discovery.

Acceptance: fixture-driven missing-command, malformed-output, IPv4/IPv6,
multi-interface, NAT, proxy/bastion and LXC scenarios. Unknowns remain explicit.

## Stage 3 — Guided interactive setup

- Offer simple and advanced paths; explain technical terms in plain language.
- Ask about purpose, intended access and desired components.
- Present detected values for confirmation rather than requiring CIDR knowledge.
- Offer preserve/back/help/cancel; hide irrelevant follow-up questions.
- Keep the wizard separate from the mutation engine.
- Render one immutable action plan consumed by preview and apply.
- Show package upgrades, service restarts, changed files and access risks.

Acceptance: scripted TTY transcripts, EOF/cancel tests and preview/apply plan parity.

## Stage 4 — Access safety and recovery

- Preserve SSH and firewall by default on existing hosts unless explicitly selected.
- Reject conflicting firewall ownership rather than modifying several backends.
- Validate SSH syntax and effective settings before reload.
- Establish a tested rollback mechanism before any access-affecting mutation.
- Snapshot only managed state with restrictive permissions; record recovery steps.
- Make rollback survive disconnects, process exit and relevant service restarts.
- Require a new SSH connection and explicit confirmation before cancelling rollback;
  the original connection alone does not prove future access.
- If rollback cannot be armed and verified, refuse remote access changes.
- Define expiry, concurrency locking, stale-run handling and reboot behavior.

Acceptance: disposable VM tests for successful reconnection, lost sessions,
timeout rollback, invalid configuration, interrupted apply and rollback failure.
Mock tests alone do not establish remote-access safety.

## Stage 5 — Reruns and final guidance

- Change and restart only what differs from the selected desired state.
- Use a per-host execution lock; do not resume from a stale checkpoint blindly.
- Save reusable non-secret choices only with explicit consent and safe permissions.
- Separate fatal safety failures from optional-component failures.
- Verify runtime behavior and report success, failed, preserved and pending actions.
- Explain outstanding VPN authentication and reboot needs without doing them implicitly.

Acceptance: repeat-run idempotency, partial-failure recovery and secret-free
logs/reports; no automatic reboot or credential capture.

## Stage 6 — Documentation, review and GitHub delivery

- Write the README in English with new-host/existing-host walkthroughs, compatibility
  notes, conservative examples, flags, exit codes, rollback and troubleshooting.
- Update configuration examples and the real-VM checklist.
- Run syntax checks, the regression suite and available static analysis.
- Review the entire diff for unrelated edits, credentials and unsupported claims.
- Clearly label real-VM tests not performed; do not claim production readiness.
- Commit only reviewed, completed work and push normally to the confirmed GitHub
  remote/branch. Never force-push or stage unrelated files.

## Parallel work boundaries

After Git location and compatibility policy are confirmed:
1. Coordinator owns `debian-setup.sh`; implementation stages are sequential.
2. Read-only reviewer maps regression gaps and risky access paths independently.
3. Documentation writer works on the English README once the CLI contract is stable.
4. A separate final review follows integration; no two agents edit the same file.

Delegation must use the approved provider/model bindings and pass the Herdr RAM,
workspace and provider gates. Agents must not commit, push or run host setup.

## Rollback of development changes

Work on a dedicated branch in the confirmed checkout and keep stages separately
reviewable. Preserve pre-existing work. No reset, deletion, history rewriting or
restoration over user edits without explicit confirmation.
