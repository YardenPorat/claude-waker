#!/bin/bash
# Undo everything install.sh sets up.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.user.claude"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"
SUDOERS_FILE="/etc/sudoers.d/claude-waker"

echo "Resetting claude-waker..."

# --- Unload and remove LaunchAgent -------------------------------------------
if [ -f "$PLIST_DEST" ]; then
  launchctl unload "$PLIST_DEST" 2>/dev/null
  rm -f "$PLIST_DEST"
  echo "Removed LaunchAgent: $PLIST_DEST"
else
  echo "LaunchAgent not found (already removed)"
fi

# --- Cancel pmset repeat wake ------------------------------------------------
sudo pmset repeat cancel 2>/dev/null
echo "Cancelled pmset repeat wake"

# --- Restore original hibernatemode & standby ---------------------------------
if [ -f "$SCRIPT_DIR/.hibernatemode_original" ]; then
  ORIG_HIBERNATE=$(cat "$SCRIPT_DIR/.hibernatemode_original")
  if [ -n "$ORIG_HIBERNATE" ]; then
    sudo pmset -a hibernatemode "$ORIG_HIBERNATE"
    echo "Restored hibernatemode to: $ORIG_HIBERNATE"
  fi
else
  sudo pmset -a hibernatemode 3
  echo "Restored hibernatemode to default: 3"
fi

if [ -f "$SCRIPT_DIR/.standby_original" ]; then
  ORIG_STANDBY=$(cat "$SCRIPT_DIR/.standby_original")
  if [ -n "$ORIG_STANDBY" ]; then
    sudo pmset -a standby "$ORIG_STANDBY"
    echo "Restored standby to: $ORIG_STANDBY"
  fi
else
  sudo pmset -a standby 1
  echo "Restored standby to default: 1"
fi

# --- Remove sudoers entry ----------------------------------------------------
if [ -f "$SUDOERS_FILE" ]; then
  sudo rm -f "$SUDOERS_FILE"
  echo "Removed sudoers file: $SUDOERS_FILE"
else
  echo "Sudoers file not found (already removed)"
fi

# --- Remove config files -----------------------------------------------------
rm -f "$SCRIPT_DIR/.interval" "$SCRIPT_DIR/.skip_hours" "$SCRIPT_DIR/.standby_original" "$SCRIPT_DIR/.hibernatemode_original"
echo "Removed config files"

echo ""
echo "claude-waker has been fully reset."
echo "Note: existing pmset schedule events will expire on their own."
echo "Log file kept at: $SCRIPT_DIR/claude_sync.log"
