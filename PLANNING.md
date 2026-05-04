# Offload — Planning & Feature Roadmap

> Living document. Updated as the system evolves. Each feature has **Why**, **Why Not** (tradeoffs/risks), and **How To** (implementation path).

## Architecture Summary

Phone captures intent → Harness manages lifecycle & visibility → Claude Code executes in project dir.

Core principles:
- **Harness is transparent, not smart** — routes events, manages sessions, never orchestrates
- **Memory is agent-driven** — `.offload/` is files, agent reads/compacts them, no special APIs
- **Both sides are CC** — no Anthropic SDK, CC manages its own auth
- **Concurrency = visibility + control** — dashboard shows all running agents, user cancels what they want

---

## P0 — Must Have (blocking real usage)

### Cancel Running Session
**Status:** Not started  
**Why:** Without cancel, sending a large task means waiting up to 600s. CC-native feel requires Ctrl+C equivalent. This is the single biggest UX gap.  
**Why Not:** Killing CC mid-edit can leave files in broken state. Need to consider graceful shutdown (SIGTERM → wait → SIGKILL).  
**How To:**
1. Add `POST /chat/sessions/<id>/cancel` endpoint in `http.py`
2. Wire to `OffloadSessionManager.cancel_session(id)` → calls `adapter.stop()`
3. `ClaudeCodeAdapter.stop()` already exists — send SIGTERM, wait 5s, SIGKILL
4. iOS: add cancel button in ChatView when `isChatStreaming || isAgentWorking`
5. Publish `chat.cancelled` event so iOS resets streaming state

### Session Resume Resilience
**Status:** Not started  
**Why:** CC's `--resume` can fail silently if session files are GC'd or corrupted. User loses all conversational context with no warning.  
**Why Not:** Reconstructing context from archive isn't perfect — offload session JSON is a lossy shadow of CC's full session (no tool calls, no reasoning). But lossy recovery >> silent loss.  
**How To:**
1. In `ClaudeCodeAdapter.send()`, detect resume failure: if CC starts a new session_id when we passed `--resume <old_id>`, the resume failed
2. On failure: read last N messages from offload session JSON, build a summary prompt: "Prior conversation summary: [user asked X, you did Y, ...]"
3. Inject summary as first message in the new CC session
4. Publish `chat.status` event: "Session context was reconstructed from archive"
5. Update `adapter_session_id` to the new CC session

### CLAUDE.md for Offload Context
**Status:** Not started  
**Why:** CC reads CLAUDE.md on every session start. This is the natural place to tell CC about `.offload/` structure, how to reference past sessions, project conventions. Without it, CC doesn't know it's running inside an offload harness.  
**Why Not:** CLAUDE.md is version-controlled and visible to all CC sessions (including manual terminal usage). Keep offload-specific guidance light — don't pollute the developer's CLAUDE.md.  
**How To:**
1. Generate `.offload/CLAUDE.md` (not project root) with offload harness context
2. Use CC's `--add-dir .offload` flag to include it
3. Content: explain `.offload/chat/sessions/` structure, how to grep past conversations, when to compact
4. Update `ClaudeCodeAdapter` to pass `--add-dir` pointing to `.offload/`

---

## P1 — Important (quality & reliability)

### Concurrency Visibility Dashboard
**Status:** Partial (agent activity indicator exists)  
**Why:** Multiple sessions can run CC simultaneously. User needs to see all running agents, what they're doing, how long, and cancel any of them. The dashboard IS the control plane.  
**Why Not:** For single-user-on-own-machine, this is rarely needed. But when it is needed, absence is catastrophic (runaway agent, resource exhaustion).  
**How To:**
1. Track all active adapters in `OffloadSessionManager` with metadata (start time, instruction preview, session_id)
2. Add `GET /chat/active` endpoint returning running sessions with status
3. iOS: show running sessions in RightPanelView with elapsed time + cancel button
4. Future: show token burn rate, files being touched

### Parse CC Tool Use Events
**Status:** Not started  
**Why:** CC emits `tool_use` events in stream-json (Read, Edit, Bash, etc). Currently forwarded as opaque blobs. Parsing tool name + first argument gives meaningful activity display ("Editing src/main.py", "Running tests").  
**Why Not:** CC's tool event format isn't stable. Parsing is best-effort — gracefully degrade to "Agent working..." if format changes.  
**How To:**
1. In `ClaudeCodeAdapter`, parse `stream_event` where `event.type == "content_block_start"` and `content_block.type == "tool_use"`
2. Emit `AgentEvent("tool_use", {"tool": name, "input_preview": first_arg[:100]})`
3. In `session.py`, publish as `chat.stream` with `claude_event_type: "agent_tool_use"`
4. iOS: render in ChatView as compact activity line ("✏️ Editing Views.swift")

### Session Index File
**Status:** Not started  
**Why:** At 50+ sessions, CC can't efficiently grep all session files to find relevant history. A lightweight index makes retrieval tractable.  
**Why Not:** Premature optimization for current scale (< 20 sessions). But trivial to implement and extends filesystem memory lifespan 10x.  
**How To:**
1. Maintain `.offload/chat/index.json`: `[{session_id, title, project, created_at, last_message_at, message_count, summary}]`
2. Update on session create and message send (in `_save_session`)
3. CC can read this one file to decide which sessions to look at in detail
4. `list_sessions()` reads index instead of deserializing every JSON file

---

## P2 — Nice to Have (polish & extensibility)

### Graceful Timeout with User Warning
**Status:** Not started  
**Why:** The 600s hard timeout kills CC mid-work. User should be warned before starting a potentially long task.  
**Why Not:** Hard to estimate task duration before execution. CC itself doesn't know how long it'll take.  
**How To:**
1. Make timeout configurable per-session (default 600s)
2. At 80% of timeout, publish a warning event to iOS: "Agent has been running for 8 minutes. Cancel or extend?"
3. iOS: show extend/cancel prompt
4. On timeout: SIGTERM → 10s grace → SIGKILL (not instant kill)

### Bundle xterm.js Locally
**Status:** Not started  
**Why:** terminal.html loads xterm.js from CDN. No internet = broken terminal. LAN-only use case (which is the primary deployment) fails.  
**Why Not:** CDN version auto-updates. Bundled version needs manual updates.  
**How To:**
1. Download xterm.js + addons to `clients/ios/OffloadClient/OffloadClient/Resources/`
2. Update terminal.html to use local paths
3. Add to Xcode project bundle resources

### Agent Ecosystem (non-CC adapters)
**Status:** Protocol ready, no real adapters beyond CC  
**Why:** PTYAdapter exists as universal fallback. Could plug in Aider, Codex, Cursor CLI, etc.  
**Why Not:** No immediate need. CC is the primary agent. Adding adapters before real demand = premature abstraction.  
**How To:**
1. Create `adapters/aider.py` following `PTYAdapter` pattern: spawn `aider --message <instruction>`
2. Add adapter selection in iOS session creation (pill menu)
3. Per-adapter: parse output format if structured, else treat as raw text

### Agent-Driven Memory Compaction
**Status:** Design only  
**Why:** At scale, session files accumulate. Agent should summarize old sessions into `.offload/chat/summaries/`. This is the "memory is an agent problem" principle in practice.  
**Why Not:** Bootstrapping problem — agent needs context about what to keep, which requires reading the memory it's compacting. Token-expensive for large histories. May need a lightweight retrieval tool (SQLite FTS over summaries) as a middle ground.  
**How To:**
1. CLAUDE.md guidance: "when `.offload/chat/sessions/` has > 50 files, summarize old sessions"
2. Agent writes summaries to `.offload/chat/summaries/<year-month>.md`
3. Original sessions can be archived (moved to `sessions/archive/`)
4. Future: add a `search_sessions` tool backed by SQLite FTS for efficient retrieval

### Multi-Agent Conflict Detection
**Status:** Not started  
**Why:** Two concurrent CC sessions editing the same file = silent corruption. The harness should detect and surface this.  
**Why Not:** Rare in single-user setup. Git handles conflict resolution well enough post-facto.  
**How To:**
1. Track files touched per active session (parse tool_use events for file paths)
2. If overlap detected, publish warning to iOS
3. Don't block — just inform. User decides whether to cancel one.

---

## Deferred / Rejected

### Vector DB for Memory
**Rejected.** Adds infrastructure complexity (embedding model, DB process, similarity search tuning) for a problem that's better solved by the agent's own judgment + a simple index file. Revisit only if the index approach proves insufficient at 500+ sessions.

### Anthropic SDK as Orchestrator
**Rejected.** Was the original design, replaced by CC-driven sessions. CC handles auth, tools, context natively. SDK approach requires API key management, manual tool definitions, and duplicates CC's capabilities. Both sides being CC is the correct simplification.

### Rate Limiting Concurrent Sessions
**Rejected.** Artificial limits remove user control. The correct approach is visibility (show what's running) + control (cancel any session). If the machine is thrashing, the user should see that and decide, not hit an opaque "too many sessions" error.

### Persistent WebSocket per Session
**Rejected for now.** Current model: one WebSocket to `/ws`, all events multiplexed. Works because events are tagged with `chat_session_id` and filtered client-side. Per-session WebSocket adds complexity without benefit at current scale.

---

## Change Log

| Date | Change |
|------|--------|
| 2026-05-02 | P1+P2: tool use display, concurrency visibility, session index, timeout, xterm local |
| 2026-05-02 | P0 complete: cancel, session resilience, CLAUDE.md context |
| 2026-05-02 | Initial planning doc created from architecture review findings |
| 2026-05-01 | PR #1: CC-driven sessions, terminal UI, agent adapters, blocker fixes |
| 2026-04-29 | Branch `feat/terminal-ui` created |
