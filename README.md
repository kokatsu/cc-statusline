# cc-statusline

A fast statusline for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that displays model info, context usage, cost tracking, and burn rate. Written in Zig for minimal latency.

![screenshot](assets/screenshot.png)

## Features

- **Model & Context** — Current model name, git branch, context window usage with color-coded progress bar (green → yellow → red)
- **Subagent Indicator** — Shows current subagent name (🧩) when running inside a Claude Code subagent
- **200K+ Tier Alert** — 🚨 marker when the conversation has exceeded the 200K-token pricing tier
- **Cost Tracking** — Today's total cost, current block cost (5h window), burn rate per hour
- **Rate Limits** — 5-hour and 7-day usage percentage with color-coded progress bars and reset countdown
- **Smart Caching** — Two-tier binary cache (30s result TTL, 5m file list TTL) with incremental diff parsing for near-zero overhead
- **Pricing** — Supports Fable 5, Mythos 5, Opus 4.8/4.7/4.6/4.5/4.1/4/3, Sonnet 4.6/4.5/4/3.7/3.5, Haiku 4.5/3.5 (including 200K+ tiered pricing and per-model fast mode rates)
- **Theming** — Built-in Catppuccin Mocha theme, fully customizable via environment variables

## Requirements

- Zig 0.16.0+

## Build

```sh
zig build -Doptimize=ReleaseFast
```

The binary is output to `zig-out/bin/cc-statusline`.

## Usage

cc-statusline reads Claude Code's statusline JSON from stdin and outputs ANSI-colored status (2-3 lines depending on available data):

```text
🤖 Opus 4.8 (1M context) | 🌿 main | 🧠 ██████▓░░░ 63%
💰 $26.79 today | 📊 $5.27 block 🔥 $11.33 /h
🕔 5h ████▓░░░░░ 42% 1h 30m 05/08 01:00 | 📅 7d ░░░░░░░░░░ 4% 4d 11h 05/12 08:00
```

### Claude Code Integration

Add to `~/.claude/settings.json`:

```json
{
  "statusline": {
    "command": "/path/to/cc-statusline"
  }
}
```

## Configuration

### Theme

Set `CC_STATUSLINE_THEME` to use a built-in theme:

```sh
export CC_STATUSLINE_THEME=catppuccin-mocha
```

### Color Overrides

Override individual colors with ANSI escape sequences:

| Variable | Description | Default |
|---|---|---|
| `CC_STATUSLINE_COLOR_MODEL` | Model name color | Cyan |
| `CC_STATUSLINE_COLOR_AGENT` | Subagent name color | Magenta |
| `CC_STATUSLINE_COLOR_GREEN` | Low context usage | Green |
| `CC_STATUSLINE_COLOR_YELLOW` | Medium context usage | Yellow |
| `CC_STATUSLINE_COLOR_RED` | High context usage | Red |
| `CC_STATUSLINE_COLOR_DIM` | Separators and labels | Dim |
| `CC_STATUSLINE_BAR_FILLED` | Filled bar character | `█` |
| `CC_STATUSLINE_BAR_TRANSITION` | Transition bar character | `▓` |
| `CC_STATUSLINE_BAR_EMPTY` | Empty bar character | `░` |

### Config Directory

By default, cc-statusline reads from `~/.claude`. Override with:

```sh
export CLAUDE_CONFIG_DIR=/path/to/config
```

## Test

```sh
zig build test
```

## Benchmark

```sh
zig build bench -Doptimize=ReleaseFast
```

Generates synthetic JSONL transcripts at `/tmp/cc-statusline-bench/` (small / medium / large) and reports min / median / p99 for four scenarios:

| scenario              | what it measures                                         |
|-----------------------|----------------------------------------------------------|
| `end-to-end (cold)`   | spawning the binary with the cache file deleted          |
| `end-to-end (warm)`   | spawning with a hot 30s result cache                     |
| `fullScan`            | `scan.benchFullScan` only (parses every JSONL)           |
| `parseJsonlContent`   | the JSONL parser on a single fixture file                |

Child processes run with `CLAUDE_CONFIG_DIR=/tmp/cc-statusline-bench`, so the harness never touches the user's real config dir, cache, or live statusline output.

Useful flags (pass after `--`):

```sh
zig build bench -Doptimize=ReleaseFast -- --save             # record bench/baseline.json
zig build bench -Doptimize=ReleaseFast -- --size=medium      # run only one fixture size
```

When `bench/baseline.json` exists, each row is annotated with its delta vs. the recorded median.

## Acknowledgments

- The transcript scanning logic (5-hour block detection, message+request ID
  deduplication, JSONL field mapping) is derived from
  [ccusage](https://github.com/ryoppippi/ccusage) by @ryoppippi (MIT).
- The `catppuccin-*` themes use color values from the
  [Catppuccin](https://github.com/catppuccin/catppuccin) palette (MIT).

See [LICENSE](./LICENSE) for full third-party copyright notices.
