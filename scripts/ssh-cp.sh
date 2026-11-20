#!/usr/bin/env bash
# SSH to the control plane (or run a command there), using the generated inventory.
set -euo pipefail
cd "$(dirname "$0")/.."
val() { awk -F= -v k="$1" '$1==k {print $2}' ansible/inventory.ini; }
exec ssh -i "$(val ansible_ssh_private_key_file)" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  "ubuntu@$(val control_plane_public_ip)" "$@"
