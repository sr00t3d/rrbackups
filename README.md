[![🇺🇸 English](https://img.shields.io/badge/lang-English-blue.svg)](README.md) [![🇧🇷 Português](https://img.shields.io/badge/lang-Português-green.svg)](README-ptbr.md) [![🇪🇸 Español](https://img.shields.io/badge/lang-Español-yellow.svg)](README-es.md)

# rrbackups

[![Version](https://img.shields.io/badge/version-2.0.0-blue.svg)](https://github.com/sr00t3d/rrbackups/releases/tag/v2.0.0)
[![License](https://img.shields.io/badge/license-Apache--2.0-green.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-4.0%2B-orange.svg)](#requirements)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20cPanel%20%7C%20WHM-lightgrey.svg)](#requirements)

**Safe cPanel Reseller Backup, Archive Verification & Restore Orchestrator CLI.**

`rrbackups.sh` discovers, deduplicates, and verifies cPanel backup archives (`cpmove-*.tar.gz`, `backup-*.tar.gz`) in read-only `scan` mode, creates `chmod 600` reseller/account backups with SHA-256 `manifest.json` via `/scripts/pkgacct`, safely orchestrates restores with pre-flight archive integrity checks and `OWNER`/`PLAN` preservation, and audits MySQL/MariaDB for non-system `SUPER`/`GRANT`/`FILE` privileges (`audit-mysql`).

> **Historical Inspiration:** Clean-room Bash + Python 3.6+ `v2.0.0` reimplementation inspired by `rrbackups` (2011–2012, v1.0.3, Mark Shields, HostGator.com, LLC). Eliminates an unencrypted HTTP RCE download (`git.hgfix.net/chgacctip`), an infinite loop in `mysqlsucheck`, undefined subroutine typos, 8-character username truncation, hardcoded HostGator scripts (`/root/bin/ui`, `/home/hgtransfer`), and unsafe shell interpolation.

---

## Requirements

- Linux server running cPanel/WHM with Bash 4.0+ and Python 3.6+ (standard library only)
- Root privileges required for `/scripts/pkgacct`, `/scripts/restorepkg`, `whmapi1`, and `/var/cpanel/users/`

---

## Direct Execution

```bash
curl -fsSL https://raw.githubusercontent.com/sr00t3d/rrbackups/main/rrbackups.sh -o rrbackups.sh
chmod +x rrbackups.sh
sudo ./rrbackups.sh scan --dir /backup/2026-11-22/accounts --verify
```

---

## Usage

```bash
# 1. Scan & verify cPanel backup archives in a directory or reseller homedir (read-only)
sudo ./rrbackups.sh scan --dir /var/backups/rrbackups/20261122 --verify
sudo ./rrbackups.sh scan myreseller -o json

# 2. Backup a single account or all accounts owned by a reseller (with SHA-256 manifest)
sudo ./rrbackups.sh backup --user percio --dest /var/backups/rrbackups
sudo ./rrbackups.sh backup myreseller --dry-run

# 3. Preview or execute a safe restore (pre-flight tar/cp/ integrity check + OWNER/PLAN preservation)
sudo ./rrbackups.sh restore /var/backups/rrbackups/20261122/cpmove-percio.tar.gz --dry-run

# 4. Audit MySQL/MariaDB for rogue non-system SUPER/GRANT/FILE users
sudo ./rrbackups.sh audit-mysql --exit-code
```

---

## License

Licensed under the [Apache License 2.0](LICENSE).
