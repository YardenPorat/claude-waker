#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.user.claude"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
CONFIG_FILE="$SCRIPT_DIR/.interval"

INTERVAL_MINUTES="${1:-60}"
SKIP_HOURS="${2:-3,4,5}"
INTERVAL_SECONDS=$((INTERVAL_MINUTES * 60))

# Persist config so claude_sync.sh can read it
echo "$INTERVAL_MINUTES" > "$CONFIG_FILE"
echo "$SKIP_HOURS" > "$SCRIPT_DIR/.skip_hours"

# Unload existing agent if present
launchctl unload "$PLIST_DEST" 2>/dev/null

# Generate plist with the current directory's sync script
cat > "$PLIST_DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DIR/claude_sync.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>$INTERVAL_SECONDS</integer>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

launchctl load "$PLIST_DEST"
echo "Installed and loaded $PLIST_DEST"
echo "Script path: $SCRIPT_DIR/claude_sync.sh"
echo "Interval: every $INTERVAL_MINUTES minutes"
echo "Skip hours: $SKIP_HOURS"

# --- Passwordless sudo for pmset schedule wake --------------------------------
# The sync script schedules the next Mac wake after each run.
# This sudoers rule scopes access to only "pmset schedule wake".
SUDOERS_FILE="/etc/sudoers.d/claude-waker"
if [ ! -f "$SUDOERS_FILE" ]; then
  echo ""
  echo "Setting up passwordless wake scheduling (requires sudo once)..."
  echo "$USER ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake *" | sudo tee "$SUDOERS_FILE" > /dev/null
  sudo chmod 0440 "$SUDOERS_FILE"
  echo "Created $SUDOERS_FILE"
fi

# Remove any old daily pmset repeat (replaced by per-run scheduling)
sudo pmset repeat cancel 2>/dev/null

# Schedule the first wake to kick off the chain
FIRST_WAKE=$(date -v+"${INTERVAL_MINUTES}M" '+%m/%d/%Y %H:%M:%S')
sudo pmset schedule wake "$FIRST_WAKE"
echo "First wake scheduled: $FIRST_WAKE"
