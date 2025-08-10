#!/usr/bin/env bash
set -euo pipefail

# snap2deb-smart.sh - Replace Snap packages with apt equivalents when available

MODE="${1:-apply}"  # apply or dry-run
log() { printf "%-10s %s\n" "$1" "$2"; }

# Check if apt package exists
has_deb_equivalent() {
    local pkg="$1"
    apt-cache show "$pkg" 2>/dev/null | grep -q '^Package: '
}

# Try alternative names
find_alternative_name() {
    local snap_name="$1"
    local alt_name="${snap_name//-desktop/}" # remove -desktop suffix
    if has_deb_equivalent "$alt_name"; then
        echo "$alt_name"
    fi
}

process_snap() {
    local snap_name="$1"
    local deb_candidate="$snap_name"

    # 1. Exact match in .deb
    if ! has_deb_equivalent "$deb_candidate"; then
        # 2. Try alternative
        alt=$(find_alternative_name "$snap_name")
        if [[ -n "$alt" ]]; then
            deb_candidate="$alt"
        else
            deb_candidate=""
        fi
    fi

    if [[ -n "$deb_candidate" ]]; then
        if [[ "$MODE" != "dry-run" ]]; then
            read -rp "Replace Snap '$snap_name' with .deb '$deb_candidate'? (y/n) " choice
        else
            choice="n"
            log "DRY-RUN" "Would check/replace: $snap_name → $deb_candidate"
        fi

        if [[ "$choice" == "y" ]]; then
            log "INSTALL" "$deb_candidate (.deb)"
            if sudo apt install -y "$deb_candidate"; then
                log "REMOVE" "$snap_name (snap)"
                sudo snap remove --purge "$snap_name"
            else
                log "ERROR" "Failed to install $deb_candidate (.deb) → Keeping Snap version"
            fi
        else
            log "SKIP" "$snap_name"
        fi
    else
        log "NO-DEB" "No .deb found for $snap_name (keeping snap)"
    fi
}

main() {
    log "MODE" "$MODE"
    log "START" "Smart Snap replacement"
    echo

    sudo apt update -y

    snap list | awk 'NR>1 {print $1}' | while read -r snap_pkg; do
        process_snap "$snap_pkg" || log "WARN" "Error processing $snap_pkg"
    done

    echo
    log "DONE" "Operation completed"
}

main

