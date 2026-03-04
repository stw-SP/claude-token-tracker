#!/usr/bin/env bash
# Token Tracker installer for Claude Code
# Adds: status line with context bar + weekly token usage, token logger hook,
#        /tokens report command with calibration support.
#
# Usage: bash install.sh
# Uninstall: bash install.sh --uninstall

set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOKS_DIR="$CLAUDE_DIR/hooks"
COMMANDS_DIR="$CLAUDE_DIR/commands"
SETTINGS="$CLAUDE_DIR/settings.json"
CONFIG="$CLAUDE_DIR/usage-config.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
DIM='\033[2m'
RESET='\033[0m'

info()  { echo -e "${GREEN}[+]${RESET} $1"; }
warn()  { echo -e "${YELLOW}[!]${RESET} $1"; }
error() { echo -e "${RED}[x]${RESET} $1"; }
dim()   { echo -e "${DIM}    $1${RESET}"; }

# ── Uninstall ────────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--uninstall" ]]; then
  echo ""
  echo "Uninstalling Token Tracker..."
  echo ""

  # Remove files
  for f in "$HOOKS_DIR/token-logger.js" "$HOOKS_DIR/token-usage.js" "$HOOKS_DIR/statusline.js" "$COMMANDS_DIR/tokens.md"; do
    if [[ -f "$f" ]]; then
      rm "$f"
      info "Removed $f"
    fi
  done

  # Patch settings.json: remove token-logger hook and statusline
  if [[ -f "$SETTINGS" ]]; then
    node -e '
      const fs = require("fs");
      const path = process.argv[1];
      let s = JSON.parse(fs.readFileSync(path, "utf8"));

      // Remove token-logger from PostToolUse hooks
      if (s.hooks && s.hooks.PostToolUse) {
        for (const group of s.hooks.PostToolUse) {
          if (group.hooks) {
            group.hooks = group.hooks.filter(h => !h.command || !h.command.includes("token-logger.js"));
          }
        }
        // Remove empty PostToolUse groups
        s.hooks.PostToolUse = s.hooks.PostToolUse.filter(g => g.hooks && g.hooks.length > 0);
        if (s.hooks.PostToolUse.length === 0) delete s.hooks.PostToolUse;
        if (Object.keys(s.hooks).length === 0) delete s.hooks;
      }

      // Remove statusline only if it points to our script
      if (s.statusLine && s.statusLine.command && s.statusLine.command.includes("statusline.js") && !s.statusLine.command.includes("gsd-statusline.js")) {
        delete s.statusLine;
      }

      fs.writeFileSync(path, JSON.stringify(s, null, 2) + "\n");
    ' "$SETTINGS"
    info "Cleaned settings.json"
  fi

  # Clean up temp files
  rm -f /tmp/claude-usage-cache.json /tmp/token-logger-cursor-*.json
  info "Cleaned temp files"

  echo ""
  info "Token Tracker uninstalled. usage-config.json and token-log.jsonl preserved."
  dim "Delete them manually if you want a full cleanup:"
  dim "  rm ~/.claude/usage-config.json ~/.claude/token-log.jsonl"
  exit 0
fi

# ── Pre-flight checks ───────────────────────────────────────────────────────

echo ""
echo "Token Tracker for Claude Code"
echo "============================="
echo ""

# Check Node.js
if ! command -v node &>/dev/null; then
  error "Node.js is required but not found. Install it first."
  exit 1
fi

# Check Claude Code directory exists
if [[ ! -d "$CLAUDE_DIR" ]]; then
  error "$CLAUDE_DIR does not exist. Install Claude Code first (npm install -g @anthropic-ai/claude-code)."
  exit 1
fi

# ── Create directories ──────────────────────────────────────────────────────

mkdir -p "$HOOKS_DIR" "$COMMANDS_DIR"

# ── Back up settings.json ────────────────────────────────────────────────────

if [[ -f "$SETTINGS" ]]; then
  cp "$SETTINGS" "$SETTINGS.bak"
  dim "Backed up settings.json to settings.json.bak"
fi

# ── Write hook files ─────────────────────────────────────────────────────────

# 1. Token Logger (PostToolUse hook)
cat << 'ENDOFFILE' > "$HOOKS_DIR/token-logger.js"
#!/usr/bin/env node
// Token Logger - PostToolUse hook
// Reads the conversation transcript and extracts per-API-call token usage
// with timestamps. Appends new entries to ~/.claude/token-log.jsonl.
//
// Dedup strategy:
// - Cursor file tracks byte offset + pending requestIds (may still be streaming)
// - A requestId is "finalized" when a NEWER requestId appears (meaning the
//   previous API call is complete and has its final token count)
// - Only finalized entries get appended to the log

const fs = require('fs');
const path = require('path');
const os = require('os');

let input = '';
const stdinTimeout = setTimeout(() => process.exit(0), 3000);
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const data = JSON.parse(input);
    const transcriptPath = data.transcript_path;
    const sessionId = data.session_id;

    if (!transcriptPath || !sessionId || !fs.existsSync(transcriptPath)) {
      process.exit(0);
    }

    const homeDir = os.homedir();
    const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(homeDir, '.claude');
    const logPath = path.join(claudeDir, 'token-log.jsonl');
    const cursorPath = '/tmp/token-logger-cursor-' + sessionId + '.json';

    // Read cursor state
    let cursor = { offset: 0, pending: {} };
    // pending: { requestId: { timestamp, model, input_tokens, output_tokens, ... } }
    try {
      if (fs.existsSync(cursorPath)) {
        cursor = JSON.parse(fs.readFileSync(cursorPath, 'utf8'));
      }
    } catch (e) {}

    // Read transcript from cursor offset
    const stat = fs.statSync(transcriptPath);
    if (stat.size <= cursor.offset) {
      process.exit(0);
    }

    const fd = fs.openSync(transcriptPath, 'r');
    const buf = Buffer.alloc(stat.size - cursor.offset);
    fs.readSync(fd, buf, 0, buf.length, cursor.offset);
    fs.closeSync(fd);

    const newContent = buf.toString('utf8');
    const lines = newContent.split('\n').filter(l => l.trim());

    // Extract usage from new lines, updating pending map
    // The last line per requestId has the most current token count
    const seenInBatch = new Set();
    for (const line of lines) {
      try {
        const d = JSON.parse(line);
        if (d.type === 'assistant' && d.message && d.message.usage && d.requestId) {
          seenInBatch.add(d.requestId);
          cursor.pending[d.requestId] = {
            timestamp: d.timestamp,
            sessionId: sessionId,
            model: d.message.model || '',
            requestId: d.requestId,
            input_tokens: d.message.usage.input_tokens || 0,
            output_tokens: d.message.usage.output_tokens || 0,
            cache_read_input_tokens: d.message.usage.cache_read_input_tokens || 0,
            cache_creation_input_tokens: d.message.usage.cache_creation_input_tokens || 0,
          };
        }
      } catch (e) {}
    }

    // Finalize: any pending requestId NOT seen in this batch is complete
    // (a new API call has started, so the old one's final count is locked in)
    const toFinalize = [];
    for (const reqId of Object.keys(cursor.pending)) {
      if (!seenInBatch.has(reqId)) {
        toFinalize.push(cursor.pending[reqId]);
        delete cursor.pending[reqId];
      }
    }

    // Append finalized entries to log
    if (toFinalize.length > 0) {
      const logLines = toFinalize.map(e => JSON.stringify(e)).join('\n') + '\n';
      fs.appendFileSync(logPath, logLines);
    }

    // Update cursor
    cursor.offset = stat.size;
    fs.writeFileSync(cursorPath, JSON.stringify(cursor));

  } catch (e) {
    // Silent fail
  }
});
ENDOFFILE
info "Wrote hooks/token-logger.js"

# 2. Shared token usage module
cat << 'ENDOFFILE' > "$HOOKS_DIR/token-usage.js"
// Shared token usage display module
// Used by both gsd-statusline.js and statusline.js

const fs = require('fs');
const path = require('path');

function getUsageDisplay(claudeDir, currentSessionId) {
  const configPath = path.join(claudeDir, 'usage-config.json');
  const statsPath = path.join(claudeDir, 'stats-cache.json');
  const cachePath = '/tmp/claude-usage-cache.json';

  // Check cache first (5-min TTL)
  try {
    if (fs.existsSync(cachePath)) {
      const cache = JSON.parse(fs.readFileSync(cachePath, 'utf8'));
      if (Date.now() - cache.timestamp < 300000) {
        return cache.display;
      }
    }
  } catch (e) {}

  // Read config
  let config;
  try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  } catch (e) {
    return '';
  }

  // Read token log (granular per-message data) or fall back to stats-cache
  const tokenLogPath = path.join(claudeDir, 'token-log.jsonl');
  let tokenLogEntries = [];
  let usingGranularLog = false;
  try {
    if (fs.existsSync(tokenLogPath)) {
      const content = fs.readFileSync(tokenLogPath, 'utf8');
      const byReqId = new Map();
      for (const line of content.split('\n')) {
        if (!line.trim()) continue;
        try {
          const d = JSON.parse(line);
          if (d.requestId) byReqId.set(d.requestId, d);
        } catch (e) {}
      }
      tokenLogEntries = Array.from(byReqId.values());
      if (tokenLogEntries.length > 0) usingGranularLog = true;
    }
  } catch (e) {}

  // Fall back to stats-cache if no granular log
  let dailyTokens = [];
  if (!usingGranularLog) {
    try {
      const stats = JSON.parse(fs.readFileSync(statsPath, 'utf8'));
      dailyTokens = stats.dailyModelTokens || [];
    } catch (e) {}
    if (dailyTokens.length === 0) return '';
  }

  const view = config.view || 'weekly';
  const limits = config.limits || {};
  const resetDay = (config.resetDay || 'thursday').toLowerCase();
  const resetHour = config.resetHour != null ? config.resetHour : 0;
  const resetTz = config.resetTimezone || null;

  // Get current time in reset timezone (or local if not set)
  function nowInTz() {
    if (resetTz) {
      const s = new Date().toLocaleString('en-US', { timeZone: resetTz });
      return new Date(s);
    }
    return new Date();
  }

  const now = nowInTz();
  const today = now.toISOString().split('T')[0];

  const dayMap = { sunday: 0, monday: 1, tuesday: 2, wednesday: 3, thursday: 4, friday: 5, saturday: 6 };
  const resetDayNum = dayMap[resetDay] != null ? dayMap[resetDay] : 4;

  // Find start of current reset window
  function getWeekStart(date) {
    const d = new Date(date);
    let diff = d.getDay() - resetDayNum;
    if (diff < 0) diff += 7;
    if (diff === 0 && d.getHours() < resetHour) diff = 7;
    d.setDate(d.getDate() - diff);
    d.setHours(resetHour, 0, 0, 0);
    return d;
  }

  const weekStart = getWeekStart(now);
  const weekStartStr = weekStart.toISOString().split('T')[0];

  // Next reset countdown as DD HH:MM:SS
  const nextReset = new Date(weekStart);
  nextReset.setDate(nextReset.getDate() + 7);
  const msUntilReset = Math.max(0, nextReset - now);
  const totalSec = Math.floor(msUntilReset / 1000);
  const dd = Math.floor(totalSec / 86400);
  const hh = String(Math.floor((totalSec % 86400) / 3600)).padStart(2, '0');
  const mm = String(Math.floor((totalSec % 3600) / 60)).padStart(2, '0');
  const ss = String(totalSec % 60).padStart(2, '0');
  const resetLabel = dd > 0
    ? dd + 'd ' + hh + ':' + mm + ':' + ss
    : hh + ':' + mm + ':' + ss;

  function modelFamily(name) {
    if (name.includes('opus')) return 'opus';
    if (name.includes('sonnet')) return 'sonnet';
    if (name.includes('haiku')) return 'haiku';
    return 'other';
  }

  function formatTokens(n) {
    if (n >= 1000000) return (n / 1000000).toFixed(1).replace(/\.0$/, '') + 'M';
    if (n >= 1000) return (n / 1000).toFixed(0) + 'K';
    return String(n);
  }

  // Sum tokens by model family
  function getWeekTotals() {
    const totals = {};
    if (usingGranularLog) {
      for (const entry of tokenLogEntries) {
        const entryTime = new Date(entry.timestamp);
        let entryInTz = entryTime;
        if (resetTz) {
          const s = entryTime.toLocaleString('en-US', { timeZone: resetTz });
          entryInTz = new Date(s);
        }
        if (entryInTz >= weekStart) {
          const family = modelFamily(entry.model);
          const tokens = (entry.input_tokens || 0) + (entry.output_tokens || 0);
          totals[family] = (totals[family] || 0) + tokens;
        }
      }
    } else {
      for (const entry of dailyTokens) {
        if (entry.date >= weekStartStr) {
          for (const [model, tokens] of Object.entries(entry.tokensByModel || {})) {
            const family = modelFamily(model);
            totals[family] = (totals[family] || 0) + tokens;
          }
        }
      }
    }
    return totals;
  }

  function getSessionTotals() {
    const totals = {};
    if (usingGranularLog && currentSessionId) {
      for (const entry of tokenLogEntries) {
        if (entry.sessionId === currentSessionId) {
          const family = modelFamily(entry.model);
          const tokens = (entry.input_tokens || 0) + (entry.output_tokens || 0);
          totals[family] = (totals[family] || 0) + tokens;
        }
      }
    }
    return totals;
  }

  let display = '';

  if (view === 'weekly') {
    const totals = getWeekTotals();
    const used = Object.values(totals).reduce((a, b) => a + b, 0);
    const limit = limits.total;

    if (used === 0) {
      display = ' \x1b[2m|\x1b[0m Wk: 0 \x1b[2m|\x1b[0m ' + resetLabel;
    } else if (limit) {
      const pct = Math.round((used / limit) * 100);
      let color;
      if (pct < 50) color = '\x1b[32m';
      else if (pct < 75) color = '\x1b[33m';
      else if (pct < 90) color = '\x1b[38;5;208m';
      else color = '\x1b[31m';

      display = ' \x1b[2m|\x1b[0m ' + color + 'Wk: ' + formatTokens(used) + '/' + formatTokens(limit) + ' (' + pct + '%)' + '\x1b[0m \x1b[2m|\x1b[0m ' + resetLabel;
    } else {
      display = ' \x1b[2m|\x1b[0m Wk: ' + formatTokens(used) + ' \x1b[2m|\x1b[0m ' + resetLabel;
    }
  } else {
    // Session view
    const totals = getSessionTotals();
    const primaryModel = totals.opus != null ? 'opus' : Object.keys(totals)[0];

    if (!primaryModel) {
      display = ' \x1b[2m|\x1b[0m Sn: 0 \x1b[2m|\x1b[0m ' + resetLabel;
    } else {
      display = ' \x1b[2m|\x1b[0m Sn: ' + formatTokens(totals[primaryModel]) + ' ' + primaryModel + ' \x1b[2m|\x1b[0m ' + resetLabel;
    }
  }

  // Cache result
  try {
    fs.writeFileSync(cachePath, JSON.stringify({ display, timestamp: Date.now() }));
  } catch (e) {}

  return display;
}

module.exports = { getUsageDisplay };
ENDOFFILE
info "Wrote hooks/token-usage.js"

# 3. Standalone status line
cat << 'ENDOFFILE' > "$HOOKS_DIR/statusline.js"
#!/usr/bin/env node
// Claude Code Statusline - Standalone Edition
// Shows: model | directory | context usage | token tracker

const fs = require('fs');
const path = require('path');
const os = require('os');
const { getUsageDisplay } = require('./token-usage.js');

// Read JSON from stdin
let input = '';
const stdinTimeout = setTimeout(() => process.exit(0), 3000);
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const data = JSON.parse(input);
    const model = data.model?.display_name || 'Claude';
    const dir = data.workspace?.current_dir || process.cwd();
    const session = data.session_id || '';
    const remaining = data.context_window?.remaining_percentage;

    // Context window display (shows USED percentage scaled to usable context)
    // Claude Code reserves ~16.5% for autocompact buffer, so usable context
    // is 83.5% of the total window. We normalize to show 100% at that point.
    const AUTO_COMPACT_BUFFER_PCT = 16.5;
    let ctx = '';
    if (remaining != null) {
      const usableRemaining = Math.max(0, ((remaining - AUTO_COMPACT_BUFFER_PCT) / (100 - AUTO_COMPACT_BUFFER_PCT)) * 100);
      const used = Math.max(0, Math.min(100, Math.round(100 - usableRemaining)));

      // Build progress bar (10 segments)
      const filled = Math.floor(used / 10);
      const bar = '\u2588'.repeat(filled) + '\u2591'.repeat(10 - filled);

      // Color based on usable context thresholds
      if (used < 50) {
        ctx = ` \x1b[32m${bar} ${used}%\x1b[0m`;
      } else if (used < 65) {
        ctx = ` \x1b[33m${bar} ${used}%\x1b[0m`;
      } else if (used < 80) {
        ctx = ` \x1b[38;5;208m${bar} ${used}%\x1b[0m`;
      } else {
        ctx = ` \x1b[5;31m${bar} ${used}%\x1b[0m`;
      }
    }

    // Token usage
    const homeDir = os.homedir();
    const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(homeDir, '.claude');
    const usage = getUsageDisplay(claudeDir, session);

    // Output
    const dirname = path.basename(dir);
    process.stdout.write(`\x1b[2m${model}\x1b[0m \x1b[2m|\x1b[0m \x1b[2m${dirname}\x1b[0m${ctx}${usage}`);
  } catch (e) {
    // Silent fail - don't break statusline on parse errors
  }
});
ENDOFFILE
info "Wrote hooks/statusline.js"

# ── Write /tokens command ────────────────────────────────────────────────────

cat << 'ENDOFFILE' > "$COMMANDS_DIR/tokens.md"
Show a detailed token usage breakdown. Read the following files and present the information described below.

**Files to read:**
1. `~/.claude/token-log.jsonl` - **primary source** (granular per-message data with timestamps). Each line is JSON: `{ timestamp, sessionId, model, requestId, input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens }`. Deduplicate by `requestId` (take last entry per requestId). Token metric = `input_tokens + output_tokens`.
2. `~/.claude/stats-cache.json` - **fallback** if token-log.jsonl is empty. Field `dailyModelTokens` (array of `{ date, tokensByModel }`). Token metric = the value per model (already input+output).
3. `~/.claude/usage-config.json` - fields: `plan`, `resetDay`, `resetHour`, `resetTimezone`, `view`, `limits`

**If the user passes an argument:**
- `session` or `weekly`: update the `view` field in `~/.claude/usage-config.json` and confirm the change. Then show the report below using the new view mode.
- `calibrate`: run the calibration flow described below instead of the report.

**Report to display:**

### Token Usage Report

1. **Current view mode**: weekly or daily (from config)
2. **Weekly reset**: show the exact reset boundary, e.g., "Thursday 10:00 PM EST" (from `resetDay`, `resetHour`, `resetTimezone` in config)
3. **Time until reset**: calculate as DD HH:MM:SS countdown from now to the next reset boundary
4. **Data source**: indicate whether using granular token log or stats-cache fallback

5. **Weekly summary** (always show, regardless of view mode):
   - Sum all tokens (input_tokens + output_tokens) from the current reset window across ALL models
   - The reset window starts at `resetDay` + `resetHour` in `resetTimezone` (e.g., Thursday 10pm EST)
   - When using token-log.jsonl, filter by exact timestamp (this is the whole point -- precise boundary)
   - When using stats-cache.json, filter by date >= reset day (day-level approximation)
   - Show the combined total and percentage of `limits.total` from config (single limit across all models)
   - Also show breakdown by model family (opus, sonnet, haiku) for reference, but the percentage is against the single total limit
   - Format large numbers: e.g., 12,345,678 = 12.3M

6. **Daily breakdown for current week**:
   - List each day that has data, showing date and tokens by model family
   - Highlight today's row if present

7. **How to toggle view**:
   - Tell the user: "Run `/tokens session` or `/tokens weekly` to switch the status line view"
   - Or: "Edit `~/.claude/usage-config.json` and change the `view` field"

8. **Limitations** (show at the bottom in a note):
   - The token logger hook captures data from PostToolUse events. The LAST API call of a session (after the final tool use) may not be captured until the next tool use triggers the logger. This is a minor gap.
   - Weekly limits are estimates, not official Anthropic numbers -- adjust `limits` in usage-config.json as needed
   - If token-log.jsonl is empty or missing, falls back to stats-cache.json (day-level granularity, no precise 10pm boundary)
   - Running `/stats` in Claude Code may trigger a stats-cache refresh

---

## Calibration Flow (when argument is `calibrate`)

This helps the user determine their weekly token limit by cross-referencing tracked usage with their claude.ai usage percentage.

**Steps:**

1. **Read data**: Read `~/.claude/token-log.jsonl` and `~/.claude/usage-config.json`.

2. **Calculate tracked tokens**: Sum all `input_tokens + output_tokens` from token-log.jsonl entries that fall within the current reset window (using `resetDay`, `resetHour`, `resetTimezone` from config). Deduplicate by `requestId` (take last entry per requestId).

3. **Check for sufficient data**: If total tracked tokens in the current window is 0 or very low (< 100K), tell the user: "Not enough token data in the current reset window to calibrate accurately. Use Claude Code for a while and try again later." Stop here.

4. **Ask for usage percentage**: Ask the user: "Check your claude.ai account usage page. What percentage of your weekly limit have you used so far this period?" Validate the response is a number between 1 and 99. If < 10, warn: "Low percentages produce imprecise estimates. For better accuracy, calibrate when you've used at least 10-15% of your limit."

5. **Calculate the limit**: `estimated_limit = tracked_tokens / (percentage / 100)`. Round to the nearest integer.

6. **Show the result**: Display:
   - Tracked tokens this window: [formatted number]
   - User-reported usage: [X]%
   - Calculated weekly limit: [formatted number]
   - Current configured limit: [formatted number, or "not set"]

7. **Confirm with user**: Ask "Update your weekly limit to [calculated value]?" Wait for confirmation.

8. **Update config**: If confirmed, update `limits.total` in `~/.claude/usage-config.json` to the calculated value. Delete `/tmp/claude-usage-cache.json` to clear the status line cache so it picks up the new limit immediately.

9. **Confirm**: Tell the user the limit has been updated and the status line will reflect the change.

$ARGUMENTS
ENDOFFILE
info "Wrote commands/tokens.md"

# ── Create usage-config.json (only if missing) ──────────────────────────────

if [[ ! -f "$CONFIG" ]]; then
  cat << 'ENDOFFILE' > "$CONFIG"
{
  "resetDay": "thursday",
  "resetHour": 0,
  "view": "weekly",
  "limits": {}
}
ENDOFFILE
  info "Created usage-config.json with defaults"
  dim "Edit resetDay, resetHour, and resetTimezone to match your billing cycle."
  dim "Run /tokens calibrate after some usage to set your weekly limit."
else
  dim "usage-config.json already exists -- skipping"
fi

# ── Patch settings.json ──────────────────────────────────────────────────────

# Use node for safe JSON manipulation (no jq dependency)
node -e '
  const fs = require("fs");
  const path = require("path");
  const settingsPath = process.argv[1];
  const hooksDir = process.argv[2];

  let settings = {};
  try {
    settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  } catch (e) {
    // File missing or invalid -- start fresh
  }

  let changed = false;
  const messages = [];

  // --- Add token-logger to PostToolUse hooks ---
  if (!settings.hooks) settings.hooks = {};
  if (!settings.hooks.PostToolUse) settings.hooks.PostToolUse = [];

  // Check if token-logger already present
  const hasTokenLogger = settings.hooks.PostToolUse.some(group =>
    (group.hooks || []).some(h => h.command && h.command.includes("token-logger.js"))
  );

  if (!hasTokenLogger) {
    // Find existing catch-all group (matcher === "" or no matcher) to append to
    let catchAll = settings.hooks.PostToolUse.find(g => !g.matcher || g.matcher === "");
    if (!catchAll) {
      catchAll = { hooks: [] };
      settings.hooks.PostToolUse.push(catchAll);
    }
    if (!catchAll.hooks) catchAll.hooks = [];
    catchAll.hooks.push({
      type: "command",
      command: "node \"" + path.join(hooksDir, "token-logger.js") + "\""
    });
    changed = true;
    messages.push("ADDED token-logger PostToolUse hook");
  } else {
    messages.push("SKIP  token-logger hook (already present)");
  }

  // --- Set statusLine ---
  if (settings.statusLine) {
    const cmd = settings.statusLine.command || "";
    if (cmd.includes("gsd-statusline.js")) {
      messages.push("SKIP  statusLine (gsd-statusline.js detected -- it already includes token tracking)");
    } else if (cmd.includes("statusline.js")) {
      messages.push("SKIP  statusLine (already set to statusline.js)");
    } else {
      messages.push("SKIP  statusLine (custom command detected -- not overwriting)");
      messages.push("       To use token tracker status line, set statusLine.command to:");
      messages.push("       node \"" + path.join(hooksDir, "statusline.js") + "\"");
    }
  } else {
    settings.statusLine = {
      type: "command",
      command: "node \"" + path.join(hooksDir, "statusline.js") + "\""
    };
    changed = true;
    messages.push("ADDED statusLine command");
  }

  // Write if changed
  if (changed) {
    fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
  }

  // Output messages for the shell script to display
  for (const m of messages) {
    console.log(m);
  }
' "$SETTINGS" "$HOOKS_DIR" | while IFS= read -r line; do
  case "$line" in
    ADDED*) info "${line#ADDED }" ;;
    SKIP*)  dim "${line#SKIP  }" ;;
    *)      dim "$line" ;;
  esac
done

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
info "Installation complete. Restart Claude Code to activate."
echo ""
echo "  What you get:"
dim "Status line: model | directory | context bar | weekly token usage | reset countdown"
dim "/tokens      - detailed usage report"
dim "/tokens calibrate - determine your weekly limit from claude.ai usage %"
echo ""
echo "  Next steps:"
dim "1. Restart Claude Code"
dim "2. Use it normally for a bit (tokens start logging automatically)"
dim "3. Run /tokens calibrate to set your weekly limit"
echo ""
dim "To uninstall: bash ~/.claude/install-token-tracker.sh --uninstall"
