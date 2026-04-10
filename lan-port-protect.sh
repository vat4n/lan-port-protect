#!/usr/bin/env bash

set -euo pipefail

CHAIN="LAN_PORT_PROTECT"
RULE_COMMENT="lan-port-protect"
LOG_PREFIX="IPTABLES_WAN_BLOCK: "

LAN_NETS=(
    "10.141.0.0/24"
    "10.140.0.0/24"
)

PORTS=(
    "3306"
    "10050"
    "10051"
    "29090"
    "29093"
    "29094"
    "29100"
    "29115"
)

BACKUP_DIR="/root/iptables-backups"
BACKUP_LATEST_FILE="$BACKUP_DIR/iptables-before-lan-port-protect.latest.rules"
SAVED_RULES_FILE="/etc/iptables/rules.v4"

PORTS_CSV="$(IFS=,; echo "${PORTS[*]}")"

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "Run as root"
        exit 1
    fi
}

ensure_dirs() {
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$(dirname "$SAVED_RULES_FILE")"
}

generate_backup_file() {
    local ts
    ts="$(date '+%Y-%m-%d_%H-%M-%S')"
    echo "$BACKUP_DIR/iptables-before-lan-port-protect-${ts}.rules"
}

backup_current_rules() {
    local backup_file
    backup_file="$(generate_backup_file)"

    echo "Creating backup: $backup_file"
    iptables-save > "$backup_file"

    cp -f "$backup_file" "$BACKUP_LATEST_FILE"

    LAST_BACKUP_FILE="$backup_file"
}

save_current_rules() {
    echo "Saving current rules to: $SAVED_RULES_FILE"
    iptables-save > "$SAVED_RULES_FILE"
}

ensure_base_rules() {
    iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$RULE_COMMENT" -j ACCEPT

    iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 2 -i lo -m comment --comment "$RULE_COMMENT" -j ACCEPT
}

create_or_reset_chain() {
    iptables -N "$CHAIN" 2>/dev/null || true
    iptables -F "$CHAIN"
}

attach_chain_to_input() {
    while iptables -C INPUT -p tcp -m multiport --dports "$PORTS_CSV" -j "$CHAIN" 2>/dev/null; do
        iptables -D INPUT -p tcp -m multiport --dports "$PORTS_CSV" -j "$CHAIN"
    done

    iptables -I INPUT 3 -p tcp -m multiport --dports "$PORTS_CSV" -m comment --comment "$RULE_COMMENT" -j "$CHAIN"
}

fill_chain() {
    for NET in "${LAN_NETS[@]}"; do
        iptables -A "$CHAIN" \
            -p tcp \
            -s "$NET" \
            -m multiport --dports "$PORTS_CSV" \
            -m conntrack --ctstate NEW \
            -m comment --comment "$RULE_COMMENT" \
            -j ACCEPT
    done

    iptables -A "$CHAIN" \
        -p tcp \
        -m multiport --dports "$PORTS_CSV" \
        -m conntrack --ctstate NEW \
        -m limit --limit 10/min --limit-burst 20 \
        -m comment --comment "$RULE_COMMENT" \
        -j LOG --log-prefix "$LOG_PREFIX" --log-level 4

    iptables -A "$CHAIN" \
        -p tcp \
        -m multiport --dports "$PORTS_CSV" \
        -m comment --comment "$RULE_COMMENT" \
        -j DROP

    iptables -A "$CHAIN" \
        -m comment --comment "$RULE_COMMENT" \
        -j RETURN
}

list_backups() {
    find "$BACKUP_DIR" -maxdepth 1 -type f -name 'iptables-before-lan-port-protect-*.rules' | sort || true
}

apply_rules() {
    echo "Applying rules..."
    ensure_dirs
    backup_current_rules
    ensure_base_rules
    create_or_reset_chain
    fill_chain
    attach_chain_to_input
    save_current_rules
    echo "Rules applied successfully."
}

rollback_rules() {
    local restore_file="${1:-$BACKUP_LATEST_FILE}"

    if [[ ! -f "$restore_file" ]]; then
        echo "Backup file not found: $restore_file"
        exit 1
    fi

    echo "Restoring rules from backup: $restore_file"
    iptables-restore < "$restore_file"
    save_current_rules
    echo "Rollback completed."
}

show_status() {
    echo "=== INPUT chain ==="
    iptables -L INPUT -n -v --line-numbers
    echo

    if iptables -L "$CHAIN" >/dev/null 2>&1; then
        echo "=== $CHAIN chain ==="
        iptables -L "$CHAIN" -n -v --line-numbers
        echo
    else
        echo "Chain $CHAIN does not exist."
        echo
    fi

    echo "Managed TCP ports: $PORTS_CSV"
    echo "Allowed LAN subnets: ${LAN_NETS[*]}"
    echo "Latest backup file: $BACKUP_LATEST_FILE"

    if [[ -n "${LAST_BACKUP_FILE:-}" ]]; then
        echo "Current session backup file: $LAST_BACKUP_FILE"
    fi

    echo "Saved rules file: $SAVED_RULES_FILE"
}

show_backups() {
    ensure_dirs
    echo "Available backups:"
    list_backups
}

usage() {
    cat <<EOF
Usage:
    $0 apply
    $0 status
    $0 backups
    $0 rollback
    $0 rollback <backup_file>

Commands:
    apply                   Backup current rules, apply protection rules, save current state
    status                  Show current iptables status
    backups                 Show available backup files
    rollback                Restore rules from latest backup
    rollback <backup_file>  Restore rules from specified backup file
EOF
}

main() {
    require_root

    case "${1:-}" in
        apply)
            apply_rules
            show_status
            ;;
        rollback)
            shift || true
            rollback_rules "${1:-}"
            show_status
            ;;
        status)
            ensure_dirs
            show_status
            ;;
        backups)
            show_backups
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
