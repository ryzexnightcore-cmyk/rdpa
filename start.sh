
#!/usr/bin/env bash
set -Eeuo pipefail

# Check required secret
if [[ -z "${NGROK_AUTH_TOKEN:-}" ]]; then
  echo "::error::NGROK_AUTH_TOKEN is missing"
  exit 1
fi

# Check Homebrew
if ! command -v brew >/dev/null 2>&1; then
  echo "::error::Homebrew is unavailable"
  exit 1
fi

# Install ngrok
if ! command -v ngrok >/dev/null 2>&1; then
  brew install ngrok
fi

# Generate VNC password
VNC_PASSWORD="$(openssl rand -hex 4)"

# Share password with subsequent GitHub Actions steps
echo "VNC_PASSWORD=$VNC_PASSWORD" >> "$GITHUB_ENV"

# Configure Apple Remote Desktop
ARD_KICKSTART="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"

if [[ ! -x "$ARD_KICKSTART" ]]; then
  echo "::error::ARDAgent kickstart not found"
  exit 1
fi

sudo "$ARD_KICKSTART" \
  -activate \
  -configure \
  -allowAccessFor -allUsers \
  -privs -all

sudo "$ARD_KICKSTART" \
  -configure \
  -clientopts \
  -setvnclegacy \
  -vnclegacy yes

# Configure VNC legacy password
printf '%s\n' "$VNC_PASSWORD" |
  perl -we '
    BEGIN {
      @k = unpack "C*", pack "H*",
      "1734516E8BA8C5E2FF1C39567390ADCA"
    }
    $_ = <>;
    chomp;
    s/^(.{8}).*/$1/;
    @p = unpack "C*", $_;
    foreach (@k) {
      printf "%02X", $_ ^ (shift @p || 0)
    }
    print "\n";
  ' | sudo tee /Library/Preferences/com.apple.VNCSettings.txt >/dev/null

# Restart Remote Management
sudo "$ARD_KICKSTART" -restart -agent
sudo "$ARD_KICKSTART" -activate

# Check VNC port
echo "Waiting for VNC server..."

VNC_READY=false

for attempt in {1..30}; do
  if nc -z 127.0.0.1 5900; then
    VNC_READY=true
    break
  fi
  sleep 2
done

if [[ "$VNC_READY" != true ]]; then
  echo "::error::VNC server is not listening on port 5900"
  exit 1
fi

echo "VNC server is listening."

# Configure ngrok
ngrok config add-authtoken "$NGROK_AUTH_TOKEN"

# Start ngrok
nohup ngrok tcp 5900 --log=stdout \
  > "$RUNNER_TEMP/ngrok.log" 2>&1 &

echo $! > "$RUNNER_TEMP/ngrok.pid"

# Wait for ngrok API
TUNNEL_URL=""

for attempt in {1..30}; do
  TUNNEL_URL="$(python3 - <<'PY'
import json
import urllib.request

try:
    with urllib.request.urlopen(
        "http://127.0.0.1:4040/api/tunnels",
        timeout=3
    ) as response:
        data = json.load(response)

    for tunnel in data.get("tunnels", []):
        url = tunnel.get("public_url", "")
        if url.startswith("tcp://"):
            print(url)
            break
except Exception:
    pass
PY
)"

  if [[ -n "$TUNNEL_URL" ]]; then
    break
  fi

  sleep 2
done

if [[ -z "$TUNNEL_URL" ]]; then
  echo "::error::ngrok tunnel failed"
  tail -n 80 "$RUNNER_TEMP/ngrok.log" || true
  exit 1
fi

# Export tunnel address for next steps
echo "TUNNEL_URL=$TUNNEL_URL" >> "$GITHUB_ENV"

# Add connection details to workflow summary
{
  echo "## MacRDP Connection"
  echo
  echo "**VNC Address:** $TUNNEL_URL"
  echo
  echo "**VNC Username:** Not required"
  echo
  echo "**VNC Password:** $VNC_PASSWORD"
} >> "$GITHUB_STEP_SUMMARY"

echo "=================================="
echo "       MAC RDP CONNECTION"
echo "=================================="
echo "VNC Address: $TUNNEL_URL"
echo "VNC Username: Not required"
echo "VNC Password: $VNC_PASSWORD"
echo "=================================="
