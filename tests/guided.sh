#!/usr/bin/env bash
# Read-only/unit and dry-run coverage. Never applies host configuration.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import os
from pathlib import Path
import subprocess
import tempfile

root = Path.cwd()
script = root / 'debian-setup.sh'
passed = 0

def run(code, expected='', rc=0, stdin=''):
    global passed
    result = subprocess.run(['bash', '-c', 'source "$1"; ' + code, 'test', str(script)],
                            input=stdin, text=True, capture_output=True,
                            env={k:v for k,v in os.environ.items() if not k.startswith('DS_')})
    assert result.returncode == rc, (code, result.returncode, result.stderr)
    assert result.stdout.strip() == expected, (code, result.stdout, expected)
    passed += 1

# No implicit execution when sourced; CLI/config sources suppress questions.
run('printf "%s" "$VERSION"', '2.8.0')
run('parse_args --no-docker --no-tailscale --no-fail2ban --no-auto-updates; '
    'yes_no() { return 99; }; resolve_feature_flags; '
    'printf "%s" "$INSTALL_DOCKER:$INSTALL_TAILSCALE:$INSTALL_FAIL2BAN:$INSTALL_AUTO_UPDATES"',
    'no:no:no:no')
for flag, key in [('--no-docker','INSTALL_DOCKER'), ('--no-tailscale','INSTALL_TAILSCALE'),
                  ('--no-fail2ban','INSTALL_FAIL2BAN'), ('--no-auto-updates','INSTALL_AUTO_UPDATES')]:
    run(f'parse_args {flag}; printf "%s" "${{{key}}}:${{CHOICE_SOURCE[{key}]}}"', 'no:cli')
run('yes_no() { return 1; }; resolve_feature_flags; '
    'printf "%s" "$INSTALL_DOCKER:$INSTALL_TAILSCALE:$INSTALL_FAIL2BAN:$INSTALL_AUTO_UPDATES"',
    'no:no:no:no')
run('yes_no "EOF must cancel" y', rc=2)
run('yes_no "EOF must cancel" n', rc=2)
run('WIZARD=yes; DRY_RUN=yes; resolve_mode >/dev/null', rc=2)
run('WIZARD=yes; DRY_RUN=yes; MODE=lan; resolve_lan_cidr', rc=2)
run('WIZARD=yes; DRY_RUN=yes; resolve_wireguard_cidr', rc=2, stdin='y\n')
run('export DS_UNTRUSTED_OVERRIDE=1; main --inspect', rc=2)
run('SKIP_FIREWALL=yes; print_plan_summary | grep -q "existing rules, unverified"; printf clear', 'clear')
run('parse_args --wizard --yes; validate_selection', rc=2)
run('parse_args --no-ssh --ssh-keys-only; validate_selection', rc=2)
run('parse_args --no-ssh --allow-users admin; validate_selection', rc=2)
run('parse_args --no-firewall --reset-firewall; validate_selection', rc=2)
run('parse_args --no-ssh --no-firewall; validate_selection; printf ok', 'ok')
run('MANAGE_SSH=no; run() { exit 91; }; write_file() { exit 92; }; configure_ssh; printf preserved', 'preserved')
run('MANAGE_SSH=no; SKIP_FIREWALL=yes; SKIP_UPGRADE=yes; INSTALL_DOCKER=no; '
    'INSTALL_TAILSCALE=no; INSTALL_AUTO_UPDATES=no; run() { exit 91; }; '
    'bootstrap >/dev/null; printf noop', 'noop')
run('SKIP_FIREWALL=yes; run() { exit 91; }; write_file() { exit 92; }; configure_ufw >/dev/null; '
    'configure_fail2ban >/dev/null; printf preserved', 'preserved')
run('dpkg-query() { printf "install ok installed"; }; package_state docker-ce', 'installed')
run('dpkg-query() { return 1; }; package_state docker-ce', 'absent-or-unregistered')
run('dpkg-query() { printf "deinstall ok config-files"; }; package_state docker-ce', 'not-fully-installed')
run('WIZARD=yes; package_state() { printf installed; }; '
    'yes_no() { [[ "$2" == n ]] || exit 91; return 1; }; '
    'resolve_component INSTALL_DOCKER docker-ce Docker >/dev/null; printf "%s" "$INSTALL_DOCKER"', 'no')
run('WIZARD=yes; package_state() { printf unknown; }; '
    'yes_no() { [[ "$2" == n ]] || exit 91; return 1; }; '
    'resolve_component INSTALL_DOCKER docker-ce Docker >/dev/null; printf "%s" "$INSTALL_DOCKER"', 'no')
run('WIZARD=yes; DRY_RUN=yes; yes_no() { [[ "$2" == n ]] || exit 91; return 1; }; '
    'resolve_access_choices >/dev/null; printf "%s" "$MANAGE_SSH:$SKIP_FIREWALL:$SKIP_UPGRADE"', 'no:yes:yes')
run('parse_args --wizard --no-ssh --no-firewall --skip-upgrade; '
    'yes_no() { exit 91; }; resolve_access_choices >/dev/null; '
    'printf "%s" "$MANAGE_SSH:$SKIP_FIREWALL:$SKIP_UPGRADE"', 'no:yes:yes')
run('open_log() { exit 91; }; preflight() { exit 92; }; bootstrap() { exit 93; }; '
    'detect_distro() { :; }; detect_ssh_port() { :; }; detect_ssh_source() { :; }; '
    'detect_lan_cidr() { :; }; print_inventory() { printf inventory; }; main --inspect', 'inventory')

with tempfile.TemporaryDirectory(prefix='onboarding-guided-') as directory:
    fixture = Path(directory) / 'choices.conf'
    fixture.write_text('INSTALL_DOCKER=yes\nINSTALL_TAILSCALE=no\nINSTALL_FAIL2BAN=no\n'
                       'INSTALL_AUTO_UPDATES=no\nMANAGE_SSH=no\nSKIP_FIREWALL=yes\nSKIP_UPGRADE=yes\n')
    for args in [f'--no-docker --config {fixture}', f'--config {fixture} --no-docker']:
        run(f'parse_args {args}; yes_no() {{ exit 91; }}; resolve_feature_flags; '
            'printf "%s" "$INSTALL_DOCKER:${CHOICE_SOURCE[INSTALL_DOCKER]}"', 'no:cli')
    run(f'parse_args --config {fixture}; yes_no() {{ exit 91; }}; resolve_feature_flags; '
        'printf "%s" "$INSTALL_DOCKER:${CHOICE_SOURCE[INSTALL_DOCKER]}"', 'yes:config')
    # Exercise the actual CLI plan, not mocked bootstrap functions.
    env = {k:v for k,v in os.environ.items() if not k.startswith('DS_')}
    env.update(DS_TEST='1', DS_ROOT_OK='1', DS_OS_RELEASE=str(root/'tests/fixtures/os-release.debian12'),
               DS_SSH_CHAIN='none', DS_SSH_SOURCE='')
    result = subprocess.run(['bash', str(script), '--dry-run', '-y', '--mode', 'lan',
                             '--no-ssh', '--no-firewall', '--skip-upgrade', '--no-docker',
                             '--no-tailscale', '--no-fail2ban', '--no-auto-updates'],
                            text=True, capture_output=True, env=env)
    assert result.returncode == 0, result.stderr
    for forbidden in ['apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade',
                      'openssh-server', 'sshd_config.d/', 'ufw default', 'ufw enable',
                      'install fail2ban', 'docker-ce-cli', 'install tailscale']:
        assert forbidden not in result.stdout, forbidden
    passed += 1
    # All-default wizard preview must preserve access and skip full-upgrade.
    result = subprocess.run(['bash', str(script), '--wizard', '--dry-run', '--mode', 'lan'],
                            input='\n'*7, text=True, capture_output=True, env=env)
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert 'SSH configuration:      no' in result.stdout
    assert 'Upgrade Debian:          NO' in result.stdout
    assert 'ufw enable' not in result.stdout and 'sshd_config.d/' not in result.stdout
    assert 'apt-get ' not in result.stdout
    passed += 1
    # UI language regression: stdout must stay free of Romanian UI markers.
    assert not any(ch in result.stdout for ch in 'ăâîșțĂÂÎȘȚ'), result.stdout
    for marker in ['Intrare închisă', 'Lipsește valoarea', 'REZUMAT', 'planificat',
                   'Configurație', 'Avertismente', 'Pași următori']:
        assert marker not in result.stdout, marker
    passed += 1
    # EOF never silently accepts yes/default actions.
    result = subprocess.run(['bash', str(script), '--wizard', '--dry-run', '--mode', 'lan'],
                            input='', text=True, capture_output=True, env=env)
    assert result.returncode == 2, result.returncode
    assert '[DRY-RUN]' not in result.stdout
    passed += 1

print(f'Guided setup: {passed} checks passed')
PY
