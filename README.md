# Claude Code Token Tracker

Track your weekly token usage directly in the Claude Code status line. Know exactly where you stand in your billing cycle without leaving your terminal.

## What It Looks Like

After installation, your Claude Code status line shows:

```
Claude Opus 4.6 | my-project ████░░░░░░ 35% | Wk: 2.1M/5.4M (39%) | 3d 14:22:00
```

Here's what each section means:

```
Claude Opus 4.6 | my-project ████░░░░░░ 35% | Wk: 2.1M/5.4M (39%) | 3d 14:22:00
│                 │            │                │                      │
Model name        Directory    Context window   Weekly tokens          Reset countdown
                               usage bar        used/limit (%)         days hours:min:sec
```

The status line is color-coded:
- **Green** -- you're in good shape (< 50% tokens used, < 50% context used)
- **Yellow** -- moderate usage (50-74% tokens, 50-64% context)
- **Orange** -- getting heavy (75-89% tokens, 65-79% context)
- **Red** -- near limit (90%+ tokens, 80%+ context)

### Status Line Variations

Before calibration (no limit set):
```
Claude Opus 4.6 | my-project ░░░░░░░░░░ 0% | Wk: 847K | 5d 02:15:30
```

With limit calibrated:
```
Claude Opus 4.6 | my-project ███░░░░░░░ 25% | Wk: 2.1M/5.4M (39%) | 3d 14:22:00
```

In session view mode (`/tokens session`):
```
Claude Opus 4.6 | my-project █████░░░░░ 42% | Sn: 156K opus | 3d 14:22:00
```

Deep into a long conversation:
```
Claude Opus 4.6 | my-project ████████░░ 80% | Wk: 4.9M/5.4M (91%) | 0d 03:45:12
```

## What You Get

**Status line** -- always-visible display of model, directory, context usage, weekly token consumption, and time until your limit resets.

**Context progress bar** -- shows how much of your context window you've consumed. The bar accounts for the ~16.5% that Claude Code reserves for its autocompact buffer, so 100% means autocompact is about to trigger, not that the model is out of context.

**Token logger** -- a `PostToolUse` hook that silently records per-API-call token usage from conversation transcripts. Runs automatically, no user interaction needed.

**`/tokens` command** -- detailed usage report with daily breakdown by model family:
```
> /tokens

### Token Usage Report
View: weekly
Weekly reset: Thursday 10:00 PM EST
Time until reset: 3d 14:22:00
Data source: granular token log (1,247 entries)

Weekly total: 5,284,301 / 5,430,924 (97%)
  opus:   4,891,220 (93%)
  sonnet:   312,448 (6%)
  haiku:     80,633 (1%)

Daily breakdown:
  Thu Feb 27:  opus 892K  sonnet 45K
  Fri Feb 28:  opus 1.2M  sonnet 89K  haiku 31K
  Sat Mar 01:  opus 756K
  Sun Mar 02:  opus 1.1M  sonnet 112K  haiku 50K
  Mon Mar 03:  opus 943K  sonnet 66K    <-- today
```

**`/tokens calibrate`** -- interactive flow to determine your actual weekly limit:
```
> /tokens calibrate

Tracked tokens this window: 2,142,561

Check your claude.ai account usage page.
What percentage of your weekly limit have you used so far this period?
> 39

Results:
  Tracked tokens this window: 2.1M
  Reported usage: 39%
  Calculated weekly limit: 5,493,490
  Current configured limit: not set

Update your weekly limit to 5,493,490? (yes/no)
> yes

Limit updated. Status line will reflect the change immediately.
```

**`/tokens weekly`** and **`/tokens session`** -- toggle the status line between weekly totals and current session view.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/stw-SP/claude-token-tracker/main/install.sh | bash
```

Or download and inspect first:

```bash
curl -fsSL https://raw.githubusercontent.com/stw-SP/claude-token-tracker/main/install.sh -o install.sh
less install.sh
bash install.sh
```

Then restart Claude Code.

**Requirements:** Node.js (v16+) and Claude Code already installed.

### What the Installer Does

1. Writes 3 hook scripts to `~/.claude/hooks/`
2. Writes the `/tokens` command to `~/.claude/commands/tokens.md`
3. Creates `~/.claude/usage-config.json` with defaults (only if it doesn't exist)
4. Patches `~/.claude/settings.json` to register the hook and status line (backs it up first)

The installer is idempotent -- running it again skips anything already present. It also detects existing configurations (like GSD's status line) and won't overwrite them.

## Getting Started

After installing:

1. **Restart Claude Code** so the new hooks activate
2. **Use Claude Code normally** for a few conversations -- the token logger starts recording automatically
3. **Run `/tokens calibrate`** to set your weekly limit:
   - Open [claude.ai/settings/usage](https://claude.ai/settings/usage) in your browser
   - Note the percentage shown
   - Enter it when prompted
   - The tracker calculates your limit and saves it
4. **Your status line now shows percentages** -- you can see at a glance where you stand

You can recalibrate anytime. More usage data and higher percentages produce more accurate estimates.

## Configure

Edit `~/.claude/usage-config.json`:

```json
{
  "resetDay": "thursday",
  "resetHour": 22,
  "resetTimezone": "America/New_York",
  "view": "weekly",
  "limits": {
    "total": 5430924
  }
}
```

| Field | Description | Default |
|-------|-------------|---------|
| `resetDay` | Day your weekly usage resets (lowercase) | `thursday` |
| `resetHour` | Hour (0-23) when it resets | `0` (midnight) |
| `resetTimezone` | [IANA timezone](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones) for reset calculation | system local |
| `view` | Status line mode: `weekly` or `session` | `weekly` |
| `limits.total` | Your weekly token limit (set via `/tokens calibrate`) | none |

### Finding Your Reset Day

Your reset day depends on when you first subscribed. Check [claude.ai/settings/usage](https://claude.ai/settings/usage) -- it should show when your current period started. Common values: `thursday`, `monday`, `wednesday`.

### Setting the Reset Hour

If your usage resets at a specific time (e.g., 10 PM Eastern), set:
```json
{
  "resetHour": 22,
  "resetTimezone": "America/New_York"
}
```

The tracker will use this exact boundary when calculating weekly totals, giving you precise tracking even across timezone-aware reset windows.

## How It Works

### Token Logger

A `PostToolUse` hook that runs after every tool call. It reads the conversation transcript (a JSONL file that Claude Code maintains), extracts token counts from API responses, and appends them to `~/.claude/token-log.jsonl`.

Dedup strategy: uses a cursor file to track where it left off in the transcript. A request is only "finalized" (written to the log) when a newer request appears, ensuring the final token count is captured rather than an intermediate streaming count.

### Status Line

Reads `token-log.jsonl`, sums usage within the current reset window, and formats it alongside the context progress bar. Results are cached for 5 minutes (`/tmp/claude-usage-cache.json`) to keep execution fast -- the status line runs on every prompt render.

### Context Bar

Clauded Code reports `remaining_percentage` of the context window. The bar normalizes this against the ~16.5% autocompact buffer, so:
- 0% used = fresh conversation
- 100% used = autocompact will trigger on next turn
- The bar is not about model context limits, it's about when Claude Code will compress your history

## Files

### Installed Files

| File | Purpose |
|------|---------|
| `~/.claude/hooks/token-logger.js` | PostToolUse hook -- logs token usage per API call |
| `~/.claude/hooks/token-usage.js` | Shared module -- computes and formats the usage display |
| `~/.claude/hooks/statusline.js` | Status line script -- renders model, dir, context bar, tokens |
| `~/.claude/commands/tokens.md` | `/tokens` slash command definition |
| `~/.claude/usage-config.json` | Configuration (created on first install only) |

### Runtime Data

| File | Purpose |
|------|---------|
| `~/.claude/token-log.jsonl` | Granular token log (one JSON line per finalized API call) |
| `/tmp/claude-usage-cache.json` | 5-minute cache for status line display |
| `/tmp/token-logger-cursor-*.json` | Per-session transcript read cursor |

### What a Token Log Entry Looks Like

```json
{
  "timestamp": "2026-03-03T15:42:18.123Z",
  "sessionId": "abc123-def456",
  "model": "claude-opus-4-6-20250625",
  "requestId": "req_01ABC",
  "input_tokens": 45231,
  "output_tokens": 1847,
  "cache_read_input_tokens": 38000,
  "cache_creation_input_tokens": 5000
}
```

## Uninstall

```bash
bash ~/.claude/install-token-tracker.sh --uninstall
```

This removes hook files, cleans `settings.json`, and clears temp files. Your `usage-config.json` and `token-log.jsonl` are preserved -- delete them manually if you want a full cleanup:

```bash
rm ~/.claude/usage-config.json ~/.claude/token-log.jsonl
```

## Compatibility

The installer handles existing configurations gracefully:

| Existing Setup | What Happens |
|---|---|
| No status line | Installs standalone status line |
| GSD status line (`gsd-statusline.js`) | Skips status line (GSD already includes token tracking), adds logger hook |
| Custom status line | Skips status line, prints instructions for manual setup |
| Existing PostToolUse hooks | Appends token logger to the existing hook group |
| Already installed | Idempotent -- skips what's already there |

## Limitations

- **Last-call gap**: The token logger fires on `PostToolUse` events. The final API call of a session (after the last tool use) won't be captured until the next tool use in a future session. This is typically a small amount.
- **Self-calibrated limits**: Weekly limits are estimates based on your reported usage percentage, not official API numbers. Recalibrate periodically for better accuracy.
- **Fallback granularity**: If `token-log.jsonl` is empty (e.g., fresh install), the tracker falls back to `stats-cache.json` which only has day-level granularity. This means the reset-hour boundary won't be precise until the token logger has collected data.
- **Cache delay**: The status line caches results for 5 minutes. After calibrating, the cache is cleared immediately, but normal usage updates appear within 5 minutes.
