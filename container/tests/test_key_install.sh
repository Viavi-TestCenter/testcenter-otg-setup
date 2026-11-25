#!/usr/bin/env bash
# test_key_install.sh - the DUT SSH key install must be append-only-if-missing (proposal §3b item 7):
# running it twice leaves ~/.ssh/authorized_keys byte-identical, the key appears once, other lines keep
# their order, a last line without a trailing newline is not glued onto, and a key whose comment holds
# spaces or a single quote survives the quoting.
#
#   bash container/tests/test_key_install.sh
#
# _dut_key_install_remote_cmd <pubkey> prints the command the DUT's shell runs; it is executed here
# under a throwaway HOME, which is exactly what the remote shell does with it.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../lib/deploy.sh"
fails=0

if ! declare -F _dut_key_install_remote_cmd >/dev/null; then
    echo "FAIL: _dut_key_install_remote_cmd is not defined in lib/deploy.sh"
    exit 1
fi

BLOB='AAAAC3NzaC1lZDI1NTE5AAAAIAbcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH'
KEY_PLAIN="ssh-ed25519 $BLOB admin@sonic-mgmt"
KEY_SPACES="ssh-ed25519 $BLOB admin's laptop (work) \$HOME 2026"
OTHER_A="ssh-rsa AAAAB3NzaC1yc2EAAAAOTHERA first@host command=\"x\""
OTHER_B="ssh-rsa AAAAB3NzaC1yc2EAAAAOTHERB second@host"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

check() {
    local name="$1" ok="$2" detail="${3:-}"
    if [[ "$ok" == "1" ]]; then echo "ok   - $name"; else echo "FAIL - $name ${detail:+($detail)}"; fails=$((fails + 1)); fi
}

# scenario <name> <key> <initial authorized_keys content or "-" for no file> [--no-newline]
scenario() {
    local name="$1" key="$2" initial="$3" nonl="${4:-}"
    local home="$TMP/$(echo "$name" | tr -c 'a-z0-9\n' _)"
    mkdir -p "$home"
    if [[ "$initial" != "-" ]]; then
        mkdir -p "$home/.ssh"
        if [[ "$nonl" == "--no-newline" ]]; then printf '%s' "$initial" > "$home/.ssh/authorized_keys"
        else printf '%s\n' "$initial" > "$home/.ssh/authorized_keys"; fi
    fi
    local cmd; cmd="$(_dut_key_install_remote_cmd "$key")"
    local f="$home/.ssh/authorized_keys"

    HOME="$home" bash -c "$cmd"; local rc1=$?
    local sum1; sum1="$(md5sum "$f" 2>/dev/null | cut -d' ' -f1)"
    HOME="$home" bash -c "$cmd"; local rc2=$?
    local sum2; sum2="$(md5sum "$f" 2>/dev/null | cut -d' ' -f1)"

    check "$name: exits 0 both times" "$([[ $rc1 -eq 0 && $rc2 -eq 0 ]] && echo 1 || echo 0)" "rc=$rc1/$rc2"
    check "$name: second run leaves the file byte-identical" "$([[ -n "$sum1" && "$sum1" == "$sum2" ]] && echo 1 || echo 0)"
    check "$name: key present exactly once" "$([[ "$(grep -cxF -- "$key" "$f")" == "1" ]] && echo 1 || echo 0)" "$(cat "$f" 2>&1 | head -5)"
    check "$name: permissions (~/.ssh 700, file 600)" "$([[ "$(stat -c %a "$home/.ssh")" == "700" && "$(stat -c %a "$f")" == "600" ]] && echo 1 || echo 0)"
    LAST_FILE="$f"
}

scenario "missing file" "$KEY_PLAIN" "-"

scenario "no trailing newline" "$KEY_PLAIN" "$OTHER_A" --no-newline
check "no trailing newline: existing line intact (key not glued onto it)" \
    "$([[ "$(sed -n 1p "$LAST_FILE")" == "$OTHER_A" && "$(sed -n 2p "$LAST_FILE")" == "$KEY_PLAIN" ]] && echo 1 || echo 0)" "$(cat "$LAST_FILE")"

scenario "comment with spaces, quote, parens and dollar" "$KEY_SPACES" "-"
check "comment with spaces: stored verbatim" \
    "$([[ "$(cat "$LAST_FILE")" == "$KEY_SPACES" ]] && echo 1 || echo 0)" "$(cat "$LAST_FILE")"

scenario "key already present between other keys" "$KEY_PLAIN" "$(printf '%s\n%s\n%s' "$OTHER_A" "$KEY_PLAIN" "$OTHER_B")"
check "already present: order of the other entries kept" \
    "$([[ "$(sed -n 1p "$LAST_FILE")" == "$OTHER_A" && "$(sed -n 2p "$LAST_FILE")" == "$KEY_PLAIN" && "$(sed -n 3p "$LAST_FILE")" == "$OTHER_B" && "$(wc -l < "$LAST_FILE")" == "3" ]] && echo 1 || echo 0)" "$(cat "$LAST_FILE")"

scenario "other keys, key missing" "$KEY_PLAIN" "$(printf '%s\n%s' "$OTHER_B" "$OTHER_A")"
check "key missing: appended last, existing order kept (no sort)" \
    "$([[ "$(sed -n 1p "$LAST_FILE")" == "$OTHER_B" && "$(sed -n 2p "$LAST_FILE")" == "$OTHER_A" && "$(sed -n 3p "$LAST_FILE")" == "$KEY_PLAIN" ]] && echo 1 || echo 0)" "$(cat "$LAST_FILE")"

echo
if [[ "$fails" -eq 0 ]]; then echo "ALL PASSED"; else echo "$fails FAILED"; exit 1; fi
