# Linux Onboarding Script

Bootstrap simplu pentru servere Debian 12/13, orientat către Docker, Docker Compose, firewall și acces SSH privat prin VPN.

## Ce face

Scriptul:

- actualizează Debian prin `apt full-upgrade`;
- instalează Docker Engine, Buildx și Docker Compose plugin din repository-ul oficial Docker;
- instalează Tailscale din repository-ul oficial stable;
- instalează și configurează UFW;
- configurează Fail2Ban pentru SSH;
- activează actualizări automate limitate la Debian Security;
- aplică un baseline SSH minimal:
  - dezactivează parolele goale;
  - dezactivează X11 forwarding;
  - limitează încercările de autentificare;
- permite SSH doar din rețelele configurate: LAN, WireGuard și Tailscale;
- verifică Docker, Compose, Tailscale, UFW, Fail2Ban și porturile ascultate.

Docker și Tailscale sunt instalate de pe canalele lor oficiale `stable`, astfel încât instalările ulterioare folosesc cele mai recente versiuni stabile disponibile pentru Debian.

## Ce nu face

- nu deschide porturile 80 sau 443;
- nu deschide portul 22 global către Internet;
- nu configurează Cloudflare Tunnel;
- nu creează utilizatori Linux;
- nu configurează WG-Easy sau WireGuard;
- nu publică porturi Docker automat;
- nu modifică `machine-id`, timezone-ul sau SSH host keys.

Cloudflare Tunnel poate fi instalat ulterior prin Docker Compose. Pentru această arhitectură, aplicațiile expuse prin Cloudflare nu ar trebui să folosească `ports:`; `cloudflared` și aplicația pot comunica printr-o rețea Docker comună.

## Utilizare

Copiază scriptul pe server și rulează-l ca root sau prin `sudo`.

### Server în LAN

```bash
sudo bash debian-setup.sh \
  --mode lan \
  --lan-cidr 192.168.1.0/24 \
  --wireguard-cidr 10.8.0.0/24 \
  --reset-firewall
```

În modul LAN, SSH este permis din:

- subnetul LAN;
- subnetul WireGuard configurat;
- subnetul Tailscale `100.64.0.0/10`.

### VPS

```bash
sudo bash debian-setup.sh \
  -y \
  --mode vps \
  --wireguard-cidr 10.8.0.0/24 \
  --reset-firewall
```

În modul VPS, portul 22 public nu este deschis. Accesul SSH se face prin WireGuard și/sau Tailscale.

Dacă Tailscale este singura cale de administrare, autentifică-l după instalare:

```bash
sudo tailscale up
```

## CIDR-uri

CIDR-ul LAN este subnetul rețelei locale, de exemplu:

```text
192.168.1.0/24
```

Poate fi identificat cu:

```bash
ip -4 route
```

Pentru `--wireguard-cidr`, folosește subnetul WireGuard văzut de serverul țintă. Dacă WG-Easy face NAT, serverul poate vedea IP-ul mașinii WG-Easy, nu IP-ul clientului WireGuard. În acest caz, folosește IP-ul sau subnetul observat efectiv pe server.

## Opțiuni

```text
-y, --yes                  Mod non-interactiv; necesită --mode
--mode lan|vps             Alege politica de rețea
--lan-cidr CIDR            Subnet LAN permis pentru SSH
--wireguard-cidr CIDR      Sursă/subnet WireGuard permis pentru SSH
--no-docker                Nu instala Docker și Compose
--no-tailscale             Nu instala Tailscale
--no-fail2ban              Nu instala Fail2Ban
--no-auto-updates          Nu activa actualizările automate de securitate
--reset-firewall           Resetează regulile UFW existente
--allow-current-ssh        Permite explicit IP-ul sesiunii SSH curente
--skip-upgrade             Nu executa apt full-upgrade
-h, --help                 Afișează ajutorul
```

`--reset-firewall` șterge regulile UFW existente. Folosește-l doar pe servere pregătite pentru bootstrap sau după ce ai verificat configurația actuală.

## Actualizări automate

Implicit, scriptul activează `unattended-upgrades` pentru actualizări automate de securitate Debian. Nu activează reboot automat.

Pachetele Docker și Tailscale sunt instalate din repository-urile lor stable, dar nu sunt actualizate automat de regula de securitate Debian. Aceste actualizări pot schimba versiuni de runtime sau pot reporni servicii, deci se fac controlat printr-o rulare ulterioară a bootstrap-ului sau prin politica proprie de mentenanță.

Pentru a dezactiva funcția:

```bash
sudo bash debian-setup.sh --mode lan --no-auto-updates
```

## LXC

Într-un LXC neprivilegiat, scriptul instalează pachetele, dar nu activează UFW și Fail2Ban în guest. Firewall-ul trebuie configurat pe hostul Proxmox sau la nivelul infrastructurii.

Pentru Docker în LXC pot fi necesare opțiuni precum:

- `nesting=1`;
- `keyctl=1`;
- `fuse=1`, în funcție de configurație.

## Verificare după instalare

```bash
docker --version
docker compose version
sudo tailscale status
sudo ufw status verbose
sudo fail2ban-client status sshd
ss -lntup
```

## Licență

Publicat pentru utilizare personală și operațională. Adaptează și verifică regulile de firewall înainte de folosirea pe sisteme existente.
