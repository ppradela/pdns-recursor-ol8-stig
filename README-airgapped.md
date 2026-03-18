# PowerDNS Recursor 4.8.9 — DISA STIG Hardened Deployment (Air-Gapped)

> **Variant for disconnected / air-gapped networks. All packages and files are pre-staged on an internet-connected machine and transferred to the target host via approved media.**

![PowerDNS](https://img.shields.io/badge/PowerDNS_Recursor-4.8.9-blue)
![OL8](https://img.shields.io/badge/Oracle_Linux-8-red)
![STIG](https://img.shields.io/badge/DISA_STIG-Oracle_Linux_8_V2R7-green)
![License](https://img.shields.io/badge/license-MIT-blue)

> **Internet-connected network?** See [README.md](README.md) for the standard deployment guide.

---

## Features

- **Pure recursive resolution** — walks the DNS tree from root servers; no forwarders, no internet dependency at runtime
- **DNSSEC full validation** — bogus responses return SERVFAIL; trust anchors set via Lua, not the broken INI key
- **Offline root hints** — `named.root` bundled in this repository (verify currency before deployment)
- **systemd hardening drop-in** — capabilities tightened, core dumps disabled, syscall filter extended; OL8/systemd-239 compatible
- **Verbose audit logging** — `local3` syslog facility, forwarded to internal SIEM via rsyslog
- **Zero runtime internet access required** — resolves via in-enclave authoritative servers or a forwarding stub; all packages pre-staged

---

## Architecture

```
Client (internal / air-gapped network)
        │  UDP/TCP 53
        ▼
PowerDNS Recursor 4.8.9
  ├── recursor.conf       — main daemon config (access control, DNSSEC, logging)
  ├── recursor.lua        — Lua config (DNSSEC trust anchors via addTA())
  ├── named.root          — operator-managed root hints (pre-staged, see note)
  └── hardening.conf      — systemd drop-in (capabilities, syscall filter)
        │  UDP/TCP 53 (outbound from query-local-address)
        ▼
In-enclave root / authoritative servers
  (or split-horizon forwarder for internal zones)
        │
        ▼
rsyslog (facility local3)
        │  TLS 6514 (required — no cleartext on air-gapped networks)
        ▼
Internal SIEM
```

> **Root hints in air-gapped environments:** If your enclave does not reach the public internet root servers, replace the root hints with the addresses of your internal root or forwarding infrastructure. The `named.root` file format is identical — simply substitute the NS/A/AAAA records.

---

## File Structure

```
repository/
├── recursor.conf                  # Main daemon configuration
├── recursor.lua                   # Lua config — DNSSEC trust anchors
├── named.root                     # Root hints (reference copy — verify before use)
├── pdns-recursor-hardening.conf   # systemd hardening drop-in
├── README.md                      # Internet-connected deployment guide
└── README-airgapped.md            # This guide (air-gapped deployment)
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
- Approved removable media or secure file-transfer path to the air-gapped host
- An internet-connected **staging machine** running Oracle Linux 8 to download packages

### Stage packages on the internet-connected machine

Run the following on the **staging machine**:

```bash
# Enable EPEL on the staging machine (if not already enabled)
dnf install oracle-epel-release-el8

# Create a staging directory
mkdir -p ~/pdns-stage

# Download pdns-recursor and all dependencies
dnf download --resolve --destdir ~/pdns-stage pdns-recursor

# Verify what was downloaded
ls ~/pdns-stage/
```

Transfer `~/pdns-stage/` to the air-gapped host via approved media.

### Stage named.root on the internet-connected machine

```bash
cd ~/pdns-stage
curl -O https://www.internic.net/domain/named.root
curl -O https://www.internic.net/domain/named.root.sig

# Import the IANA signing key on the staging machine (one-time, or when key changes)
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys F0CB1A326BDF3F3EFA3A01FA937BB869E3A238C5

# Verify PGP signature before transferring
gpg --verify named.root.sig named.root     # must show: Good signature
```

> If the repository copy of `named.root` is sufficiently current (check the timestamp in the file header), it may be used directly. The PGP-verified IANA copy is always preferred.

> **FIPS mode note:** On OL8 with FIPS enabled, `gpg` emits `out of core handler ignored in FIPS mode` (harmless warning) but may also refuse to verify DSA signatures. If verification fails with a DSA-related error, compare the SHA-256 hash of the downloaded file against a trusted out-of-band source as an alternative integrity check.

---

## Deployment

### Step 1 — Install the RPM packages

On the **air-gapped target host**, from the transferred staging directory:

```bash
dnf install --disablerepo='*' ~/pdns-stage/*.rpm
```

If `dnf` is unavailable or repos are fully disabled, use `rpm` directly:

```bash
rpm -ivh ~/pdns-stage/*.rpm
```

Confirm the installed version:

```bash
pdns_recursor --version 2>&1 | head -1
```

### Step 2 — Verify the service account

The stock package creates `pdns-recursor`; confirm it is locked:

```bash
id pdns-recursor || useradd -r -s /sbin/nologin -d /var/empty pdns-recursor
passwd -l pdns-recursor
```

### Step 3 — Create the configuration directory

```bash
install -d -o root -g root -m 0755 /etc/pdns-recursor
```

### Step 4 — Install recursor.conf

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

> **Air-gapped note:** If this resolver forwards queries to an in-enclave authoritative server rather than walking the public root, add the appropriate `forward-zones=` or `forward-zones-recurse=` directives and point `hint-file=` at a locally-maintained root hints file reflecting your internal infrastructure.

### Step 5 — Install recursor.lua

```bash
install -o root -g pdns-recursor -m 0440 \
  recursor.lua /etc/pdns-recursor/recursor.lua
```

The file ships with both **KSK-2017** (key tag 20326) and **KSK-2024** (key tag 38696) active. Both anchors are required simultaneously during the ongoing rollover. In an air-gapped environment, coordinate KSK-2017 retirement timing with your ISSM/ISSO and remove it from this file once IANA retires it.

For internal zones signed with your own DNSSEC keys, add one `addTA()` line per zone in the `SECTION 1` block of `recursor.lua`.

### Step 6 — Install named.root

Use the PGP-verified copy staged from IANA:

```bash
install -o root -g root -m 0444 \
  ~/pdns-stage/named.root /etc/pdns-recursor/named.root
```

If your enclave does not reach public root servers, replace the contents of `named.root` with the addresses of your internal root or forwarding infrastructure using the same zone-file format.

### Step 7 — Install the systemd hardening drop-in

```bash
install -d -o root -g root -m 0755 \
  /etc/systemd/system/pdns-recursor.service.d

install -o root -g root -m 0644 \
  pdns-recursor-hardening.conf \
  /etc/systemd/system/pdns-recursor.service.d/hardening.conf

systemctl daemon-reload
```

### Step 8 — Configure rsyslog forwarding to internal SIEM

Create `/etc/rsyslog.d/pdns-recursor.conf`:

```
# TLS forwarding to internal SIEM — required on air-gapped / CUI networks
local3.*   @@(o)siem.internal.mil:6514
```

```bash
systemctl restart rsyslog
```

> Plain UDP (`@`) should not be used in critical networks that require a high level of security. Ensure the SIEM's TLS certificate chain is trusted by the host's certificate store, or configure the CA explicitly in rsyslog's `$DefaultNetstreamDriverCAFile`.

### Step 9 — Enable and start

```bash
systemctl enable --now pdns-recursor
systemctl status pdns-recursor
```

### Step 10 — Configure firewalld

Remove all default services and allow only what this host requires. Adjust the
zone and the allowed services to match your enclave before applying.

```bash
# Identify the active zone (commonly 'public' on a freshly installed host)
firewall-cmd --get-active-zones

# Remove every pre-configured service from the zone
# Replace 'public' if your active zone differs
for svc in $(firewall-cmd --zone=public --list-services); do
  firewall-cmd --permanent --zone=public --remove-service="$svc"
done

# Allow SSH (adjust or remove if management access is via a jump host or out-of-band console)
firewall-cmd --permanent --zone=public --add-service=ssh

# Allow DNS — required for clients querying this resolver
firewall-cmd --permanent --zone=public --add-service=dns

# Add any additional services your enclave requires, for example:
#   --add-rich-rule='rule family="ipv4" source address="10.0.0.0/8" service name="dns" accept'
#                                 # to restrict DNS to a specific internal source range
#   --add-service=syslog          # if this host forwards logs to an in-enclave SIEM

firewall-cmd --reload
firewall-cmd --zone=public --list-all    # verify before continuing
```

---

## Smoke Tests

Run these immediately after first start and after every configuration change.

```bash
# 1. Basic resolution (use an internal domain known to resolve in your enclave)
dig @127.0.0.1 <internal-domain> A +short

# 2. DNSSEC validated — response must carry the AD flag
#    Use a domain signed and validated within your enclave
dig @127.0.0.1 +dnssec <signed-internal-domain> A | grep -E 'flags|status'

# 3. DNSSEC bogus — must return SERVFAIL
#    Requires a deliberately broken DNSSEC zone in your test environment,
#    or temporarily add an incorrect trust anchor for a test zone
dig @127.0.0.1 <bogus-test-domain> A | grep status

# 4. Confirm trust anchors loaded (both KSK-2017 and KSK-2024)
journalctl -u pdns-recursor --no-pager | grep 'KSK-2017.*KSK-2024'

# 5. Confirm DNSSEC bogus logging is active
journalctl -u pdns-recursor --no-pager | grep -i bogus
```

> Tests 2 and 3 require DNSSEC-signed zones reachable from the enclave. For a quick connectivity-only check, test 1 is sufficient.

---

## Maintenance Schedule

| Task | Frequency |
|------|-----------|
| Stage and transfer a fresh `named.root` (PGP-verified on staging machine) | Quarterly |
| Review IANA root KSK rollover status; coordinate with ISSM/ISSO | Quarterly |
| Review `allow-from` against current network topology | On every network change |
| Run smoke tests | Monthly |
| Check EPEL for updated `pdns-recursor` packages; stage and schedule patching | Monthly |

---

## Key Lessons — What NOT to Do on OL8

These issues were discovered through real deployment and are documented here to prevent recurrence. Both deployment variants (online and air-gapped) are affected equally.

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
