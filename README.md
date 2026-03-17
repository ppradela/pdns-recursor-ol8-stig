# PowerDNS Recursor 4.8.9 — DISA STIG Hardened Deployment

> **A complete, production-tested DISA STIG hardening guide for PowerDNS Recursor on Oracle Linux 8. No comparable guide exists — built from real deployment and iterative troubleshooting.**

![PowerDNS](https://img.shields.io/badge/PowerDNS_Recursor-4.8.9-blue)
![OL8](https://img.shields.io/badge/Oracle_Linux-8-red)
![STIG](https://img.shields.io/badge/DISA_STIG-DNS_V2R4-green)
![License](https://img.shields.io/badge/license-MIT-blue)

> **Air-gapped / disconnected network?** See [README-airgapped.md](README-airgapped.md).

---

## Features

- **Pure recursive resolution** — walks the DNS tree from root servers; no forwarders, no external dependencies
- **DNSSEC full validation** — bogus responses return SERVFAIL; trust anchors set via Lua, not the broken INI key
- **Operator-controlled root hints** — custom `named.root` downloaded and PGP-verified from IANA
- **DISA STIG DNS V2R4 compliance** — all applicable controls satisfied and mapped
- **systemd hardening drop-in** — capabilities tightened, core dumps disabled, syscall filter extended; OL8/systemd-239 compatible
- **Verbose audit logging** — `local3` syslog facility, forwarded to SIEM via rsyslog
- **Documented pitfalls** — every non-obvious OL8/4.8.x failure mode explained and solved

---

## Architecture

```
Client (internal network)
        │  UDP/TCP 53
        ▼
PowerDNS Recursor 4.8.9
  ├── recursor.conf       — main daemon config (access control, DNSSEC, logging)
  ├── recursor.lua        — Lua config (DNSSEC trust anchors via addTA())
  ├── named.root          — operator-managed root hints (IANA, PGP-verified)
  └── hardening.conf      — systemd drop-in (capabilities, syscall filter)
        │  UDP/TCP 53 (outbound from query-local-address)
        ▼
Internet root / TLD / authoritative servers
        │
        ▼
rsyslog (facility local3)
        │  UDP 514 (dev/lab) or TLS 6514 (production/CUI)
        ▼
SIEM
```

---

## File Structure

```
repository/
├── recursor.conf                  # Main daemon configuration
├── recursor.lua                   # Lua config — DNSSEC trust anchors
├── named.root                     # Root hints (reference copy — always re-download)
├── pdns-recursor-hardening.conf   # systemd hardening drop-in
└── README.md                      # This guide (internet-connected deployment)
└── README-airgapped.md            # Air-gapped deployment variant
```

| File | Install path |
|------|-------------|
| `recursor.conf` | `/etc/pdns-recursor/recursor.conf` |
| `recursor.lua` | `/etc/pdns-recursor/recursor.lua` |
| `named.root` | `/etc/pdns-recursor/named.root` |
| `pdns-recursor-hardening.conf` | `/etc/systemd/system/pdns-recursor.service.d/hardening.conf` |

---

## Prerequisites

### Oracle Linux 8 baseline

Oracle Linux 8 is assumed to be **DISA STIG hardened at install time** using the STIG profile available in the OL8 installer. No additional OS hardening steps are required here.

- `rsyslog` installed and running
- Outbound access to `yum.oracle.com` and `www.internic.net` during installation

### Install PowerDNS Recursor from EPEL

```bash
# Enable the Oracle Linux 8 EPEL repository (if not already enabled)
dnf install oracle-epel-release-el8

# Install PowerDNS Recursor
dnf install pdns-recursor
```

### Verify the service account

The stock package creates `pdns-recursor`; confirm it is locked:

```bash
id pdns-recursor || useradd -r -s /sbin/nologin -d /var/empty pdns-recursor
passwd -l pdns-recursor
```

---

## Deployment

### Step 1 — Create the configuration directory

```bash
install -d -o root -g root -m 0755 /etc/pdns-recursor
```

### Step 2 — Install recursor.conf

```bash
install -o root -g pdns-recursor -m 0640 \
  recursor.conf /etc/pdns-recursor/recursor.conf
```

Edit the three site-specific values before starting the service:

| Setting | What to set |
|---------|-------------|
| `local-address` | IP address(es) this resolver listens on — never `0.0.0.0` in production |
| `allow-from` | All client subnets permitted to use this resolver |
| `query-local-address` | Outbound source IP for all recursive queries |

### Step 3 — Install recursor.lua

```bash
install -o root -g root -m 0440 \
  recursor.lua /etc/pdns-recursor/recursor.lua
```

The file ships with both **KSK-2017** (key tag 20326) and **KSK-2024** (key tag 38696) active. Both anchors are required simultaneously during the ongoing rollover. Monitor <https://www.iana.org/dnssec/files> for KSK-2017 retirement announcements and remove it once retired.

### Step 4 — Download and install named.root

Always fetch a fresh copy and verify the PGP signature. Do not use the copy from this repository as-is in production — it may be stale.

```bash
cd /tmp
curl -O https://www.internic.net/domain/named.root
curl -O https://www.internic.net/domain/named.root.sig
gpg --verify named.root.sig named.root     # must show: Good signature

install -o root -g root -m 0444 \
  /tmp/named.root /etc/pdns-recursor/named.root
```

### Step 5 — Install the systemd hardening drop-in

```bash
install -d -o root -g root -m 0755 \
  /etc/systemd/system/pdns-recursor.service.d

install -o root -g root -m 0644 \
  pdns-recursor-hardening.conf \
  /etc/systemd/system/pdns-recursor.service.d/hardening.conf

systemctl daemon-reload
```

### Step 6 — Configure rsyslog forwarding to SIEM

Create `/etc/rsyslog.d/pdns-recursor.conf`:

```
# Plain UDP — development / lab only
local3.*   @siem.example.mil:514

# TLS — required for classified / CUI networks
# local3.*   @@(o)siem.example.mil:6514
```

```bash
systemctl restart rsyslog
```

### Step 7 — Enable and start

```bash
systemctl enable --now pdns-recursor
systemctl status pdns-recursor
```

---

## Smoke Tests

Run these immediately after first start and after every configuration change.

```bash
# 1. Basic resolution
dig @127.0.0.1 www.example.com A +short

# 2. DNSSEC validated — response must carry the AD flag
dig @127.0.0.1 +dnssec sigok.verteiltesysteme.net A | grep -E 'flags|status'

# 3. DNSSEC bogus — must return SERVFAIL
dig @127.0.0.1 sigfail.verteiltesysteme.net A | grep status

# 4. Confirm trust anchors loaded (both KSK-2017 and KSK-2024)
journalctl -u pdns-recursor --no-pager | grep 'KSK-2017.*KSK-2024'

# 5. Confirm DNSSEC bogus logging is active
journalctl -u pdns-recursor --no-pager | grep -i bogus
```

Expected results: test 1 returns an IP, test 2 shows `flags: ... ad`, test 3 shows `SERVFAIL`, tests 4–5 show journal entries.

---

## Maintenance Schedule

| Task | Frequency |
|------|-----------|
| Download and PGP-verify fresh `named.root` from IANA | Quarterly |
| Check IANA root KSK page for rollover announcements | Quarterly |
| Review `allow-from` against current network topology | On every network change |
| Run smoke tests (especially SERVFAIL for bogus domain) | Monthly |
| Check for updated `pdns-recursor` packages in EPEL | Monthly |

---

## Key Lessons — What NOT to Do on OL8

These issues were discovered through real deployment and are documented here to prevent recurrence.

### recursor.conf — directives that do not exist in 4.8.x

All of these produce `Fatal error: Trying to set unknown setting`:

| Bad directive | Correct approach |
|---------------|-----------------|
| `trust-anchor=` | Use `addTA()` in `recursor.lua` |
| `edns-do-bit-in-outgoing=` | Set automatically by `dnssec=validate` |
| `min-ttl=` | Does not exist in 4.8.x |
| `throttle-netmask=` | Does not exist in 4.8.x |
| `max-nxdomain-per-second=` | Does not exist in 4.8.x |
| `max-nxdomain-per-second-action=` | Does not exist in 4.8.x |
| `serve-stale-extensions=` | Added in 4.9.0 |
| `max-delegation-depth=` | Does not exist in 4.8.x |
| `socket-dir=` | Conflicts with `--socket-dir` already on the ExecStart command line |

### hardening.conf — systemd drop-in rules for OL8 (systemd 239)

**`Failed at step NAMESPACE: No such file or directory`** is thrown when any path in `ReadWritePaths=` or `ReadOnlyPaths=` does not exist when the mount namespace is assembled. The error never names the offending path.

1. **Never use `ReadWritePaths=` for `/run/...` paths.** Use `RuntimeDirectory=` instead — but only if the stock unit does not already set it; list-type keys accumulate. The stock unit already sets `RuntimeDirectory=pdns-recursor`.

2. **Never use `ReadOnlyPaths=` for any path that may not exist at start time.** `ProtectSystem=full` (already set by the stock unit) makes `/etc` read-only inside the namespace — adding a redundant `ReadOnlyPaths=/etc/pdns-recursor` causes a NAMESPACE error if the directory is absent.

3. **Never set `ProtectSystem=strict` on OL8.** Under systemd 239 with SELinux enforcing, `strict` prevents the kernel from exec'ing binaries under `/usr/sbin/`. The stock unit's `ProtectSystem=full` is the safe maximum.

4. **List-type keys accumulate across drop-ins.** To replace a list-type key (`CapabilityBoundingSet=`, `SystemCallFilter=`, `RuntimeDirectory=`, etc.), issue an empty assignment first to clear the inherited value, then set the new value.

5. **Check systemd version before using new directives.** OL8 ships systemd 239. The following are silently ignored or cause parse failures: `ProtectHostname=` (240+), `ProtectClock=` (245+), `RestrictSUIDSGID=` (245+), `ProtectKernelLogs=` (253+).

---

## License

MIT — free to use, modify, and distribute.

---

## Author

**Przemysław Pradela**

Built through real production deployment and iterative troubleshooting on Oracle Linux 8.

[![GitHub](https://img.shields.io/badge/GitHub-ppradela-181717?logo=github)](https://github.com/ppradela)
[![LinkedIn](https://img.shields.io/badge/LinkedIn-Przemysław%20Pradela-0A66C2?logo=linkedin)](https://www.linkedin.com/in/przemyslaw-pradela)
[![Website](https://img.shields.io/badge/Website-pradela.ovh-4A90D9)](https://pradela.ovh)

Contributions and issue reports welcome.
