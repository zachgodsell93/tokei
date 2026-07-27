# AI Usage Monitor

A macOS menu bar app that shows your AI subscription usage at a glance — like iStat Menus, but for your AI rate limits.

It reads the credentials your local CLIs are already signed in with (Claude Code, Codex CLI, Gemini CLI) and shows live usage for:

| Provider | Metrics | Source |
|---|---|---|
| **Claude** (Anthropic) | 5-hour limit, 7-day limit (plus per-model 7-day limits when reported) | Claude Code's OAuth token → `api.anthropic.com/api/oauth/usage` |
| **OpenAI** (Codex) | 5-hour / weekly rate-limit windows, plan, credits | `~/.codex/auth.json` → `chatgpt.com/backend-api/wham/usage` |
| **Gemini** (Google) | Per-tier daily quota (Pro / Flash / Flash Lite) | `~/.gemini/oauth_creds.json` → Code Assist `retrieveUserQuota` |

Everything runs locally. Tokens are read from where the CLIs store them, requests go directly to each provider, and nothing is logged or sent anywhere else.

## Features

- **Menu bar readout** — pin any metric (e.g. Claude 5-hour) and it renders compactly in the menu bar: `C5h 16%  C7d 36%`. Unpin everything for an icon-only look.
- **Popover dashboard** — click the menu bar item for per-provider cards with color-coded usage bars (green → yellow → orange → red), plan badges (Max 20x, Plus, …), and live "resets in 2h 38m" countdowns.
- **Pin from any row** — the pin button on each row controls what shows in the menu bar.
- **Auto-refresh** — every 1/5/15/30 minutes (configurable in the gear menu), plus refresh-on-open and a manual refresh button. Transient network failures keep showing the last good data with a warning.
- **Launch at Login** toggle (when running as the installed app).
- **Graceful states** — providers that aren't signed in show a hint (`run codex login`) instead of an error; providers you don't use can be hidden entirely.

## Install

Requires macOS 14+ and Xcode (or the Xcode Command Line Tools with a Swift 5.9+ toolchain).

```sh
git clone https://github.com/zachgodsell/ai-usage-monitor.git
cd ai-usage-monitor
make install        # builds the .app, copies it to /Applications, and opens it
```

Other targets:

```sh
make check          # headless test: prints live usage for every connected provider
make run            # run the debug build without installing
make app            # just produce build/AI Usage Monitor.app
make test           # unit tests
```

On first launch macOS may ask for permission to read the **"Claude Code-credentials"** keychain item — click **Always Allow** so refreshes work silently.

## How it gets your usage

- **Claude** — Claude Code stores an OAuth token in the macOS Keychain (service `Claude Code-credentials`, with `~/.claude/.credentials.json` as a fallback). The app calls Anthropic's OAuth usage endpoint — the same one Claude Code's `/usage` command uses — which returns utilization percentages and reset times for the 5-hour and 7-day windows. The app never refreshes this token itself (Claude Code rotates it); if it expires, open Claude Code once.
- **OpenAI** — the Codex CLI stores ChatGPT OAuth tokens in `~/.codex/auth.json`. The app calls the usage endpoint behind Codex's `/status` display, which reports each active rate-limit window (5-hour, weekly) with used percent and reset time. If the token expires, run any `codex` command to refresh it.
- **Gemini** — the Gemini CLI stores Google OAuth credentials in `~/.gemini/oauth_creds.json`. Access tokens only last an hour, so the app refreshes them in memory using the Gemini CLI's own public OAuth client (Google refresh tokens are reusable — the CLI's session is unaffected, and nothing is written back). Quota comes from the Code Assist `retrieveUserQuota` endpoint as per-model daily buckets.

## Privacy & safety

- Read-only: the app never writes to any CLI's credential store.
- Tokens never leave your machine except to the provider that issued them.
- No analytics, no third-party services, no background daemons — it's one small local app.

## Troubleshooting

- **Claude shows "token expired"** — open Claude Code (`claude`) once; it refreshes the keychain token, and the next poll picks it up.
- **OpenAI shows "not connected" / rejected** — run `codex login`.
- **Gemini shows "sign-in expired"** — run `gemini` and complete the Google login.
- **Keychain prompt every launch** — rebuild via `make install` (the ad-hoc code signature keeps the "Always Allow" grant stable), or click *Always Allow* instead of *Allow*.

## Development

```sh
swift build && swift test
.build/debug/AIUsageMonitor --check   # live end-to-end fetch, no UI
```

Sources live under `Sources/AIUsageMonitor/`:

- `Services/` — one client per provider plus the polling `UsageStore`
- `Views/` — the popover dashboard and menu bar label
- `Support/` — HTTP/JSON helpers, ISO-8601 parsing, Keychain access
