#!/usr/bin/env bash
# PAM attempt audit of THIS tree's shell and security process (read-only; never starts, stops or signals anything).
# Since ADR-0041 step 1, S2 the lock (and its PamContext) lives in the security process (shell/security.qml): its instances
# are counted with the shell's (shell/shell.qml), so an attempt in either is seen.
#
# A password submitted on the lock screen is checked against the owner's real account (PAM service
# omarchy-lock-password) and a wrong one counts a faillock failure shared with sudo. The nested tests must never cause
# one. Every Quickshell instance keeps its own log ($XDG_RUNTIME_DIR/quickshell/by-id/<id>/log.log, kept after the
# instance exits), whose first lines name the config it launched; .dev/shell.log only holds the live instance and is
# overwritten on every restart, and instance.lock is not text (UTF-16), so the per-instance logs are the record.
#
#   tests/security/pam_audit.sh     per-instance counts (instances with an attempt) and the totals
#
# Counted lines: "authenticating (submit)" = a password handed to PAM (a real attempt); "dev: PAM submit suppressed" =
# a key reached the lock field and submitted, but the dev PAM suppression blocked it (no attempt; still a test defect).
# Sourced by tests/security/reload_locked.sh for pam_tree_logs / pam_counts.

pam_audit_root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)

# Log files of every instance (live or exited) that launched this tree's shell/shell.qml or shell/security.qml.
pam_tree_logs() {
  local f ui="Launching config: \"$pam_audit_root/shell/shell.qml\"" sec="Launching config: \"$pam_audit_root/shell/security.qml\""
  for f in "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/quickshell/by-id/*/log.log; do
    [[ -f $f ]] || continue
    head -n 5 "$f" | grep -a -q -F -e "$ui" -e "$sec" && echo "$f"
  done
}

# "<instances> <submits> <suppressed>" summed over every instance log of this tree.
pam_counts() {
  local f n=0 s=0 x=0 a b
  while IFS= read -r f; do
    a=$(grep -a -c "authenticating (submit)" "$f")
    b=$(grep -a -c "dev: PAM submit suppressed" "$f")
    n=$((n + 1)) s=$((s + a)) x=$((x + b))
  done < <(pam_tree_logs)
  echo "$n $s $x"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  set -uo pipefail
  total_n=0 total_s=0 total_x=0
  while IFS= read -r f; do
    a=$(grep -a -c "authenticating (submit)" "$f")
    b=$(grep -a -c "dev: PAM submit suppressed" "$f")
    total_n=$((total_n + 1)) total_s=$((total_s + a)) total_x=$((total_x + b))
    if ((a > 0 || b > 0)); then
      id=$(basename "$(dirname "$f")")
      echo "$id started $(head -n 1 "$f" | cut -c1-19): PAM submits $a, suppressed $b"
    fi
  done < <(pam_tree_logs)
  echo "pam_audit: $total_n instance logs of $pam_audit_root/shell (shell.qml and security.qml); PAM submits $total_s; suppressed $total_x"
fi
