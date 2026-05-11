#!/bin/bash

# ═══════════════════════════════════
# Configuration
# ═══════════════════════════════════
NAMED_DIR="/var/named"
BACKUP_DIR="/var/named/bak"
SUBDOMAINS=("cpanel" "mail" "www" "ftp")
LOG_FILE="/var/log/cwp_fix_dns.log"
EMAIL_TO=""
DRY_RUN=false
LAST_OPERATION=""
WAIT_TIME=300
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ═══════════════════════════════════
# Function: Log Action
# ═══════════════════════════════════
log_action() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# ═══════════════════════════════════
# Function: Validate Zones
# ═══════════════════════════════════
validate_zones() {
    local errors=0
    for file in "$NAMED_DIR"/*.db; do
        [ -f "$file" ] || continue
        domain=$(basename "$file" .db)
        if ! named-checkzone "$domain" "$file" > /dev/null 2>&1; then
            echo -e "${RED}✗ Zone validation failed: $domain${NC}"
            log_action "Zone validation failed: $domain" "ERROR"
            errors=$((errors + 1))
        fi
    done
    return $errors
}

# ═══════════════════════════════════
# Function: Send Notification
# ═══════════════════════════════════
send_notification() {
    local subject="$1"
    local body="$2"
    if [ -n "$EMAIL_TO" ]; then
        echo "$body" | mail -s "$subject" "$EMAIL_TO" 2>/dev/null || \
            log_action "Failed to send email to $EMAIL_TO" "ERROR"
    fi
}

# ═══════════════════════════════════
# Function: Quick Undo
# ═══════════════════════════════════
quick_undo() {
    echo ""
    echo "═══════════════════════════════════"
    echo "Quick Undo"
    echo "═══════════════════════════════════"

    LAST_BACKUP=$(cat "$BACKUP_DIR/.last" 2>/dev/null)

    if [ -z "$LAST_BACKUP" ] || [ ! -d "$LAST_BACKUP" ]; then
        echo -e "${RED}✗ No previous operation found${NC}"
        return 1
    fi

    echo -e "${YELLOW}⚠  This will undo the last operation:${NC}"
    echo "   Restoring from: $LAST_BACKUP"
    echo ""
    read -p "Are you sure? (yes/no): " confirm

    if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
        echo "Cancelled"
        return 0
    fi

    count=0
    for file in "$LAST_BACKUP"/*.db; do
        [ -f "$file" ] || continue
        cp "$file" "$NAMED_DIR/"
        ((count++))
    done

    if rndc reload > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Restored $count files${NC}"
        echo -e "${GREEN}✓ DNS reloaded${NC}"
        log_action "Quick undo completed: $count files restored from $LAST_BACKUP" "INFO"
    else
        echo -e "${RED}✗ DNS reload failed${NC}"
        log_action "Quick undo: rndc reload failed" "ERROR"
    fi
}

# ═══════════════════════════════════
# Function: Create Backup
# ═══════════════════════════════════
create_backup() {
    echo ""
    echo "═══════════════════════════════════"
    echo "Creating Backup"
    echo "═══════════════════════════════════"
    
    mkdir -p "$BACKUP_DIR"
    
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_SUBDIR="$BACKUP_DIR/backup_$TIMESTAMP"
    mkdir -p "$BACKUP_SUBDIR"
    
    count=0
    for file in "$NAMED_DIR"/*.db; do
        [ -f "$file" ] || continue
        cp "$file" "$BACKUP_SUBDIR/"
        ((count++))
    done
    
    echo -e "${GREEN}✓ Backed up $count files${NC}"
    echo "  Location: $BACKUP_SUBDIR"
    echo ""
    
    echo "$BACKUP_SUBDIR" > "$BACKUP_DIR/.latest"
    LAST_OPERATION="$BACKUP_SUBDIR"
    log_action "Backup created: $BACKUP_SUBDIR ($count files)"
}

# ═══════════════════════════════════
# Function: Fix NS Records
# ═══════════════════════════════════
fix_ns_records() {
    echo ""
    echo "═══════════════════════════════════"
    echo "Fix NS Records (ns1/ns2)"
    echo "═══════════════════════════════════"
    echo ""

    read -p "Enter NS domain (e.g. example.com): " ns_domain
    read -p "Enter IP address for ns1 & ns2: " ip

    if [ -z "$ns_domain" ] || [ -z "$ip" ]; then
        echo -e "${RED}✗ NS domain and IP are required${NC}"
        return 1
    fi

    base_ns=$(echo "$ns_domain" | sed 's/^[^.]*\.\(.*\)/\1/')

    echo ""
    echo -e "${YELLOW}⚠  This will update NS records for ALL zones${NC}"
    echo "   NS: ns1.$base_ns. and ns2.$base_ns."
    echo "   IP: $ip"
    echo ""
    read -p "Continue? (yes/no): " confirm

    if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
        echo "Cancelled"
        return 0
    fi

    create_backup

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}DRY-RUN MODE - No changes will be made${NC}"
        for file in "$NAMED_DIR"/*.db; do
            [ -f "$file" ] || continue
            zone=$(basename "$file" .db)
            echo "  @ NS 86400 ns1.$base_ns. (would be set)"
            echo "  @ NS 86400 ns2.$base_ns. (would be set)"
            echo "  ns1.$base_ns. A $ip (would be set)"
            echo "  ns2.$base_ns. A $ip (would be set)"
        done
        return 0
    fi

    count=0
    for file in "$NAMED_DIR"/*.db; do
        [ -f "$file" ] || continue
        zone=$(basename "$file" .db)
        ns1="ns1.$base_ns"
        ns2="ns2.$base_ns"

        sed -i "/^@[[:space:]].*IN[[:space:]]*NS[[:space:]].*$/d" "$file"
        sed -i "/^${ns1}\.[[:space:]]/d" "$file"
        sed -i "/^${ns2}\.[[:space:]]/d" "$file"
        sed -i "/^${ip}[[:space:]].*IN[[:space:]]*A$/d" "$file"

        echo "@ NS 86400 $ns1." >> "$file"
        echo "@ NS 86400 $ns2." >> "$file"
        echo "$ns1. 86400 IN A $ip" >> "$file"
        echo "$ns2. 86400 IN A $ip" >> "$file"

        echo -e "  ${GREEN}+${NC} $zone: NS updated"
        ((count++))
    done

    if validate_zones; then
        if rndc reload > /dev/null 2>&1; then
            echo ""
            echo -e "${GREEN}✓ NS records updated for $count zones${NC}"
            log_action "NS records updated for all zones with IP $ip"
        else
            echo -e "${RED}✗ rndc reload failed${NC}"
            log_action "NS fix: rndc reload failed" "ERROR"
        fi
    else
        echo -e "${RED}✗ Zone validation failed${NC}"
    fi
}

# ═══════════════════════════════════
# Function: Restore Backup
# ═══════════════════════════════════
restore_backup() {
    echo ""
    echo "═══════════════════════════════════"
    echo "Restore Backup"
    echo "═══════════════════════════════════"
    
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A $BACKUP_DIR 2>/dev/null | grep backup_)" ]; then
        echo -e "${RED}✗ No backups found in $BACKUP_DIR${NC}"
        return 1
    fi
    
    echo "Available backups:"
    echo "─────────────────────────────────────"
    
    backups=($(ls -dt "$BACKUP_DIR"/backup_* 2>/dev/null))
    
    for i in "${!backups[@]}"; do
        backup="${backups[$i]}"
        timestamp=$(basename "$backup" | sed 's/backup_//')
        file_count=$(ls "$backup" | wc -l)
        formatted_date=$(echo "$timestamp" | sed 's/\(....\)\(..\)\(..\)_\(..\)\(..\)\(..\)/\1-\2-\3 \4:\5:\6/')
        echo "  [$((i+1))] $formatted_date  ($file_count files)"
    done
    
    echo "  [0] Cancel"
    echo "─────────────────────────────────────"
    echo ""
    read -p "Select backup number to restore: " choice
    
    if [ "$choice" = "0" ] || [ -z "$choice" ]; then
        echo "Cancelled"
        return 0
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#backups[@]}" ]; then
        echo -e "${RED}✗ Invalid choice${NC}"
        return 1
    fi
    
    selected="${backups[$((choice-1))]}"
    echo ""
    echo -e "${YELLOW}⚠  This will overwrite current DNS files with backup from:${NC}"
    echo "   $selected"
    echo ""
    read -p "Are you sure? (yes/no): " confirm
    
    if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
        echo "Cancelled"
        return 0
    fi
    
    count=0
    for file in "$selected"/*.db; do
        [ -f "$file" ] || continue
        cp "$file" "$NAMED_DIR/"
        ((count++))
    done
    
    rndc reload
    echo ""
    echo -e "${GREEN}✓ Restored $count files from backup${NC}"
    echo -e "${GREEN}✓ DNS reloaded${NC}"
}

# ═══════════════════════════════════
# Function: Safety Check
# ═══════════════════════════════════
safety_check() {
    echo ""
    echo "═══════════════════════════════════"
    echo "Safety Check: MX & mail records"
    echo "═══════════════════════════════════"
    echo ""
    echo -e "${YELLOW}⚠  Warning: MX records cannot point to CNAME (RFC 2181)${NC}"
    echo "   If 'mail' is referenced by MX, converting it will break email!"
    echo ""
    echo "Current MX and mail records:"
    echo "─────────────────────────────────────"
    grep -E "^(mail|.*MX)" "$NAMED_DIR"/*.db 2>/dev/null | head -30
    echo "─────────────────────────────────────"
    echo ""
    echo "Subdomains to be processed: ${SUBDOMAINS[*]}"
    echo ""
    read -p "Continue? (yes/no): " confirm
    
    if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
        return 1
    fi
    return 0
}

# ═══════════════════════════════════
# Function: Process Records
# ═══════════════════════════════════
process_records() {
    local ttl=$1
    local mode=$2

    for file in "$NAMED_DIR"/*.db; do
        [ -f "$file" ] || continue
        domain=$(basename "$file" .db)

        for sub in "${SUBDOMAINS[@]}"; do
            correct="$sub $ttl IN CNAME $domain."

            if grep -qE "^${sub}[[:space:]]+${ttl}[[:space:]]+IN[[:space:]]+CNAME[[:space:]]+${domain}\.$" "$file"; then
                echo -e "  ${GREEN}✓${NC} $domain → $sub: correct, skipped"
            else
                existing=$(grep -E "^${sub}[[:space:]]" "$file" 2>/dev/null)

                if [ -n "$existing" ]; then
                    sed -i "/^${sub}[[:space:]]/d" "$file"

                    if [ "$mode" = "fix" ] || [ "$mode" = "both" ]; then
                        if [ "$DRY_RUN" = true ]; then
                            echo -e "  ${YELLOW}↻${NC} [DRY-RUN] $domain → $sub: would be fixed"
                        else
                            echo "$correct" >> "$file"
                            echo -e "  ${YELLOW}↻${NC} $domain → $sub: fixed"
                            log_action "Fixed record: $sub IN CNAME $domain (TTL=$ttl)"
                        fi
                    else
                        if [ "$DRY_RUN" = true ]; then
                            echo -e "  ${BLUE}⊘${NC} [DRY-RUN] $domain → $sub: exists (would skip in fix mode)"
                        else
                            echo -e "  ${BLUE}⊘${NC} $domain → $sub: exists (skipped in add mode)"
                        fi
                    fi
                else
                    if [ "$mode" = "add" ] || [ "$mode" = "both" ]; then
                        if [ "$DRY_RUN" = true ]; then
                            echo -e "  ${GREEN}+${NC} [DRY-RUN] $domain → $sub: would be added"
                        else
                            echo "$correct" >> "$file"
                            echo -e "  ${GREEN}+${NC} $domain → $sub: added"
                            log_action "Added record: $sub IN CNAME $domain (TTL=$ttl)"
                        fi
                    else
                        if [ "$DRY_RUN" = true ]; then
                            echo -e "  ${BLUE}⊘${NC} [DRY-RUN] $domain → $sub: missing (would skip in fix mode)"
                        else
                            echo -e "  ${BLUE}⊘${NC} $domain → $sub: missing (skipped in fix mode)"
                        fi
                    fi
                fi
            fi
        done
    done
}

# ═══════════════════════════════════
# Function: Run with TTL Phases
# ═══════════════════════════════════
run_with_phases() {
    local mode=$1

    safety_check || { echo "Cancelled"; return 0; }

    if [ "$DRY_RUN" = true ]; then
        echo ""
        echo "═══════════════════════════════════"
        echo -e "${YELLOW}DRY-RUN MODE - No changes will be made${NC}"
        echo "═══════════════════════════════════"
    fi

    create_backup

    echo ""
    echo "═══════════════════════════════════"
    echo "Phase 1: Applying TTL = 0"
    echo "═══════════════════════════════════"
    process_records 0 "$mode"

    if [ "$DRY_RUN" = false ]; then
        if rndc reload > /dev/null 2>&1; then
            echo ""
            echo -e "${GREEN}✓ TTL = 0 applied${NC}"
            log_action "Phase 1 complete: TTL=0 mode=$mode"
        else
            echo -e "${RED}✗ rndc reload failed${NC}"
            log_action "Phase 1: rndc reload failed" "ERROR"
            send_notification "[CWP DNS] Error: rndc reload failed" "Phase 1 rndc reload failed for mode=$mode"
            return 1
        fi
    fi
    echo ""

    echo "Waiting $WAIT_TIME seconds ($(($WAIT_TIME / 60)) minutes) for cache expiration..."
    echo "   Press Ctrl+C to stop and skip to Phase 2 manually later"
    echo ""

    remaining=$WAIT_TIME
    while [ $remaining -gt 0 ]; do
        mins=$((remaining / 60))
        secs=$((remaining % 60))
        printf "   ⏱  Remaining: %d minutes (%02d:%02d left)\n" "$mins" "$mins" "$secs"
        sleep 1
        remaining=$((remaining - 1))
    done

    echo ""
    echo "═══════════════════════════════════"
    echo "Phase 2: Applying TTL = 86400"
    echo "═══════════════════════════════════"
    process_records 86400 "$mode"

    if [ "$DRY_RUN" = false ]; then
        if validate_zones; then
            if rndc reload > /dev/null 2>&1; then
                echo ""
                echo -e "${GREEN}✓ Complete! TTL = 86400 applied${NC}"
                log_action "Phase 2 complete: TTL=86400 mode=$mode"
                send_notification "[CWP DNS] Success" "DNS update completed successfully (mode=$mode)"
            else
                echo -e "${RED}✗ rndc reload failed${NC}"
                log_action "Phase 2: rndc reload failed" "ERROR"
                send_notification "[CWP DNS] Error: rndc reload failed" "Phase 2 rndc reload failed for mode=$mode"
                return 1
            fi
        else
            echo -e "${RED}✗ Zone validation failed - changes NOT applied${NC}"
            log_action "Zone validation failed - aborted" "ERROR"
            send_notification "[CWP DNS] Error: Zone validation failed" "Zone validation failed, operation aborted"
            return 1
        fi
    fi
}

# ═══════════════════════════════════
# Main Menu
# ═══════════════════════════════════
show_menu() {
    clear
    echo "╔════════════════════════════════════╗"
    echo "║           CWP Fix DNS              ║"
    echo "║       CWP Control Web Panel        ║"
    echo "║    Subdomain Manager for BIND      ║"
    echo "║      by WondTech.com © 2026        ║"
    echo "╚════════════════════════════════════╝"
    echo ""
    echo "Subdomains: ${SUBDOMAINS[*]}"
    echo "Zone Dir:   $NAMED_DIR"
    echo "Backup Dir: $BACKUP_DIR"
    echo ""
    echo "─────────────────────────────────────"
    echo "  [1] Fix + Add (both)"
    echo "  [2] Fix existing records (wrong values)"
    echo "  [3] Add missing records only"
    echo "  [4] Backup current zone files"
    echo "  [5] Restore from backup"
    echo "  [6] Show current MX/mail records"
    echo "  [N] Fix NS Records (ns1/ns2)"
    echo "  [D] Toggle Dry-Run Mode (currently: $([ "$DRY_RUN" = true ] && echo "ON" || echo "OFF"))"
    echo "  [U] Quick Undo last operation"
    echo "  [0] Exit"
    echo "─────────────────────────────────────"
    echo ""
}

# ═══════════════════════════════════
# Main Loop
# ═══════════════════════════════════
while true; do
    show_menu
    read -p "Select option: " option
    
    case $option in
        1)
            run_with_phases "both"
            read -p "Press Enter to continue..."
            ;;
        2)
            run_with_phases "fix"
            read -p "Press Enter to continue..."
            ;;
        3)
            run_with_phases "add"
            read -p "Press Enter to continue..."
            ;;
        4)
            create_backup
            read -p "Press Enter to continue..."
            ;;
        5)
            restore_backup
            read -p "Press Enter to continue..."
            ;;
        6)
            echo ""
            grep -E "^(mail|.*MX)" "$NAMED_DIR"/*.db 2>/dev/null | head -30
            echo ""
            read -p "Press Enter to continue..."
            ;;
        N|n)
            fix_ns_records
            read -p "Press Enter to continue..."
            ;;
        D|d)
            if [ "$DRY_RUN" = true ]; then
                DRY_RUN=false
                echo -e "${BLUE}Dry-Run Mode: OFF${NC}"
            else
                DRY_RUN=true
                echo -e "${YELLOW}Dry-Run Mode: ON${NC}"
            fi
            sleep 1
            ;;
        U|u)
            quick_undo
            read -p "Press Enter to continue..."
            ;;
        0)
            echo "Goodbye!"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            sleep 1
            ;;
    esac
done