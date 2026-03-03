#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.user.claude"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
CONFIG_FILE="$SCRIPT_DIR/.interval"

INTERVAL_MINUTES="${1:-60}"
SKIP_HOURS="${2:-0,1,2,3,4,5,19,20,21,22,23}"  # Default: skip 7pm-6am
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

# --- Passwordless sudo for pmset schedule/repeat ------------------------------
# The sync script schedules the next Mac wake after each run.
# This sudoers rule scopes access to pmset schedule and repeat commands.
SUDOERS_FILE="/etc/sudoers.d/claude-waker"
echo ""
echo "Setting up passwordless wake scheduling (requires sudo once)..."
echo "$USER ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake *, /usr/bin/pmset schedule poweron *, /usr/bin/pmset repeat cancel, /usr/bin/pmset repeat wakeorpoweron *" | sudo tee "$SUDOERS_FILE" > /dev/null
sudo chmod 0440 "$SUDOERS_FILE"
echo "Created $SUDOERS_FILE"

# --- Daily failsafe wake via pmset repeat ------------------------------------
# pmset schedule (one-shot) is unreliable on Apple Silicon. Set a recurring
# daily wake at the first non-skip hour as a safety net.
FIRST_ACTIVE_HOUR=""
for h in $(seq 0 23); do
  if [ -z "$SKIP_HOURS" ] || ! echo ",$SKIP_HOURS," | grep -q ",$h,"; then
    FIRST_ACTIVE_HOUR=$h
    break
  fi
done

if [ -n "$FIRST_ACTIVE_HOUR" ]; then
  REPEAT_TIME=$(printf "%02d:00:00" "$FIRST_ACTIVE_HOUR")
  sudo pmset repeat cancel 2>/dev/null
  sudo pmset repeat wakeorpoweron MTWRFSU "$REPEAT_TIME"
  echo "Daily failsafe wake set: every day at $REPEAT_TIME"
else
  echo "WARN: All 24 hours are skipped — no daily repeat wake set"
  sudo pmset repeat cancel 2>/dev/null
fi

# --- Disable deep standby for reliable wake -----------------------------------
# Apple Silicon in deep standby ignores pmset wake events. Save the original
# value so reset.sh can restore it, then disable standby.
ORIG_STANDBY=$(pmset -g | awk '/^ standby /{print $2}')
echo "$ORIG_STANDBY" > "$SCRIPT_DIR/.standby_original"
sudo pmset -a standby 0
echo "Disabled deep standby (was: ${ORIG_STANDBY:-unknown})"

# Schedule wakes at fixed intervals during active hours (today + tomorrow)
echo ""
echo "Scheduling wakes every ${INTERVAL_MINUTES}m during active hours..."
TODAY=$(date '+%m/%d/%Y')
TOMORROW=$(date -v+1d '+%m/%d/%Y')
NOW_MINUTES=$(( $(date '+%-H') * 60 + $(date '+%-M') ))
SCHEDULED=0
for h in $(seq 0 23); do
  if [ -z "$SKIP_HOURS" ] || ! echo ",$SKIP_HOURS," | grep -q ",$h,"; then
    m=0
    while [ "$m" -lt 60 ]; do
      TIME=$(printf "%02d:%02d:00" "$h" "$m")
      SLOT_MINUTES=$(( h * 60 + m ))
      if [ "$SLOT_MINUTES" -gt "$NOW_MINUTES" ]; then
        sudo pmset schedule wake "$TODAY $TIME" 2>/dev/null
        sudo pmset schedule poweron "$TODAY $TIME" 2>/dev/null
        SCHEDULED=$((SCHEDULED + 1))
      fi
      sudo pmset schedule wake "$TOMORROW $TIME" 2>/dev/null
      sudo pmset schedule poweron "$TOMORROW $TIME" 2>/dev/null
      SCHEDULED=$((SCHEDULED + 1))
      m=$((m + INTERVAL_MINUTES))
    done
  fi
done
echo "Scheduled $SCHEDULED wake events at fixed intervals"
