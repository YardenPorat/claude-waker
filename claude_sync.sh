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
# schedule_all_wakes
#   Schedules the Mac to wake at EVERY active hour for the rest of today and
#   all of tomorrow. This "shotgun" approach is far more reliable than a
#   single one-shot wake — if one pmset event fails, the next one still fires.
# ---------------------------------------------------------------------------
schedule_all_wakes() {
  local INTERVAL_MINUTES=60
  [ -f "$SCRIPT_DIR/.interval" ] && INTERVAL_MINUTES=$(cat "$SCRIPT_DIR/.interval")
  local SKIP_HOURS=""
  [ -f "$SCRIPT_DIR/.skip_hours" ] && SKIP_HOURS=$(cat "$SCRIPT_DIR/.skip_hours")

  local TODAY=$(date '+%m/%d/%Y')
  local TOMORROW=$(date -v+1d '+%m/%d/%Y')
  local NOW_MINUTES=$(( $(date '+%-H') * 60 + $(date '+%-M') ))
  local scheduled=0

  # Generate wake times at every INTERVAL_MINUTES within each active hour.
  # e.g. interval=30 → 06:00, 06:30, 07:00, 07:30, …, 18:00, 18:30
  for h in $(seq 0 23); do
    if [ -n "$SKIP_HOURS" ] && echo ",$SKIP_HOURS," | grep -q ",$h,"; then
      continue
    fi

    local m=0
    while [ "$m" -lt 60 ]; do
      local TIME=$(printf "%02d:%02d:00" "$h" "$m")
      local SLOT_MINUTES=$(( h * 60 + m ))

      # Schedule remaining slots today (only future times)
      if [ "$SLOT_MINUTES" -gt "$NOW_MINUTES" ]; then
        sudo pmset schedule wake "$TODAY $TIME" 2>/dev/null
        sudo pmset schedule poweron "$TODAY $TIME" 2>/dev/null
        scheduled=$((scheduled + 1))
      fi

      # Always schedule all slots tomorrow
      sudo pmset schedule wake "$TOMORROW $TIME" 2>/dev/null
      sudo pmset schedule poweron "$TOMORROW $TIME" 2>/dev/null
      scheduled=$((scheduled + 1))

      m=$((m + INTERVAL_MINUTES))
    done
  done

  echo "Scheduled $scheduled wake events every ${INTERVAL_MINUTES}m during active hours (today + tomorrow)"
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
      schedule_all_wakes
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
    UI_STATUS=$(echo "$CLEAN_OUTPUT" | grep -iE "% used|resets " | xargs)
    echo "Scraped Status: $UI_STATUS"
  
  if echo "$CLEAN_OUTPUT" | grep -iqE "resets"; then
    echo "✅ Active session detected. Skipping ping."
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
  schedule_all_wakes

  echo "--- SYNC END: $(date) ---"
  echo ""
}

run_sync 2>&1 | tee -a "$LOG"
