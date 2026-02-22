#!/bin/bash

# launchd uses a minimal PATH that excludes Homebrew — add it explicitly.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$SCRIPT_DIR/claude_sync.log"
CURRENT_USER=$(whoami)
CLAUDE_BIN="/Users/$CURRENT_USER/.local/bin/claude"

# ---------------------------------------------------------------------------
# wait_for SESSION PATTERN TIMEOUT_SECS
#   Polls tmux capture-pane every 0.5 s until PATTERN (extended regex, case-
#   insensitive) appears on screen, or TIMEOUT_SECS is exceeded.
#   Returns 0 on match, 1 on timeout.
# ---------------------------------------------------------------------------
wait_for() {
  local session="$1" pattern="$2" timeout="$3"
  local attempts=$(( timeout * 2 ))  # 2 checks per second
  local i=0
  while [ "$i" -lt "$attempts" ]; do
    if tmux capture-pane -t "$session" -p 2>/dev/null | grep -qiE "$pattern"; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# schedule_next_wake
#   Schedules the Mac to wake at the next non-skipped interval.
#   If the computed wake time lands in a skip hour, keeps advancing by
#   INTERVAL_MINUTES until it finds an allowed hour.
# ---------------------------------------------------------------------------
schedule_next_wake() {
  if [ ! -f "$SCRIPT_DIR/.interval" ]; then
    echo "WARN: .interval not found — run install.sh first. Skipping wake schedule."
    return
  fi

  local INTERVAL_MINUTES=$(cat "$SCRIPT_DIR/.interval")
  local SKIP_HOURS=""
  [ -f "$SCRIPT_DIR/.skip_hours" ] && SKIP_HOURS=$(cat "$SCRIPT_DIR/.skip_hours")

  local OFFSET_MINUTES=$INTERVAL_MINUTES
  while true; do
    local WAKE_HOUR=$(date -v+"${OFFSET_MINUTES}M" '+%-H')
    # If no skip hours configured, or this hour is allowed, use it
    if [ -z "$SKIP_HOURS" ] || ! echo ",$SKIP_HOURS," | grep -q ",$WAKE_HOUR,"; then
      break
    fi
    OFFSET_MINUTES=$((OFFSET_MINUTES + INTERVAL_MINUTES))
    # Safety: don't loop more than 24 hours ahead
    if [ "$OFFSET_MINUTES" -gt 1440 ]; then
      echo "WARN: Could not find a non-skipped hour within 24 h"
      return
    fi
  done

  NEXT_WAKE=$(date -v+"${OFFSET_MINUTES}M" '+%m/%d/%Y %H:%M:%S')
  if sudo pmset schedule poweron "$NEXT_WAKE" 2>/dev/null; then
    echo "Next wake scheduled: $NEXT_WAKE"
  else
    echo "WARN: Failed to schedule next wake (run install.sh to fix sudoers)"
  fi
}

run_sync() {
  echo "--- SYNC CHECK: $(date) ---"

  # ---- Skip hours ------------------------------------------------------------
  # .skip_hours contains comma-separated 24h hours (e.g. "3,4,5").
  # If the current hour is in the list, skip this run but still schedule wake.
  if [ -f "$SCRIPT_DIR/.skip_hours" ]; then
    local CURRENT_HOUR=$(date +%-H)
    local SKIP_HOURS=$(cat "$SCRIPT_DIR/.skip_hours")
    if echo ",$SKIP_HOURS," | grep -q ",$CURRENT_HOUR,"; then
      echo "Skipping — hour $CURRENT_HOUR is in skip list ($SKIP_HOURS)"
      schedule_next_wake
      echo "--- SYNC END: $(date) ---"
      echo ""
      return
    fi
  fi

  if [ ! -x "$CLAUDE_BIN" ]; then
    echo "ERROR: Binary not found at $CLAUDE_BIN"
    return 1
  fi

  if ! command -v tmux &>/dev/null; then
    echo "ERROR: tmux is required (brew install tmux)"
    return 1
  fi

  local SESSION="cw-$$"
  echo "Spawning tmux session '$SESSION'..."

  # 200×50 gives React Ink enough columns to fully render its panels.
  tmux new-session -d -s "$SESSION" -x 200 -y 50 || {
    echo "ERROR: Failed to create tmux session"
    return 1
  }

  # CLAUDECODE= prevents the "nested session" refusal.
  tmux send-keys -t "$SESSION" "CLAUDECODE= $CLAUDE_BIN" Enter

  # ---- Wait for boot ---------------------------------------------------------
  # Claude shows either the REPL prompt (❯) or a trust dialog ("quick safety").
  if ! wait_for "$SESSION" "❯|quick|safety" 15; then
    echo "ERROR: Claude failed to start within 15 s"
    tmux kill-session -t "$SESSION" 2>/dev/null
    return 1
  fi

  # ---- Trust dialog ----------------------------------------------------------
  if tmux capture-pane -t "$SESSION" -p 2>/dev/null | grep -qi "quick\|safety"; then
    echo "Trust dialog detected — confirming..."
    wait_for "$SESSION" "Enter.*confirm" 5
    tmux send-keys -t "$SESSION" "" Enter
    if ! wait_for "$SESSION" "❯" 10; then
      echo "ERROR: REPL prompt never appeared after trust confirmation"
      tmux kill-session -t "$SESSION" 2>/dev/null
      return 1
    fi
  fi

  # ---- Issue /usage ----------------------------------------------------------
  # Autocomplete intercepts the first Enter (selects the suggestion).
  # A second Enter after a short pause actually submits the command.
  tmux send-keys -t "$SESSION" "/usage" Enter
  sleep 0.5
  tmux send-keys -t "$SESSION" Enter

  # Poll for the stats panel instead of a fixed 10 s sleep.
  # The API round-trip is usually 2–4 s; 20 s timeout is generous.
  if ! wait_for "$SESSION" "% used|resets " 20; then
    echo "WARN: /usage stats did not appear within 20 s"
  fi

  # ---- Capture ---------------------------------------------------------------
  # -p   → stdout
  # -S - → full scrollback (catches panels that may have scrolled up)
  # no -e → plain text, no ANSI stripping needed
  CLEAN_OUTPUT=$(tmux capture-pane -t "$SESSION" -p -S - 2>/dev/null)

  # ---- Cleanup ---------------------------------------------------------------
  # We already have the capture — just kill the session, no graceful exit needed.
  tmux kill-session -t "$SESSION" 2>/dev/null

  echo "Captured ${#CLEAN_OUTPUT} chars of screen history"

  # ---- Detect active session -------------------------------------------------
  # The /usage panel shows lines like:
  #   "34% used"             → active session with usage data
  #   "Resets 12pm (tz)"     → when the window resets
  if echo "$CLEAN_OUTPUT" | grep -iqE "% used|resets "; then
    echo "✅ Active session detected. Skipping ping."
    UI_STATUS=$(echo "$CLEAN_OUTPUT" | grep -iE "% used|resets " | xargs)
    echo "Scraped Status: $UI_STATUS"
  else
    echo "❌ No active session found. Triggering 'Hi' ping..."

    caffeinate -i bash -c "
      cd /tmp
      echo 'Hi' | $CLAUDE_BIN
    " &

    CPID=$!
    echo "Claude process started (PID: $CPID). Syncing..."
    sleep 30
    kill -9 $CPID > /dev/null 2>&1

    echo "Sync process complete."
  fi

  # ---- Schedule next wake -----------------------------------------------------
  schedule_next_wake

  echo "--- SYNC END: $(date) ---"
  echo ""
}

run_sync 2>&1 | tee -a "$LOG"
