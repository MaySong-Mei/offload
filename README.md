# Offload

**Offload turns your phone into a remote control for coding agents running on your dev machine.**

Phone captures intent → Harness manages lifecycle → Claude Code executes in your repo.

## Architecture

```
┌──────────────┐              ┌──────────────────────┐            ┌──────────────┐
│   iPhone     │ ──HTTP/WS──► │  Offload Server      │ ──NDJSON──►│ cc-bridge.mjs│
│  (controller)│              │  (Python harness)     │            │ (Agent SDK)  │
└──────────────┘              │  • Session manager    │            └──────┬───────┘
                              │  • Event bus (WS)     │                   │
                              │  • File proxy         │                   ▼
                              │  • SQLite index       │            ┌──────────────┐
                              └──────────┬────────────┘            │ Claude Code  │
                                         │                         │ (in repo dir)│
                                         ▼                         └──────────────┘
                              ┌─────────────────────────────┐
                              │  Repo (your real codebase)  │
                              │  ├── src/                   │
                              │  └── .offload/              │
                              │      ├── CLAUDE.md          │
                              │      ├── context/           │
                              │      ├── chat/sessions/     │
                              │      └── topics/            │
                              └─────────────────────────────┘
```

### Key design principles

- **Harness is transparent, not smart** — routes events, manages sessions, never orchestrates
- **Both sides are CC** — no Anthropic API key needed, CC manages its own auth
- **Memory is agent-driven** — `.offload/` is files, CC reads/compacts them with its own tools
- **Zero-maintenance rendering** — Agent SDK outputs structured data, CC updates don't break us
- **Concurrency = visibility + control** — dashboard shows running agents, user cancels what they want

## Components

| Component | Path | Purpose |
|---|---|---|
| Server | `server/offload/` | Python HTTP/WS server, session manager, event bus |
| Agent SDK bridge | `server/cc-bridge.mjs` | Node.js bridge to `@anthropic-ai/claude-agent-sdk` |
| iOS client | `clients/ios/OffloadClient/` | SwiftUI app: chat, terminal, project dashboard |
| Onboarding template | `server/offload/templates/` | Files copied into `<repo>/.offload/` on init |

## Chat (CC-driven sessions)

Each chat session is backed by a Claude Code process:

- **Token-level streaming** via Agent SDK `includePartialMessages`
- **Session resume** via `--resume <session_id>`, with auto-recovery from archive on failure
- **Cancel** — red stop button terminates CC, restores message to input
- **Tool call rendering** — structured events with colored accent bars:
  - **Read** (blue) — file path, expandable content
  - **Edit** (yellow) — file path + full inline diff (red `-` / green `+`)
  - **Write** (green) — file path + content preview
  - **Bash** (orange) — `$ command  # description` + output
  - **Grep/Glob** (purple) — pattern + results
- **Markdown rendering** — code blocks with copy button, bold/italic/inline code
- **Auto-create session** — first message auto-creates session bound to current project
- **Session history** — persisted to `.offload/chat/sessions/*.json`, restored on app launch
- **Session index** — `.offload/chat/index.json` for fast listing + agent grep

## Terminal

Full xterm.js terminal rendered in WKWebView:

- Connected to server via `/pty` WebSocket
- Project-aware `cwd` — opens in project directory
- Accessible from toolbar, project cards, and dashboard
- xterm.js bundled locally (works offline/LAN-only)

## `.offload/` layout

```
.offload/
├── CLAUDE.md              # Harness context for CC (session storage, guidelines)
├── chat/
│   ├── sessions/          # Chat session JSON files (messages, adapter_session_id)
│   ├── index.json         # Lightweight session index for fast listing
│   └── config.json        # API key storage (optional)
├── context/               # Project knowledge (generated during onboarding)
│   ├── summary.md
│   ├── architecture.md
│   └── conventions.md
├── topics/                # Work items (feature, bug, refactor)
│   └── topic-<id>/
│       ├── requirement.md
│       ├── plan.md
│       └── runs/
└── state.json
```

## Observability

- **`GET /chat/active`** — all running sessions with metadata (project, elapsed time, instruction)
- **Timeout watchdog** — warns at 80% of 600s, kills at 100%
- **Event bus** — all events pushed via WebSocket to iOS in real-time

## Server

```bash
# Start (zero third-party Python deps, needs Node.js for Agent SDK bridge)
bash run-server.sh

# Or manually:
python3 -m server.offload \
  --workspace .offload \
  --host 0.0.0.0 \
  --port 8080 \
  --projects-root ~/code
```

Agent SDK dependency:
```bash
cd server && npm install
```

## iOS client

Open `clients/ios/OffloadClient/OffloadClient.xcodeproj` in Xcode. Point the app at your dev machine's address (Tailscale, LAN IP, or localhost for simulator).

Supports offline editing: mutations queued locally and replayed on reconnect.

## Agent Adapter Protocol

Pluggable interface for coding agents:

```python
class AgentAdapter(Protocol):
    def start(self, cwd: Path) -> None
    def send(self, message: str, on_event: Callable) -> str
    def stop(self) -> None
    def is_running(self) -> bool
    def session_id(self) -> Optional[str]
```

- **ClaudeCodeAdapter** — Agent SDK bridge, token streaming, session resume
- **PTYAdapter** — universal fallback for any CLI agent

## Self-Iteration

On April 14, 2026, Offload successfully used itself to modify its own codebase — the first self-bootstrapping iteration. A topic created via the phone → agent read the iOS source → wrote requirement + plan → executed (deleted 184 lines, added 54) → human reviewed and pushed. The system iterated on itself.

## Status

Active development. See [PLANNING.md](PLANNING.md) for the full roadmap.

## Why "Offload"?

Because the work gets offloaded — from your head to a topic, from your laptop to the dev machine, from you to the agent. You stay on your phone, in the loop, in control.
