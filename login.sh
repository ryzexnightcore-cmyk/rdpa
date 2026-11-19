#!/usr/bin/env bash
set -Eeuo pipefail

echo "Checking ngrok tunnel..."
curl -fsS http://127.0.0.1:4040/api/tunnels | python3 -c '
import json, sys
data = json.load(sys.stdin)
for tunnel in data.get("tunnels", []):
    url = tunnel.get("public_url", "")
    if url.startswith("tcp://"):
        print("VNC address:", url)
'
