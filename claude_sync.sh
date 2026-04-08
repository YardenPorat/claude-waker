#!/bin/bash
#
# claude_sync.sh — Periodically checks Claude Code session status and keeps it alive.
#
# Launched by launchd (com.user.claude) at a fixed interval (default: 30 min).
# Each run:
#   1. Skips if the current hour is outside active hours (.skip_hours).
#   2. Opens Claude Code in a headless tmux session and runs /usage.
#   3. If an active session exists (usage shows "Resets …"), does nothing.
#      Otherwise, sends a "Hi" ping to start a new session.
#   4. Schedules pmset wake events for the next two days (safety net for
#      overnight→morning transition).
#   5. Keeps the Mac awake via caffeinate until active hours end, so launchd
#      fires reliably without depending on flaky pmset wakes mid-day.
#

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
#   Schedules the Mac to wake via pmset at every interval slot during active
#   hours, for the rest of today and all of tomorrow. Both "wake" (from sleep)
#   and "poweron" (from shutdown) events are set for each slot.
#
#   This "shotgun" approach is a safety net — the primary mechanism for staying
#   awake during the day is caffeinate (see run_sync). These pmset events mainly
#   matter for the overnight→morning transition when the Mac is actually asleep
#   and caffeinate isn't running.
#
#   Events accumulate across runs (pmset doesn't deduplicate), but expired
#   events are cleaned up automatically by macOS.
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

  for h in $(seq 0 23); do
    # Skip inactive hours
    if [ -n "$SKIP_HOURS" ] && echo ",$SKIP_HOURS," | grep -q ",$h,"; then
      continue
    fi

    local m=0
    while [ "$m" -lt 60 ]; do
      local TIME=$(printf "%02d:%02d:00" "$h" "$m")
      local SLOT_MINUTES=$(( h * 60 + m ))

      # Today: only schedule future time slots
      if [ "$SLOT_MINUTES" -gt "$NOW_MINUTES" ]; then
        sudo pmset schedule wake "$TODAY $TIME" 2>/dev/null
        sudo pmset schedule poweron "$TODAY $TIME" 2>/dev/null
        scheduled=$((scheduled + 1))
      fi

      # Tomorrow: schedule all active slots
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
  # .skip_hours is a comma-separated list of 24h hours to skip (e.g. "0,1,2,3").
  # During skip hours we don't launch Claude, but we still keep the Mac awake
  # via caffeinate so that launchd fires reliably at the start of active hours.
  # (Apple Silicon ignores pmset schedule wakes from deep sleep.)
  if [ -f "$SCRIPT_DIR/.skip_hours" ]; then
    local CURRENT_HOUR=$(date +%-H)
    local SKIP_HOURS=$(cat "$SCRIPT_DIR/.skip_hours")
    if echo ",$SKIP_HOURS," | grep -q ",$CURRENT_HOUR,"; then
      echo "Skipping — hour $CURRENT_HOUR is in skip list ($SKIP_HOURS)"

      # Find hours until the next active hour and caffeinate through the gap.
      # Add one full interval as buffer so the Mac stays awake long enough for
      # launchd's first active-hours tick (its 30m clock may not align to :00).
      local NEXT_ACTIVE_SECS=""
      local INTERVAL_MINUTES=60
      [ -f "$SCRIPT_DIR/.interval" ] && INTERVAL_MINUTES=$(cat "$SCRIPT_DIR/.interval")
      for h in $(seq $((CURRENT_HOUR + 1)) 47); do
        local check_h=$((h % 24))
        if ! echo ",$SKIP_HOURS," | grep -q ",$check_h,"; then
          local CURRENT_M=$(date +%-M)
          local HOURS_AHEAD=$(( h - CURRENT_HOUR ))
          NEXT_ACTIVE_SECS=$(( HOURS_AHEAD * 3600 - CURRENT_M * 60 + (INTERVAL_MINUTES + 2) * 60 ))
          break
        fi
      done

      if [ -n "$NEXT_ACTIVE_SECS" ]; then
        pkill -f "caffeinate -s -t" 2>/dev/null
        caffeinate -s -t "$NEXT_ACTIVE_SECS" >/dev/null 2>&1 &
        echo "caffeinate: preventing sleep for $((NEXT_ACTIVE_SECS / 60))m until active hours (PID: $!)"
      fi

      schedule_all_wakes
      echo "--- SYNC END: $(date) ---"
      echo ""
      return
    fi
  fi

  # ---- Preflight checks ------------------------------------------------------
  if [ ! -x "$CLAUDE_BIN" ]; then
    echo "ERROR: Binary not found at $CLAUDE_BIN"
    return 1
  fi

  if ! command -v tmux &>/dev/null; then
    echo "ERROR: tmux is required (brew install tmux)"
    return 1
  fi

  # ---- Launch Claude in a headless tmux session ------------------------------
  # Use the shell PID ($$) to create a unique session name for each run.
  local SESSION="cw-$$"
  echo "Spawning tmux session '$SESSION'..."

  # 200×50 gives React Ink enough columns to fully render its UI panels.
  tmux new-session -d -s "$SESSION" -x 200 -y 50 || {
    echo "ERROR: Failed to create tmux session"
    return 1
  }

  # CLAUDECODE= clears the env var that triggers the "nested session" refusal.
  tmux send-keys -t "$SESSION" "CLAUDECODE= $CLAUDE_BIN" Enter

  # ---- Wait for Claude to boot -----------------------------------------------
  # Claude shows either the REPL prompt (❯) or a workspace trust dialog.
  if ! wait_for "$SESSION" "❯|quick|safety" 15; then
    echo "ERROR: Claude failed to start within 15 s"
    tmux kill-session -t "$SESSION" 2>/dev/null
    return 1
  fi

  # ---- Handle trust dialog (first-run only) ----------------------------------
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

  # ---- Run /usage to check session status ------------------------------------
  # Autocomplete intercepts the first Enter (selects the suggestion).
  # A second Enter after a short pause actually submits the command.
  tmux send-keys -t "$SESSION" "/usage" Enter
  sleep 0.5
  tmux send-keys -t "$SESSION" Enter

  # Poll for the usage panel to appear rather than using a fixed sleep.
  if ! wait_for "$SESSION" "% used|resets " 20; then
    echo "WARN: /usage stats did not appear within 20 s"
  fi

  # ---- Capture screen output -------------------------------------------------
  # -p prints to stdout; -S - captures full scrollback history.
  CLEAN_OUTPUT=$(tmux capture-pane -t "$SESSION" -p -S - 2>/dev/null)

  # Done with Claude — kill the session immediately.
  tmux kill-session -t "$SESSION" 2>/dev/null

  echo "Captured ${#CLEAN_OUTPUT} chars of screen history"

  # ---- Detect active session from /usage output ------------------------------
  # An active session shows "X% used" and "Resets <time> (<timezone>)".
  # If "Resets" is present, the session is alive and no action is needed.
  UI_STATUS=$(echo "$CLEAN_OUTPUT" | grep -iE "% used|resets " | xargs)
  echo "Scraped Status: $UI_STATUS"

  if echo "$CLEAN_OUTPUT" | grep -iqE "resets"; then
    echo "✅ Active session detected. Skipping ping."
  else
    # No active session — send a minimal prompt to start one.
    # caffeinate -i prevents idle sleep while the ping runs.
    echo "❌ No active session found. Triggering 'Hi' ping..."

    caffeinate -i bash -c "
      cd /tmp
      echo 'Hi' | $CLAUDE_BIN --model haiku
    " &

    CPID=$!
    echo "Claude process started (PID: $CPID). Syncing..."
    sleep 30
    kill -9 $CPID > /dev/null 2>&1

    echo "Sync process complete."
  fi

  # ---- Schedule pmset wake events (safety net) --------------------------------
  schedule_all_wakes

  # ---- Keep the Mac awake until active hours end ------------------------------
  # Apple Silicon ignores pmset schedule wakes unreliably, so we use caffeinate
  # to prevent sleep for the entire remaining active window. This guarantees
  # launchd fires at every interval. The Mac only sleeps during skip hours,
  # and the pmset repeat wake (set by install.sh) handles the morning wake-up.
  local SKIP_HOURS_CSV=""
  [ -f "$SCRIPT_DIR/.skip_hours" ] && SKIP_HOURS_CSV=$(cat "$SCRIPT_DIR/.skip_hours")

  # Walk forward from the current hour to find where active hours end.
  local CURRENT_H=$(date +%-H)
  local END_HOUR=24
  for h in $(seq $((CURRENT_H + 1)) 23); do
    if [ -n "$SKIP_HOURS_CSV" ] && echo ",$SKIP_HOURS_CSV," | grep -q ",$h,"; then
      END_HOUR=$h
      break
    fi
  done

  # Seconds from now until the start of the first skip hour, plus 60 s buffer.
  local CURRENT_M=$(date +%-M)
  local REMAINING=$(( (END_HOUR - CURRENT_H) * 3600 - CURRENT_M * 60 + 60 ))

  # Never caffeinate for less than one full interval — covers edge cases
  # near the end of active hours where REMAINING would be very small.
  local INTERVAL_MINUTES=60
  [ -f "$SCRIPT_DIR/.interval" ] && INTERVAL_MINUTES=$(cat "$SCRIPT_DIR/.interval")
  local MIN_SECS=$(( (INTERVAL_MINUTES + 2) * 60 ))
  [ "$REMAINING" -lt "$MIN_SECS" ] && REMAINING=$MIN_SECS

  # Kill any leftover caffeinate from a previous run before starting a new one.
  pkill -f "caffeinate -s -t" 2>/dev/null
  # Redirect stdout/stderr to /dev/null so the backgrounded process doesn't
  # hold the pipe to tee open (which would block the script from exiting).
  caffeinate -s -t "$REMAINING" >/dev/null 2>&1 &
  echo "caffeinate: preventing sleep for $((REMAINING / 60))m until end of active hours (PID: $!)"

  echo "--- SYNC END: $(date) ---"
  echo ""
}

# Run and append all output (stdout + stderr) to the log file.
run_sync 2>&1 | tee -a "$LOG"
