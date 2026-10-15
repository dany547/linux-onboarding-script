# TEST-VM — verificare manuală pe VM real

> Historical Debian/Ubuntu checklist (Romanian). Since v2.7.1 the script's output
> is English; interpret older quoted messages by meaning, not exact spelling.
> Alpine has separate capabilities and validation requirements: see
> [ALPINE-VALIDATION.md](ALPINE-VALIDATION.md). Do not apply this APT/systemd
> checklist to Alpine or claim booted-VM coverage from its chroot tests.

Tot ce e aici e **[MANUAL]** — nu e acoperit de `tests/run.sh` (care rulează fără root/rețea). Fă un snapshot VM înainte de fiecare scenariu.

Pre-check pe laptop, înainte de upload:

```bash
bash -n debian-setup.sh
~/.local/bin/shellcheck -x -S warning debian-setup.sh
bash tests/run.sh          # trebuie: 187+ ok, 0 eșuate
```

Rulează pe fiecare VM: **Debian 12, Debian 13, Ubuntu 22.04, Ubuntu 24.04**, plus LXC privilegiat și neprivilegiat. Înlocuiește `IP_VM` și `LAN/24` cu valorile reale.

---

## (a) Rulare peste ssh+sudo — detecția sesiunii [MANUAL]

```bash
ssh root@IP_VM
wget -qO /root/debian-setup.sh https://exemplu.tld/debian-setup.sh   # sursa ta
sudo bash /root/debian-setup.sh --dry-run -y --mode lan --lan-cidr LAN/24
echo $?
```

Așteptat: exit `0`; în rezumat apare `SSH curent din: <IP-ul tău>`.
Debian 13 (OpenSSH ≥ 9.8): procesul e `sshd-session` — detecția trebuie să funcționeze la fel; verifică suplimentar `ps -o comm= -p $PPID` pe sesiune și că nu apare `exit 4`.

## (b) Lockout intenționat — CIDR greșit ⇒ exit 4 [MANUAL]

```bash
sudo bash /root/debian-setup.sh -y --mode lan --lan-cidr 203.0.113.0/24
echo $?    # 4
```

Așteptat: `die` cu mesajul „Sesiunea SSH curentă … nu este acoperită”, **înainte** de orice mutație UFW. Sesiunea SSH rămâne funcțională.

## (c) --allow-current-ssh [MANUAL]

```bash
sudo bash /root/debian-setup.sh -y --mode lan --lan-cidr LAN/24 --allow-current-ssh
```

Așteptat: exit `0`; în „SSH permis din” apare `<IP-tău>/32`.

## (d) VPS fără Tailscale autentificat [MANUAL]

Comportament real: din sesiune SSH publică, guard-ul anti-lockout oprește rularea.

```bash
# (d1) fără --allow-current-ssh, non-interactiv:
sudo bash /root/debian-setup.sh -y --mode vps
echo $?    # 4 — „Sesiuni SSH neacoperite de regulile propuse: <IP-ul tău> …”
# (d2) cu --allow-current-ssh:
sudo bash /root/debian-setup.sh -y --mode vps --allow-current-ssh
echo $?    # 0
```

Așteptat: (d1) exit 4, **înainte** de orice mutație UFW, sesiunea rămâne funcțională; (d2) exit 0, în „SSH permis din” apare `<IP-tău>/32`, rularea se termină cu `warn … sudo tailscale up`; după rulare SSH din internet e blocat (test din **alt terminal**), iar după `sudo tailscale up` SSH prin IP-ul Tailscale funcționează.

## (e) apt update cu repo-urile deb822 [MANUAL]

```bash
ls /etc/apt/sources.list.d/
apt-get update
apt-get -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/tailscale.sources \
        -o Dir::Etc::sourceparts=- update
apt-get -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/docker.sources \
        -o Dir::Etc::sourceparts=- update
```

Așteptat: doar `docker.sources` + `tailscale.sources` (+ `tailscale.list` absent); fără erori, fără „configured multiple times”, fără warning-uri N: despre repo-uri duplicate. (`indextargets` nu poate rula local — verificarea formatului e manuală, aici.)

## (f) Fail2Ban jail sshd activ (Debian 13, fără rsyslog) [MANUAL]

```bash
fail2ban-client status sshd
systemctl status fail2ban
```

Așteptat: `Status for the jail: sshd` cu jail-ul activ; fără erori legate de backend (`backend = systemd` în `/etc/fail2ban/jail.d/sshd-bootstrap.local`).

## (g) Originea de securitate în unattended [MANUAL]

```bash
unattended-upgrade --dry-run --debug 2>&1 | grep -E 'bookworm-security|trixie-security|jammy-security|noble-security'
```

Așteptat: linii care conțin `<codename>-security`. Dacă lipsește, scriptul emite `warn VERIFICARE UNATTENDED` (sau exit 1 cu `--strict`).

## (h) daemon.json merge + rotație loguri [MANUAL]

```bash
cat /etc/docker/daemon.json
ls /etc/docker/
docker info --format '{{.LoggingDriver}}'    # json-file
docker run --rm -d --name t1 nginx && docker inspect t1 --format '{{json .HostConfig.LogConfig}}' && docker rm -f t1
```

Așteptat: `live-restore`, `no-new-privileges`, `max-size:10m`, `max-file:3` în daemon.json; un `daemon.json.bak-<timestamp>` dacă fișierul exista înainte; la rerulare mesajul „daemon.json este deja la setările gestionate; docker nu este repornit” și `systemctl show -p ActiveEnterTimestamp docker` nemodificat.

## (i) --ssh-keys-only + login cu cheie din alt terminal [MANUAL]

```bash
# sesiunea 1 (NU o închide):
sudo bash /root/debian-setup.sh -y --config examples/vps-fleet.conf
# sesiunea 2 (de pe laptop, cu cheia privată perechea lui examples/admin_key.pub):
ssh -i /cale/la/admin_key admin@IP_VM
sudo sshd -T | grep -E 'passwordauthentication|kbdinteractiveauthentication|permitrootlogin'
```

Așteptat: login funcționează doar pe cheie; `passwordauthentication no`, `kbdinteractiveauthentication no`, `permitrootlogin prohibit-password`; `/etc/ssh/sshd_config.d/00-bootstrap-security.conf` prezent.

## (j) Rerulare idempotentă [MANUAL]

```bash
sudo bash /root/debian-setup.sh -y --config examples/vps-fleet.conf --skip-upgrade
```

Așteptat: exit `0`; fără `full-upgrade`; „daemon.json este deja la setările gestionate”; `grep -c ssh- /home/admin/.ssh/authorized_keys` nemodificat (fără duplicate); `grep '^IPV6=yes' /etc/default/ufw` rămâne; nimic nou în `/var/backups/ufw-*` (fără `--reset-firewall`).

## (k) Rollback-uri [MANUAL]

- sshd: adaugă o linie eronată în `/etc/ssh/sshd_config.d/90-bootstrap-security.conf`, apoi rerulare → `sshd -t` eșuează → fișierul e restaurat automat, exit 1.
- daemon.json: scrie `{{invalid` în fișier, rerulare → `warn … JSON invalid`, fișierul rămâne neatins, bootstrap continuă.
- Tailscale key: înlocuiește keyring-ul cu un fișier ne-PGP și rerulare → `die 1`, keyring-ul șters.

---

Reamintire: rezultatele de aici nu se declară „verificate” doar pe baza `--dry-run`; secțiunea marchează explicit totul ca [MANUAL].
