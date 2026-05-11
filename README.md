# CWP Fix DNS

BIND zone file manager for **CWP Control Web Panel**. Manages CNAME records for subdomains (cpanel, mail, www, ftp) across all zone files in `/var/named`.

## Features

- **Two-Phase TTL Update** — TTL=0 for fast propagation, then TTL=86400 (24h) for production
- **Dry-Run Mode** — Preview changes without applying them
- **Backup/Restore** — Timestamped backups with quick undo
- **Zone Validation** — `named-checkzone` before reload
- **Logging** — All operations logged to `/var/log/cwp_fix_dns.log`
- **Email Notifications** — Optional alerts on success/failure

## Installation

### Method 1: Quick Install (curl | sh)

```bash
curl -sL https://raw.githubusercontent.com/mogbil/cwp/main/cwp_fix_dns.sh | tee /usr/local/bin/cwp_fix_dns.sh > /dev/null && chmod +x /usr/local/bin/cwp_fix_dns.sh
cwp_fix_dns
```

### Method 2: Download

```bash
wget -O /usr/local/bin/cwp_fix_dns.sh https://raw.githubusercontent.com/mogbil/cwp/main/cwp_fix_dns.sh
chmod +x /usr/local/bin/cwp_fix_dns.sh
```

### Method 3: Clone

```bash
git clone https://github.com/mogbil/cwp.git /tmp/cwp
cp /tmp/cwp/cwp_fix_dns.sh /usr/local/bin/cwp_fix_dns.sh
chmod +x /usr/local/bin/cwp_fix_dns.sh
rm -rf /tmp/cwp
```

### Method 4: Manual Copy

```bash
cp cwp_fix_dns.sh /usr/local/bin/cwp_fix_dns.sh
chmod +x /usr/local/bin/cwp_fix_dns.sh
```
or normal use
```bash
./cwp_fix_dns.sh
```

## Configuration

Edit these variables at the top of the script:

```bash
NAMED_DIR="/var/named"           # Zone files location
BACKUP_DIR="/var/named/bak"      # Backup location
SUBDOMAINS=("cpanel" "mail" "www" "ftp")  # Subdomains to manage
WAIT_TIME=300                    # Seconds between TTL phases
LOG_FILE="/var/log/cwp_fix_dns.log"      # Log file path
EMAIL_TO=""                      # Email for notifications (optional)
```

### Menu Options

| Option | Description |
|--------|-------------|
| `[1]` Fix + Add (both) | Fix existing and add missing records |
| `[2]` Fix existing | Overwrite wrong records only |
| `[3]` Add missing | Add missing records only |
| `[4]` Backup | Create backup of all zone files |
| `[5]` Restore | Restore from backup |
| `[6]` Show MX/mail | Display current MX and mail records |
| `[D]` Toggle Dry-Run | Preview changes without applying |
| `[U]` Quick Undo | Restore last backup |
| `[0]` Exit | Exit script |

## Safety

- MX record check before any changes (RFC 2181 compliance)
- Backup created before any modification
- Zone validation before `rndc reload`
- Error handling with logging

## Requirements

- BIND DNS server
- `named-checkzone` utility
- `rndc` command
- Root/sudo access

## License

by [WondTech](https://wondtech.com) © 2026
