# Offload Development Diary

## 2026-05-04 ~ 05-05: Abstract Projects + Design Philosophy

### What we built
- **Virtual project registry** — projects can exist without a repo (`VirtualProjectManager`, `.offload/projects.json`)
- **Project = execution context, not UI container** — `id` can be `vp-<uuid>` (virtual) or filesystem path (repo-backed)
- **Session move** — `POST /chat/sessions/<id>/move` reassigns sessions between projects
- **Repo binding** — virtual projects can bind to a repo later when the project matures
- **Flat timeline sidebar** — removed project grouping, sessions listed chronologically with project as a label tag

### Design decisions
- **Sidebar is a timeline, not a file manager.** Conversations are the primary unit. Projects are metadata/tags, not navigation hierarchy. This mirrors how iMessage/ChatGPT work — no folders, just recency.
- **Progressive structuring.** Sessions start unstructured (misc), get tagged to projects when the user sees patterns, projects bind to repos when code work begins. Don't force organization upfront.
- **Project still matters** — it's just not a sidebar concept. It determines where CC runs (cwd), what context it has, and what repo it operates on. The pill menu is the project selector.

### Architecture insights captured
- **Harness = infra layer + presentation layer.** Infra gives agents engineering capability (files, sessions, context, execution env). Presentation gives humans supervisory capability (API, events, UI, control).
- **Symmetric API.** Humans (via UI→HTTP) and agents (via file tools) perform the same operations on the same `.offload/` data. No special agent API needed.
- **Deployment model.** v1 = local server + remote phone. v2 = cloud harness (paid) + SSH to dev machines.

### Open items
- Project management UI needs an entry point (pill menu "Manage Projects" or settings page)
- Project settings page (bind repo, rename, delete, view sessions)

---

## 2026-05-03: Agent SDK + CC-Native Rendering

### What we built
- **cc-bridge.mjs** — Node.js bridge to `@anthropic-ai/claude-agent-sdk`, outputs structured NDJSON
- **ClaudeCodeAdapter rewrite** — subprocess calls cc-bridge instead of CLI directly
- **Structured tool events** — `tool_start`, `tool_use` (with full input), `tool_result` (output)
- **Edit diff rendering** — red `-` removed / green `+` added lines, expandable
- **Tool call persistence** — saved in session JSON, restored on reload
- **Colored accent bars** — Read (blue), Edit (yellow), Bash (orange), Write (green), Grep (purple)

### Design decisions
- **Agent SDK over CLI parsing.** CLI stream-json format is unstable and CC-specific. Agent SDK is the official programmatic interface — structured messages, typed events, zero ANSI parsing.
- **Server formats, iOS renders.** Tool descriptions are pre-formatted on the server (`_format_tool_detail`). iOS receives strings, not dicts — avoids AnyCodable limitations.
- **Abandoned pty rendering approach.** CC's `-p` mode doesn't produce rich terminal UI (no colored tool blocks). Interactive mode's TUI can't be driven via pty input. Agent SDK was the correct solution.

### Research findings
- CC `--include-partial-messages` gives `content_block_delta` events for token-level streaming
- CC `--input-format stream-json` exists but the protocol is undocumented and didn't work in testing
- `@anthropic-ai/claude-agent-sdk` npm package is the official way to embed CC programmatically
- Python SDK doesn't exist — Node.js bridge is the practical solution

---

## 2026-05-02: P0-P2 Features + Architecture Reviews

### What we built
- **Cancel** — `POST /chat/sessions/<id>/cancel`, red stop button, message restored to input
- **Session resume resilience** — detect `--resume` failure, inject prior conversation as context insurance
- **CLAUDE.md** — `.offload/CLAUDE.md` tells CC about the harness environment, loaded via `--add-dir`
- **Tool use parsing** — `content_block_start/stop` events parsed for tool name + input
- **Concurrency visibility** — `GET /chat/active` returns running sessions with metadata
- **Session index** — `.offload/chat/index.json` for fast listing
- **Timeout watchdog** — warns at 80%, kills at 100%
- **xterm.js bundled locally** — works offline/LAN-only
- **Markdown rendering** — code blocks with copy button, inline formatting
- **PLANNING.md** — full roadmap with why/why-not/how-to for each feature

### Architecture reviews (2 rounds)
- **Code review** found: watchdog logic bug (loop condition inverted), session index race condition (no lock), path traversal bypass (startswith), WKWebView retain cycle. All fixed.
- **Architecture review** found: "pure agent" memory will hit walls at ~50 sessions (need index), `--resume` is fragile (need fallback), CC CLI is not a stable API (biggest risk). Validated that both-sides-CC and harness-not-smart are correct bets for 0→10 users.

---

## 2026-05-01: CC-Driven Sessions + Terminal UI

### What we built
- **Terminal in UI** — xterm.js in WKWebView, `/pty` WebSocket endpoint, project-aware cwd
- **Agent Adapter protocol** — `ClaudeCodeAdapter` + `PTYAdapter`
- **OffloadSession** — replaces ChatManager, CC-driven (no Anthropic API key needed)
- **Token-level streaming** — `--include-partial-messages` with `content_block_delta`
- **Session resume** — `--resume <session_id>` for conversation continuity
- **Auto-create session** — first message creates session bound to current project
- **Session history restore** — loads last session on app launch
- **PR #1** created with all changes

### Key decision
Started with Anthropic SDK orchestrator + CC executor (two-layer). User said "both sides should be CC" — simplified to single CC process per session. No API key management, CC handles its own auth. This was the right call.

---

## 2026-04-29: Branch Created

Branch `feat/terminal-ui` created from main. Initial goal: render terminal in iOS UI. Evolved into full session architecture rewrite.
