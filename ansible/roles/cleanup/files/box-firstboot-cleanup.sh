#!/usr/bin/env bash
set -euo pipefail

marker="/var/lib/box-firstboot-cleanup.done"

if [[ -f "$marker" ]]; then
  exit 0
fi

# Clean temporary directories (safe to run at first boot).
rm -rf /tmp/* /var/tmp/* || true

# Ensure correct perms on /tmp.
chmod 1777 /tmp || true

# Mark done.
install -d -m 0755 /var/lib || true
: > "$marker"
