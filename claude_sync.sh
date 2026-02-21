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

run_sync() {
  echo "--- SYNC CHECK: $(date) ---"

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
    osascript -e 'display notification "New Claude Session Started!" with title "Claude Sync"'
  fi

  # ---- Schedule next wake -----------------------------------------------------
  # Each run schedules the Mac to wake at the configured interval, forming a
  # self-sustaining chain. Requires the passwordless sudoers rule created by install.sh.
  local INTERVAL_MINUTES=60
  [ -f "$SCRIPT_DIR/.interval" ] && INTERVAL_MINUTES=$(cat "$SCRIPT_DIR/.interval")
  NEXT_WAKE=$(date -v+"${INTERVAL_MINUTES}M" '+%m/%d/%Y %H:%M:%S')
  if sudo pmset schedule wake "$NEXT_WAKE" 2>/dev/null; then
    echo "Next wake scheduled: $NEXT_WAKE"
  else
    echo "WARN: Failed to schedule next wake (run install.sh to fix sudoers)"
  fi

  echo "--- SYNC END: $(date) ---"
  echo ""
}

run_sync 2>&1 | tee -a "$LOG"
