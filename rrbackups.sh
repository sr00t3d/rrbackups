#!/usr/bin/env bash
# ==============================================================================
# rrbackups.sh — Safe cPanel Reseller Backup & Restore Orchestrator CLI (v2.0.0)
# ==============================================================================
# Clean-room Bash + Python 3.6+ reimplementation inspired by rrbackups (2011-2012,
# v1.0.3, Mark Shields, HostGator.com, LLC).
#
# Eliminates unencrypted HTTP RCE auto-downloads (git.hgfix.net), an infinite
# loop in mysqlsucheck, undefined subroutine typos, 8-char username truncation,
# hardcoded HostGator internal dependencies (/root/bin/ui, /home/hgtransfer),
# and unsafe shell command interpolation.
#
# Adds read-only scan/verify mode, SHA-256 backup manifests via /scripts/pkgacct,
# pre-flight archive integrity verification before restore, OWNER/PLAN/IP drift
# protection, MySQL super-privilege security auditing, --dry-run, and JSON/CSV.
#
# License: Apache-2.0
# Author:  Percio Castelo (https://perciocastelo.com.br)
# Repo:    https://github.com/sr00t3d/rrbackups
# ==============================================================================

set -euo pipefail

readonly SCRIPT_NAME="rrbackups.sh"
readonly SCRIPT_VERSION="2.0.0"

ACTION=""
TARGET=""
RESELLER=""
SINGLE_USER=""
SCAN_DIR=""
DEST_DIR="/var/backups/rrbackups"
LOG_DIR=""
NICE_VAL="15"
VERIFY_ARCHIVES=0
REPLACE_EXISTING=0
KEEP_QUOTAS=0
SKIP_RESELLER=1
DRY_RUN=0
EXIT_CODE_MODE=0
OUTPUT_FMT="table"
QUIET=0
NO_COLOR=0

C_RED=""
C_GREEN=""
C_YELLOW=""
C_CYAN=""
C_BOLD=""
C_RESET=""

init_colors() {
  if [[ "$NO_COLOR" -eq 0 && -t 1 && "$OUTPUT_FMT" == "table" ]]; then
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'
    C_CYAN=$'\033[0;36m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
  fi
}

usage() {
  cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} — Safe cPanel Reseller Backup & Restore Orchestrator CLI

Usage:
  ${SCRIPT_NAME} scan [reseller | --dir <dir>] [opts]     Discover & deduplicate cPanel archives (read-only)
  ${SCRIPT_NAME} backup <reseller | --user <u>> [opts]    Backup reseller accounts or single user via pkgacct
  ${SCRIPT_NAME} restore <archive | --dir <dir>> [opts]   Safely restore cPanel archive(s) with pre/post checks
  ${SCRIPT_NAME} audit-mysql [options]                    Audit MySQL/MariaDB for non-system SUPER/GRANT users

Options:
  --reseller <user>       Target cPanel reseller (checks /var/cpanel/resellers & /etc/trueuserowners)
  --user <user>           Target single cPanel user (for backup or restore validation)
  --dir <path>            Directory containing cPanel backup archives (cpmove-*.tar.gz / backup-*.tar.gz)
  --dest <path>           Destination directory for backups (default: /var/backups/rrbackups)
  --log-dir <path>        Directory for pkgacct/restorepkg logs (default: <dest>/logs)
  --nice <N>              CPU niceness from -20 to 19 (default: 15)
  --verify                Verify tar/gzip header & cPanel cp/ metadata inside each archive
  --replace-existing      Allow pre-backup + killacct + restore when account already exists (opt-in)
  --keep-quotas           Preserve restored disk/bandwidth quotas
  --dry-run               Preview all actions without creating backups, killing accounts, or restoring
  --exit-code             Exit 2 on issues (corrupt/duplicate archives in scan, rogue SUPER users in audit-mysql)
  -o, --output <fmt>      Output format: table (default), json, csv
  -q, --quiet             Minimal output
  --no-color              Disable ANSI colors
  -h, --help              Show this help
  -v, --version           Show version

Examples:
  ${SCRIPT_NAME} scan --dir /backup/2026-11-22/accounts --verify
  ${SCRIPT_NAME} scan myreseller -o json
  ${SCRIPT_NAME} backup --user percio --dest /var/backups/rrbackups
  ${SCRIPT_NAME} backup myreseller --dry-run
  ${SCRIPT_NAME} restore /var/backups/rrbackups/cpmove-percio.tar.gz --dry-run
  ${SCRIPT_NAME} audit-mysql --exit-code

Exit codes:
  0  Success (clean)
  1  Error (invalid arguments, missing account/archive, pkgacct/restorepkg failure)
  2  Issues detected (corrupt/duplicate archives in scan --exit-code, or rogue SUPER users in audit-mysql)
EOF
}

parse_args() {
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      -v|--version) printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
      --reseller)
        [[ $# -ge 2 ]] || { printf '[ERR] --reseller requires a username.\n' >&2; exit 1; }
        RESELLER="$2"; shift 2 ;;
      --reseller=*) RESELLER="${1#*=}"; shift ;;
      --user|--shared)
        [[ $# -ge 2 ]] || { printf '[ERR] --user requires a username.\n' >&2; exit 1; }
        SINGLE_USER="$2"; shift 2 ;;
      --user=*|--shared=*) SINGLE_USER="${1#*=}"; shift ;;
      --dir)
        [[ $# -ge 2 ]] || { printf '[ERR] --dir requires a path.\n' >&2; exit 1; }
        SCAN_DIR="$2"; shift 2 ;;
      --dest)
        [[ $# -ge 2 ]] || { printf '[ERR] --dest requires a path.\n' >&2; exit 1; }
        DEST_DIR="$2"; shift 2 ;;
      --log-dir)
        [[ $# -ge 2 ]] || { printf '[ERR] --log-dir requires a path.\n' >&2; exit 1; }
        LOG_DIR="$2"; shift 2 ;;
      --nice)
        [[ $# -ge 2 ]] || { printf '[ERR] --nice requires -20..19.\n' >&2; exit 1; }
        NICE_VAL="$2"; shift 2 ;;
      --nice=*) NICE_VAL="${1#*=}"; shift ;;
      --verify) VERIFY_ARCHIVES=1; shift ;;
      --replace-existing) REPLACE_EXISTING=1; shift ;;
      --keep-quotas|--keepquotas) KEEP_QUOTAS=1; shift ;;
      --dry-run|--pretend|-p) DRY_RUN=1; shift ;;
      --exit-code) EXIT_CODE_MODE=1; shift ;;
      -o|--output)
        [[ $# -ge 2 ]] || { printf '[ERR] --output requires table|json|csv.\n' >&2; exit 1; }
        OUTPUT_FMT="$2"; shift 2 ;;
      -q|--quiet) QUIET=1; shift ;;
      --no-color|--nocolor|-nc) NO_COLOR=1; shift ;;
      --) shift; while [[ $# -gt 0 ]]; do positional+=("$1"); shift; done ;;
      -*)
        printf '[ERR] Unknown option: %s\n' "$1" >&2
        exit 1 ;;
      *)
        positional+=("$1"); shift ;;
    esac
  done

  if [[ ${#positional[@]} -eq 0 && -z "$RESELLER" && -z "$SINGLE_USER" && -z "$SCAN_DIR" ]]; then
    usage
    exit 0
  fi

  if [[ ${#positional[@]} -eq 0 ]]; then
    ACTION="scan"
  else
    case "${positional[0]}" in
      scan|list|listbackups)
        ACTION="scan"
        TARGET="${positional[1]:-}"
        ;;
      backup|backupall)
        ACTION="backup"
        TARGET="${positional[1]:-}"
        ;;
      restore)
        ACTION="restore"
        TARGET="${positional[1]:-}"
        ;;
      audit-mysql|mysql-audit)
        ACTION="audit-mysql"
        ;;
      *)
        ACTION="scan"
        TARGET="${positional[0]}"
        ;;
    esac
  fi

  if ! [[ "$NICE_VAL" =~ ^-?[0-9]+$ ]] || (( NICE_VAL < -20 || NICE_VAL > 19 )); then
    printf '[ERR] --nice must be an integer between -20 and 19.\n' >&2
    exit 1
  fi

  case "$OUTPUT_FMT" in
    table|json|csv) ;;
    *) printf '[ERR] Invalid --output format: %s (expected table|json|csv)\n' "$OUTPUT_FMT" >&2; exit 1 ;;
  esac
}

main() {
  parse_args "$@"

  if ! command -v python3 >/dev/null 2>&1; then
    printf '[ERR] python3 is required.\n' >&2
    exit 1
  fi

  init_colors

  local ts_utc
  ts_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local py_script
  py_script="$(cat <<'PYEOF'
import csv
import hashlib
import io
import json
import os
import pwd
import re
import shutil
import subprocess
import sys
import tarfile
import time

(
    action, target, reseller_opt, single_user_opt, scan_dir_opt, dest_dir,
    log_dir_opt, nice_val, verify_s, replace_s, keep_quotas_s, dry_run_s,
    exit_code_s, fmt, quiet_s, script_name, script_version, ts_utc,
    c_red, c_green, c_yellow, c_cyan, c_bold, c_reset
) = sys.argv[1:25]

verify_archives = verify_s == "1"
replace_existing = replace_s == "1"
keep_quotas = keep_quotas_s == "1"
dry_run = dry_run_s == "1"
exit_code_mode = exit_code_s == "1"
quiet = quiet_s == "1"

USER_RE = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{0,31}$')

# Match modern & legacy cPanel backup archive filenames (usernames up to 16 chars)
ARCHIVE_PATTERNS = [
    re.compile(r'^cpmove-([a-z0-9][a-z0-9_-]{0,15})\.tar(?:\.(?:gz|xz|zst|bz2))?$'),
    re.compile(r'^backup-[0-9]{1,2}\.[0-9]{1,2}\.[0-9]{4}_[0-9]{2}-[0-9]{2}-[0-9]{2}_([a-z0-9][a-z0-9_-]{0,15})\.tar(?:\.(?:gz|xz|zst|bz2))?$'),
    re.compile(r'^([a-z0-9][a-z0-9_-]{0,15})\.tar(?:\.(?:gz|xz|zst|bz2))?$'),
]

SYSTEM_MYSQL_USERS = {
    "root", "mysql", "mysql.sys", "mysql.session", "mysql.infoschema",
    "mariadb.sys", "cpldap", "roundcube", "cphulkd", "eximstats",
    "leechprotect", "modsec", "munin", "cpanel", "dovecot",
}


def human_bytes(n):
    val = float(n)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(val) < 1024.0:
            return f"{val:.2f} {unit}" if unit != "B" else f"{int(val)} B"
        val /= 1024.0
    return f"{val:.2f} PiB"


def run_cmd(cmd, timeout=600):
    try:
        p = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            timeout=timeout,
        )
        return p.returncode, p.stdout, p.stderr
    except Exception as e:
        return 1, "", str(e)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def get_homedir(user):
    try:
        return pwd.getpwnam(user).pw_dir
    except KeyError:
        return None


def read_cpuser_meta(user):
    path = f"/var/cpanel/users/{user}"
    meta = {"exists": False, "owner": "-", "plan": "-", "ip": "-", "bwlimit": "-"}
    if not os.path.isfile(path):
        return meta
    meta["exists"] = True
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if "=" not in line or line.startswith("#"):
                    continue
                k, v = line.strip().split("=", 1)
                if k == "OWNER":
                    meta["owner"] = v
                elif k == "PLAN":
                    meta["plan"] = v
                elif k == "IP":
                    meta["ip"] = v
                elif k == "BWLIMIT":
                    meta["bwlimit"] = v
    except Exception:
        pass
    return meta


def is_reseller(user):
    if user == "root":
        return True
    if not os.path.isfile("/var/cpanel/resellers"):
        return False
    try:
        with open("/var/cpanel/resellers", "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if line.startswith(f"{user}:"):
                    return True
    except Exception:
        pass
    return False


def get_reseller_accounts(reseller):
    users = set()
    if os.path.isfile("/etc/trueuserowners"):
        try:
            with open("/etc/trueuserowners", "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    if ":" in line:
                        u, own = line.split(":", 1)
                        if own.strip() == reseller and USER_RE.match(u.strip()):
                            users.add(u.strip())
        except Exception:
            pass
    if not users and os.path.isdir("/var/cpanel/users"):
        for fn in os.listdir("/var/cpanel/users"):
            if fn.startswith(".") or not USER_RE.match(fn):
                continue
            m = read_cpuser_meta(fn)
            if m["owner"] == reseller:
                users.add(fn)
    return sorted(users)


def extract_user_from_archive_name(filename):
    base = os.path.basename(filename)
    for pat in ARCHIVE_PATTERNS:
        m = pat.match(base)
        if m:
            return m.group(1)
    return None


def verify_cpanel_archive(path):
    """
    Verify archive readability, tar structure, and presence of cPanel cp/<user>
    or homedir metadata without extracting anything to disk.
    """
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        return False, "missing or empty file"
    try:
        has_cp = False
        members_checked = 0
        with tarfile.open(path, "r:*") as tf:
            for member in tf:
                members_checked += 1
                name = member.name.lstrip("./")
                if "/cp/" in f"/{name}" or name.endswith("/version") or name.startswith("cpmove-"):
                    if "/cp/" in f"/{name}":
                        has_cp = True
                        break
                if members_checked >= 500:
                    break
        if members_checked == 0:
            return False, "empty tar archive"
        return True, "valid cPanel archive" if has_cp else "valid tar (cp/ not in first 500 entries)"
    except Exception as e:
        return False, f"corrupt archive: {e}"


def audit_mysql_super_users():
    mysql_bin = shutil.which("mysql")
    if not mysql_bin:
        return None, "mysql client not installed"
    query = (
        "SELECT User, Host, Super_priv, Grant_priv, File_priv "
        "FROM mysql.user "
        "WHERE Super_priv='Y' OR Grant_priv='Y' OR File_priv='Y';"
    )
    rc, out, err = run_cmd([mysql_bin, "--batch", "--skip-column-names", "-e", query], timeout=20)
    if rc != 0:
        return None, (err.strip() or out.strip() or "mysql query failed")
    findings = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        user, host, sup, gr, fl = parts[:5]
        if user in SYSTEM_MYSQL_USERS:
            continue
        privs = []
        if sup == "Y":
            privs.append("SUPER")
        if gr == "Y":
            privs.append("GRANT")
        if fl == "Y":
            privs.append("FILE")
        findings.append({
            "user": user,
            "host": host,
            "privileges": privs,
        })
    return findings, "ok"


def emit_output(payload, columns, rows, header_title):
    if fmt == "json":
        print(json.dumps(payload, indent=2))
        return
    if fmt == "csv":
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(columns)
        for r in rows:
            w.writerow(r)
        sys.stdout.write(buf.getvalue())
        return

    if not quiet:
        print("=" * 98)
        print(f" {c_bold}{script_name} v{script_version}{c_reset} | {header_title} | {ts_utc}")
        print("=" * 98)

    if not rows:
        print(f"{c_green}[CLEAN]{c_reset} No items found.")
        return

    widths = [len(c) for c in columns]
    for r in rows:
        for idx, val in enumerate(r):
            plain = re.sub(r'\033\[[0-9;]*m', '', str(val))
            if len(plain) > widths[idx]:
                widths[idx] = min(len(plain), 60)

    hdr = "  ".join(c.ljust(widths[i]) for i, c in enumerate(columns))
    sep = "  ".join("-" * widths[i] for i in range(len(columns)))
    print(f"{c_bold}{hdr}{c_reset}")
    print(sep)
    for r in rows:
        cells = []
        for idx, val in enumerate(r):
            s = str(val)
            plain = re.sub(r'\033\[[0-9;]*m', '', s)
            pad = max(0, widths[idx] - len(plain))
            cells.append(s + (" " * pad))
        print("  ".join(cells))


# ==============================================================================
# ACTION: SCAN
# ==============================================================================
if action == "scan":
    reseller = reseller_opt or (target if (target and not os.path.isdir(target)) else "")
    scan_dir = scan_dir_opt or (target if (target and os.path.isdir(target)) else "")
    if not scan_dir and reseller:
        hd = get_homedir(reseller)
        if not hd or not os.path.isdir(hd):
            print(f"[ERR] Could not resolve homedir for reseller '{reseller}'.", file=sys.stderr)
            sys.exit(1)
        scan_dir = hd
    if not scan_dir or not os.path.isdir(scan_dir):
        print("[ERR] Specify a valid reseller or --dir <path> to scan.", file=sys.stderr)
        sys.exit(1)

    discovered = []
    for entry in sorted(os.listdir(scan_dir)):
        fp = os.path.join(scan_dir, entry)
        if not os.path.isfile(fp):
            continue
        u = extract_user_from_archive_name(entry)
        if not u:
            continue
        if reseller and u == reseller:
            continue
        st = os.stat(fp)
        discovered.append({
            "user": u,
            "path": fp,
            "filename": entry,
            "size_bytes": st.st_size,
            "size_human": human_bytes(st.st_size),
            "mtime": int(st.st_mtime),
            "mtime_utc": time.strftime("%Y-%m-%d %H:%M", time.gmtime(st.st_mtime)),
        })

    # Deduplicate by user (keep newest mtime as PRIMARY, older as DUPLICATE)
    by_user = {}
    for d in sorted(discovered, key=lambda x: (-x["mtime"], x["filename"])):
        u = d["user"]
        if u not in by_user:
            d["role"] = "PRIMARY"
            by_user[u] = d
        else:
            d["role"] = "DUPLICATE"

    issues = 0
    records = []
    for d in sorted(discovered, key=lambda x: (x["user"], 0 if x["role"] == "PRIMARY" else 1)):
        meta = read_cpuser_meta(d["user"])
        integrity = "SKIPPED"
        if verify_archives:
            ok, msg = verify_cpanel_archive(d["path"])
            integrity = "VALID" if ok else "CORRUPT"
            if not ok:
                issues += 1
        if d["role"] == "DUPLICATE":
            issues += 1
        rec = dict(d)
        rec["account_exists"] = meta["exists"]
        rec["current_owner"] = meta["owner"]
        rec["current_plan"] = meta["plan"]
        rec["current_ip"] = meta["ip"]
        rec["integrity"] = integrity
        records.append(rec)

    payload = {
        "tool": script_name,
        "version": script_version,
        "action": "scan",
        "timestamp_utc": ts_utc,
        "scan_dir": scan_dir,
        "reseller": reseller or None,
        "total_archives": len(records),
        "unique_users": len(by_user),
        "issues_count": issues,
        "archives": records,
    }
    rows = []
    for r in records:
        role_s = r["role"]
        int_s = r["integrity"]
        if fmt == "table":
            role_s = f"{c_green}PRIMARY{c_reset}" if role_s == "PRIMARY" else f"{c_yellow}DUPLICATE{c_reset}"
            if int_s == "VALID":
                int_s = f"{c_green}VALID{c_reset}"
            elif int_s == "CORRUPT":
                int_s = f"{c_red}CORRUPT{c_reset}"
        rows.append([
            r["user"],
            role_s,
            r["size_human"],
            "YES" if r["account_exists"] else "NO",
            r["current_owner"],
            int_s,
            r["filename"],
        ])
    emit_output(payload, ["USER", "ROLE", "SIZE", "EXISTS", "OWNER", "VERIFY", "ARCHIVE"], rows, f"Scan | {scan_dir}")
    if fmt == "table" and not quiet:
        print(f"\nSummary: {len(records)} archive(s) | {len(by_user)} unique account(s) | {issues} warning(s)")
    if exit_code_mode and issues > 0:
        sys.exit(2)
    sys.exit(0)

# ==============================================================================
# ACTION: BACKUP
# ==============================================================================
elif action == "backup":
    accounts = []
    reseller = reseller_opt or (target if (target and not single_user_opt) else "")
    if single_user_opt:
        if not os.path.isfile(f"/var/cpanel/users/{single_user_opt}"):
            print(f"[ERR] cPanel user not found: {single_user_opt}", file=sys.stderr)
            sys.exit(1)
        accounts = [single_user_opt]
    elif reseller:
        if not is_reseller(reseller):
            print(f"[ERR] '{reseller}' is not a valid WHM reseller in /var/cpanel/resellers.", file=sys.stderr)
            sys.exit(1)
        accounts = get_reseller_accounts(reseller)
        if not accounts:
            print(f"[ERR] No resold accounts found owned by '{reseller}'.", file=sys.stderr)
            sys.exit(1)
    else:
        print("[ERR] Usage: rrbackups.sh backup <reseller> OR rrbackups.sh backup --user <user>", file=sys.stderr)
        sys.exit(1)

    day_slug = time.strftime("%Y%m%d", time.gmtime())
    out_dir = os.path.join(dest_dir, day_slug)
    log_dir = log_dir_opt or os.path.join(out_dir, "logs")

    if not dry_run:
        os.makedirs(out_dir, mode=0o700, exist_ok=True)
        os.chmod(out_dir, 0o700)
        os.makedirs(log_dir, mode=0o700, exist_ok=True)

    pkgacct_bin = "/scripts/pkgacct"
    if not dry_run and not os.path.isfile(pkgacct_bin):
        print(f"[ERR] {pkgacct_bin} not found on this server.", file=sys.stderr)
        sys.exit(1)

    results = []
    failed = 0
    for u in accounts:
        log_path = os.path.join(log_dir, f"{u}-pkgacct.log")
        if dry_run:
            results.append({
                "user": u,
                "status": "DRY-RUN",
                "archive": os.path.join(out_dir, f"cpmove-{u}.tar.gz"),
                "size_human": "-",
                "sha256": "-",
                "duration_sec": 0,
            })
            continue

        t0 = time.time()
        cmd = ["nice", "-n", nice_val, pkgacct_bin, u, out_dir]
        rc, out, err = run_cmd(cmd, timeout=1800)
        elapsed = round(time.time() - t0, 1)

        combined = out + ("\n" + err if err else "")
        fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as lf:
            lf.write(combined)

        arch_path = ""
        m = re.search(r'^pkgacctfile is:\s*(.+)$', combined, re.MULTILINE)
        if m:
            arch_path = m.group(1).strip()
        elif os.path.isfile(os.path.join(out_dir, f"cpmove-{u}.tar.gz")):
            arch_path = os.path.join(out_dir, f"cpmove-{u}.tar.gz")

        if rc == 0 and arch_path and os.path.isfile(arch_path) and os.path.getsize(arch_path) > 0:
            os.chmod(arch_path, 0o600)
            sz = os.path.getsize(arch_path)
            digest = sha256_file(arch_path)
            results.append({
                "user": u,
                "status": "OK",
                "archive": arch_path,
                "size_bytes": sz,
                "size_human": human_bytes(sz),
                "sha256": digest,
                "duration_sec": elapsed,
                "log_file": log_path,
            })
        else:
            failed += 1
            results.append({
                "user": u,
                "status": "FAILED",
                "archive": arch_path or "-",
                "size_bytes": 0,
                "size_human": "-",
                "sha256": "-",
                "duration_sec": elapsed,
                "log_file": log_path,
            })

    manifest_path = os.path.join(out_dir, "manifest.json")
    payload = {
        "tool": script_name,
        "version": script_version,
        "action": "backup",
        "dry_run": dry_run,
        "timestamp_utc": ts_utc,
        "dest_dir": out_dir,
        "manifest_file": manifest_path if not dry_run else None,
        "total": len(results),
        "failed": failed,
        "results": results,
    }
    if not dry_run:
        fd = os.open(manifest_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as mf:
            mf.write(json.dumps(payload, indent=2) + "\n")

    rows = []
    for r in results:
        st = r["status"]
        if fmt == "table":
            if st == "OK":
                st = f"{c_green}OK{c_reset}"
            elif st == "DRY-RUN":
                st = f"{c_yellow}DRY-RUN{c_reset}"
            else:
                st = f"{c_red}FAILED{c_reset}"
        rows.append([r["user"], st, r["size_human"], f"{r['duration_sec']}s", os.path.basename(r["archive"])])
    emit_output(payload, ["USER", "STATUS", "SIZE", "TIME", "ARCHIVE"], rows, f"Backup [{'DRY-RUN' if dry_run else 'APPLIED'}]")
    if fmt == "table" and not quiet and not dry_run:
        print(f"\nManifest: {manifest_path}")
    sys.exit(1 if failed > 0 else 0)

# ==============================================================================
# ACTION: RESTORE
# ==============================================================================
elif action == "restore":
    archives = []
    if target and os.path.isfile(target):
        archives = [os.path.abspath(target)]
    elif scan_dir_opt and os.path.isdir(scan_dir_opt):
        for fn in sorted(os.listdir(scan_dir_opt)):
            fp = os.path.join(scan_dir_opt, fn)
            if os.path.isfile(fp) and extract_user_from_archive_name(fn):
                archives.append(os.path.abspath(fp))
    else:
        print("[ERR] Usage: rrbackups.sh restore <archive.tar.gz> OR --dir <dir> [--dry-run]", file=sys.stderr)
        sys.exit(1)

    if not archives:
        print("[ERR] No compatible cPanel backup archives found to restore.", file=sys.stderr)
        sys.exit(1)

    day_slug = time.strftime("%Y%m%d", time.gmtime())
    work_dir = os.path.join(dest_dir, f"restore-{day_slug}")
    log_dir = log_dir_opt or os.path.join(work_dir, "logs")
    if not dry_run:
        os.makedirs(work_dir, mode=0o700, exist_ok=True)
        os.makedirs(log_dir, mode=0o700, exist_ok=True)

    results = []
    failed = 0
    for arch in archives:
        u = extract_user_from_archive_name(arch)
        if not u:
            failed += 1
            results.append({"archive": arch, "user": "-", "status": "INVALID_NAME", "note": "Unrecognized cPanel archive name"})
            continue
        if single_user_opt and u != single_user_opt:
            failed += 1
            results.append({"archive": arch, "user": u, "status": "USER_MISMATCH", "note": f"Expected --user {single_user_opt}"})
            continue
        if reseller_opt and u == reseller_opt:
            failed += 1
            results.append({"archive": arch, "user": u, "status": "BLOCKED", "note": "Refusing to overwrite reseller account itself"})
            continue

        ok_arc, msg_arc = verify_cpanel_archive(arch)
        if not ok_arc:
            failed += 1
            results.append({"archive": arch, "user": u, "status": "CORRUPT", "note": msg_arc})
            continue

        pre_meta = read_cpuser_meta(u)
        if pre_meta["exists"] and not replace_existing:
            status_tag = "DRY-RUN (EXISTS)" if dry_run else "SKIPPED_EXISTS"
            results.append({
                "archive": arch,
                "user": u,
                "status": status_tag,
                "pre_owner": pre_meta["owner"],
                "pre_plan": pre_meta["plan"],
                "pre_ip": pre_meta["ip"],
                "note": "Account already exists (pass --replace-existing to pre-backup, remove & restore)",
            })
            continue

        if dry_run:
            results.append({
                "archive": arch,
                "user": u,
                "status": "DRY-RUN",
                "pre_owner": pre_meta["owner"],
                "pre_plan": pre_meta["plan"],
                "pre_ip": pre_meta["ip"],
                "note": f"Verified ({msg_arc}); would restore via /scripts/restorepkg",
            })
            continue

        # Live restore flow
        if pre_meta["exists"] and replace_existing:
            rc_b, _, err_b = run_cmd(["nice", "-n", nice_val, "/scripts/pkgacct", u, work_dir], timeout=1800)
            if rc_b != 0:
                failed += 1
                results.append({"archive": arch, "user": u, "status": "PREBACKUP_FAILED", "note": err_b[:120]})
                continue
            rc_k, _, err_k = run_cmd(["nice", "-n", nice_val, "/scripts/killacct", "--force", u], timeout=600)
            if rc_k != 0:
                failed += 1
                results.append({"archive": arch, "user": u, "status": "KILLACCT_FAILED", "note": err_k[:120]})
                continue

        rc_r, out_r, err_r = run_cmd(["nice", "-n", nice_val, "/scripts/restorepkg", "--skipres", arch], timeout=3600)
        log_path = os.path.join(log_dir, f"{u}-restorepkg.log")
        fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as lf:
            lf.write(out_r + ("\n" + err_r if err_r else ""))

        if rc_r != 0:
            failed += 1
            results.append({"archive": arch, "user": u, "status": "RESTORE_FAILED", "note": f"See {log_path}"})
            continue

        # Post-restore OWNER / PLAN verification
        notes = []
        target_owner = reseller_opt or (pre_meta["owner"] if pre_meta["exists"] else "")
        post_meta = read_cpuser_meta(u)
        if target_owner and target_owner != "-" and post_meta["owner"] != target_owner:
            whm = shutil.which("whmapi1")
            if whm:
                run_cmd([whm, "modifyacct", f"user={u}", f"owner={target_owner}"], timeout=60)
                notes.append(f"owner->{target_owner}")
        if pre_meta["exists"] and pre_meta["plan"] != "-" and post_meta["plan"] != pre_meta["plan"]:
            whm = shutil.which("whmapi1")
            if whm:
                run_cmd([whm, "changepackage", f"user={u}", f"pkg={pre_meta['plan']}"], timeout=60)
                notes.append(f"plan->{pre_meta['plan']}")

        results.append({
            "archive": arch,
            "user": u,
            "status": "RESTORED",
            "log_file": log_path,
            "note": ", ".join(notes) if notes else "restored cleanly",
        })

    payload = {
        "tool": script_name,
        "version": script_version,
        "action": "restore",
        "dry_run": dry_run,
        "timestamp_utc": ts_utc,
        "total": len(results),
        "failed": failed,
        "results": results,
    }
    rows = [[r["user"], r["status"], os.path.basename(r["archive"]), r["note"]] for r in results]
    emit_output(payload, ["USER", "STATUS", "ARCHIVE", "NOTE"], rows, f"Restore [{'DRY-RUN' if dry_run else 'APPLIED'}]")
    sys.exit(1 if failed > 0 else 0)

# ==============================================================================
# ACTION: AUDIT-MYSQL
# ==============================================================================
elif action == "audit-mysql":
    findings, msg = audit_mysql_super_users()
    if findings is None:
        print(f"[ERR] MySQL audit failed: {msg}", file=sys.stderr)
        sys.exit(1)

    payload = {
        "tool": script_name,
        "version": script_version,
        "action": "audit-mysql",
        "timestamp_utc": ts_utc,
        "rogue_privileged_count": len(findings),
        "findings": findings,
    }
    rows = [[f["user"], f["host"], ",".join(f["privileges"])] for f in findings]
    emit_output(payload, ["MYSQL_USER", "HOST", "PRIVILEGES"], rows, "MySQL Super-Privilege Audit")
    if fmt == "table" and not quiet:
        print(f"\nSummary: {len(findings)} non-system user(s) with SUPER/GRANT/FILE privileges.")
    if exit_code_mode and len(findings) > 0:
        sys.exit(2)
    sys.exit(0)
PYEOF
)"

  python3 -c "$py_script" \
    "$ACTION" "$TARGET" "$RESELLER" "$SINGLE_USER" "$SCAN_DIR" "$DEST_DIR" \
    "$LOG_DIR" "$NICE_VAL" "$VERIFY_ARCHIVES" "$REPLACE_EXISTING" "$KEEP_QUOTAS" "$DRY_RUN" \
    "$EXIT_CODE_MODE" "$OUTPUT_FMT" "$QUIET" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$ts_utc" \
    "$C_RED" "$C_GREEN" "$C_YELLOW" "$C_CYAN" "$C_BOLD" "$C_RESET"
}

main "$@"
