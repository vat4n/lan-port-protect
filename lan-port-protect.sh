#!/usr/bin/env bash

set -euo pipefail

CHAIN="LAN_PORT_PROTECT"
RULE_COMMENT="lan-port-protect"
LOG_PREFIX="IPTABLES_WAN_BLOCK: "

LAN_NETS=(
    "10.151.0.0/24"
    "10.150.0.0/24"
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
BACKUP_FILE="$BACKUP_DIR/iptables-before-lan-port-protect.rules"
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

backup_current_rules() {
    echo "Creating backup: $BACKUP_FILE"
    iptables-save > "$BACKUP_FILE"
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

remove_managed_rules() {
    while iptables -C INPUT -p tcp -m multiport --dports "$PORTS_CSV" -j "$CHAIN" 2>/dev/null; do
        iptables -D INPUT -p tcp -m multiport --dports "$PORTS_CSV" -j "$CHAIN"
    done

    if iptables -L "$CHAIN" >/dev/null 2>&1; then
        iptables -F "$CHAIN"
        iptables -X "$CHAIN"
    fi
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
    if [[ ! -f "$BACKUP_FILE" ]]; then
        echo "Backup file not found: $BACKUP_FILE"
        exit 1
    fi

    echo "Restoring rules from backup: $BACKUP_FILE"
    iptables-restore < "$BACKUP_FILE"
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
    echo "Backup file: $BACKUP_FILE"
    echo "Saved rules file: $SAVED_RULES_FILE"
}

usage() {
    cat <<EOF
Usage: $0 {apply|rollback|status}

Commands:
    apply       Backup current rules, apply protection rules, save current state
    rollback    Restore rules from backup and save restored state
    status      Show current iptables status
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
            rollback_rules
            show_status
            ;;
        status)
            show_status
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
