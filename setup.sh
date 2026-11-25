#!/usr/bin/env bash
# setup.sh has been replaced by deploy/install.sh (host setup) + deploy/marine-apply (config).
# Kept as a thin shim so old habits and docs still work.
set -euo pipefail
echo "setup.sh is superseded: running deploy/install.sh" >&2
echo "Secrets now live in /etc/marine/marine.env (see marine.env.example), not in the repo checkout." >&2
exec "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/deploy/install.sh" "$@"
