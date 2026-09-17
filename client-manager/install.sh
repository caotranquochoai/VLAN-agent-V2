#!/usr/bin/env bash
set -euo pipefail
chmod +x ./proxy-client-manager || true
chmod +x ./bin/bridge_linux || true
mkdir -p ./data
cat <<INFO
Installed client-manager package.
Run:
  ./proxy-client-manager serve --host 0.0.0.0 --port 8090
INFO
