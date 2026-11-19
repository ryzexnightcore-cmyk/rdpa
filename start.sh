#!/bin/bash
# Usage: bash mac/start.sh <NGROK_AUTH_TOKEN>
# Sets up VNC (Screen Sharing) on a GitHub macOS runner and tunnels it through ngrok.

NGROK_TOKEN="$1"
USER_NAME="runneradmin"
USER_PASS='P@ssw0rd!'
# Legacy VNC passwords are limited to 8 characters.
VNC_PASS='P@ssw0rd'
KICKSTART=/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart

#--- Keep the display awake (a sleeping display is the #1 cause of a black VNC screen)
sudo pmset -a displaysleep 0 sleep 0 disksleep 0 powernap 0 2>/dev/null || true
sudo pmset -a disablesleep 1 2>/dev/null || true
nohup caffeinate -dimsu >/dev/null 2>&1 &
# Disable screensaver / login-window idle so the session never blanks
sudo defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime 0 2>/dev/null || true
defaults -currentHost write com.apple.screensaver idleTime 0 2>/dev/null || true
defaults write com.apple.screensaver askForPassword -int 0 2>/dev/null || true

#--- Disable spotlight indexing
sudo mdutil -i off -a >/dev/null 2>&1 || true

#--- Create new admin account
# (NFSHomeDirectory previously pointed at /Users/tcv, which is wrong.)
if ! id "$USER_NAME" >/dev/null 2>&1; then
  sudo dscl . -create /Users/$USER_NAME
  sudo dscl . -create /Users/$USER_NAME UserShell /bin/bash
  sudo dscl . -create /Users/$USER_NAME RealName Runner_Admin
  sudo dscl . -create /Users/$USER_NAME UniqueID 1001
  sudo dscl . -create /Users/$USER_NAME PrimaryGroupID 80
  sudo dscl . -create /Users/$USER_NAME NFSHomeDirectory /Users/$USER_NAME
  sudo dscl . -passwd /Users/$USER_NAME "$USER_PASS"
  sudo createhomedir -c -u $USER_NAME >/dev/null 2>&1 || true
  sudo dscl . -append /Groups/admin GroupMembership $USER_NAME
fi

#--- Skip the Setup Assistant / "Sign in to Apple Account" screens
sudo touch /var/db/.AppleSetupDone
for h in /Users/$USER_NAME /Users/runner "$HOME"; do
  [ -d "$h" ] || continue
  o=$(stat -f %Su "$h")
  sudo -u "$o" defaults write "$h/Library/Preferences/com.apple.SetupAssistant" DidSeeCloudSetup -bool true 2>/dev/null || true
  sudo -u "$o" defaults write "$h/Library/Preferences/com.apple.SetupAssistant" DidSeeSiriSetup -bool true 2>/dev/null || true
  sudo -u "$o" defaults write "$h/Library/Preferences/com.apple.SetupAssistant" DidSeeAccessibility -bool true 2>/dev/null || true
  sudo -u "$o" defaults write "$h/Library/Preferences/com.apple.SetupAssistant" LastSeenCloudProductVersion "$(sw_vers -productVersion)" 2>/dev/null || true
done

#--- Grant Screen Recording / Accessibility to the screen sharing agents.
# Without this the VNC session connects but only shows a black screen on newer macOS.
# Best effort: only works if the TCC database is writable on the image.
TCC_DB="/Library/Application Support/com.apple.TCC/TCC.db"
NOW=$(date +%s)
for client in com.apple.screensharing.agent com.apple.screensharing.launchd com.apple.ScreenSharing com.apple.RemoteDesktop.agent; do
  for svc in kTCCServiceScreenCapture kTCCServiceAccessibility kTCCServicePostEvent; do
    sudo sqlite3 "$TCC_DB" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags, last_modified) VALUES ('$svc','$client',0,2,4,1,0,$NOW);" 2>/dev/null || true
  done
done

#--- Enable VNC (legacy VNC password so any VNC client can connect)
sudo $KICKSTART -activate -configure -access -on \
  -clientopts -setvnclegacy -vnclegacy yes \
  -clientopts -setvncpw -vncpw "$VNC_PASS" \
  -restart -agent -privs -all

# Restart the screen sharing daemon so it picks up the TCC changes
sudo killall screensharingd 2>/dev/null || true
sudo launchctl kickstart -k system/com.apple.screensharing 2>/dev/null || true
sudo $KICKSTART -restart -agent -console

#--- Wake the display once more now that everything is up
caffeinate -u -t 5 >/dev/null 2>&1 || true

#--- Browser that works on a GPU-less VM (Safari renders blank pages here)
brew install --cask google-chrome || true
# Launcher: open "Chrome-NoGPU" from Spotlight / use: open -a "Google Chrome" --args --disable-gpu
mkdir -p "$HOME/Desktop"
cat > "$HOME/Desktop/Chrome-NoGPU.command" <<'CMD'
#!/bin/bash
open -a "Google Chrome" --args --disable-gpu --disable-software-rasterizer --no-first-run --no-default-browser-check
CMD
chmod +x "$HOME/Desktop/Chrome-NoGPU.command"

#--- Install ngrok, configure and start it
brew install --cask ngrok
ngrok config add-authtoken "$NGROK_TOKEN" 2>/dev/null || ngrok authtoken "$NGROK_TOKEN"
nohup ngrok tcp 5900 --region=in --log=stdout > ngrok.log 2>&1 &
