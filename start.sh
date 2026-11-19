#!/usr/bin/env bash
set -Eeuo pipefail

# macOS GitHub-hosted runners already have a logged-in runner account.
# Do not create a second account or overwrite system account IDs.

if [[ -z "${NGROK_AUTH_TOKEN:-}" ]]; then
  echo "::error::NGROK_AUTH_TOKEN is empty. Add it as a GitHub Actions repository secret."
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "::error::Homebrew is not available on this runner."
  exit 1
fi

if ! command -v ngrok >/dev/null 2>&1; then
  brew install --cask ngrok
fi

# Generate an unpredictable 8-character VNC password.
# Traditional VNC password authentication only uses the first 8 characters.
VNC_PASSWORD="$(openssl rand -hex 4)"
echo "::add-mask::$VNC_PASSWORD"

# Configure Apple Remote Management / VNC.
ARD_KICKSTART="/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart"
if [[ ! -x "$ARD_KICKSTART" ]]; then
  echo "::error::Apple Remote Management kickstart utility was not found."
  exit 1
fi

sudo "$ARD_KICKSTART" -activate \
  -configure -allowAccessFor -allUsers -privs -all

sudo "$ARD_KICKSTART" -configure -clientopts \
  -setvnclegacy -vnclegacy yes

# Store the legacy VNC password in Apple's expected encrypted format.
printf '%s\n' "$VNC_PASSWORD" |
  perl -we '
    BEGIN { @k = unpack "C*", pack "H*", "1734516E8BA8C5E2FF1C39567390ADCA" }
    $_ = <>;
    chomp;
    s/^(.{8}).*/$1/;
    @p = unpack "C*", $_;
    foreach (@k) { printf "%02X", $_ ^ (shift @p || 0) }
    print "\n";
  ' | sudo tee /Library/Preferences/com.apple.VNCSettings.txt >/dev/null

sudo "$ARD_KICKSTART" -restart -agent
sudo "$ARD_KICKSTART" -activate

# Wait until the local VNC service is listening before opening the tunnel.
for attempt in {1..30}; do
  if nc -z 127.0.0.1 5900; then
    break
  fi
  sleep 2
done

if ! nc -z 127.0.0.1 5900; then
  echo "::error::VNC is not listening on localhost:5900. Check the runner's GUI/Remote Management availability."
  exit 1
fi

ngrok config add-authtoken "$NGROK_AUTH_TOKEN"

# Run ngrok in the background; the workflow's keep-alive step keeps the job alive.
nohup ngrok tcp 5900 --log=stdout > "$RUNNER_TEMP/ngrok.log" 2>&1 &
echo $! > "$RUNNER_TEMP/ngrok.pid"

# Wait for ngrok's local API to report the public TCP endpoint.
for attempt in {1..30}; do
  if curl -fsS http://127.0.0.1:4040/api/tunnels >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

TUNNEL_URL="$(python3 - <<'PY'
import json, urllib.request
try:
    with urllib.request.urlopen("http://127.0.0.1:4040/api/tunnels", timeout=3) as r:
        data = json.load(r)
    for tunnel in data.get("tunnels", []):
        url = tunnel.get("public_url", "")
        if url.startswith("tcp://"):
            print(url)
            break
except Exception:
    pass
PY
)"

if [[ -z "$TUNNEL_URL" ]]; then
  echo "::error::ngrok did not create a TCP tunnel. See the ngrok log in the job output."
  tail -n 80 "$RUNNER_TEMP/ngrok.log" || true
  exit 1
fi

{
  echo "## macOS VNC connection"
  echo
  echo "- **VNC address:** \`$TUNNEL_URL\`"
  echo "- **VNC username:** Not required by legacy VNC authentication"
  echo "- **VNC password:** \`$VNC_PASSWORD\`"
  echo
  echo "> Security: this is a temporary public TCP endpoint. Keep the repository private, do not share the workflow logs, and stop the workflow when finished."
} >> "$GITHUB_STEP_SUMMARY"

echo "VNC tunnel: $TUNNEL_URL"
echo "VNC password: $VNC_PASSWORD"
echo "The VNC password is masked in subsequent GitHub Actions log output."
