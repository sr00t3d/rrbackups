[![🇺🇸 English](https://img.shields.io/badge/lang-English-blue.svg)](README.md) [![🇧🇷 Português](https://img.shields.io/badge/lang-Português-green.svg)](README-ptbr.md) [![🇪🇸 Español](https://img.shields.io/badge/lang-Español-yellow.svg)](README-es.md)

# rrbackups

[![Version](https://img.shields.io/badge/version-2.0.0-blue.svg)](https://github.com/sr00t3d/rrbackups/releases/tag/v2.0.0)
[![License](https://img.shields.io/badge/license-Apache--2.0-green.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-4.0%2B-orange.svg)](#requisitos)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20cPanel%20%7C%20WHM-lightgrey.svg)](#requisitos)

**Orquestador Seguro de Backups, Verificación y Restauración de Resellers cPanel/WHM.**

`rrbackups.sh` descubre, deduplica y verifica archivos de respaldo cPanel (`cpmove-*.tar.gz`, `backup-*.tar.gz`), genera backups `chmod 600` con `manifest.json` SHA-256 mediante `/scripts/pkgacct`, restaura de forma segura preservando `OWNER`/`PLAN` y audita privilegios `SUPER`/`GRANT`/`FILE` en MySQL/MariaDB (`audit-mysql`).

> **Inspiración Histórica:** Reimplementación limpia en Bash + Python 3.6+ (`v2.0.0`) inspirada en `rrbackups` (2011–2012, v1.0.3, Mark Shields, HostGator.com, LLC).

---

## Ejecución Directa

```bash
curl -fsSL https://raw.githubusercontent.com/sr00t3d/rrbackups/main/rrbackups.sh -o rrbackups.sh
chmod +x rrbackups.sh
sudo ./rrbackups.sh scan --dir /backup/accounts --verify
```

---

## Licencia

Licenciado bajo [Apache License 2.0](LICENSE).
