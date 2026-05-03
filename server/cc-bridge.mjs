#!/usr/bin/env node
/**
 * Claude Code Agent SDK bridge — reads prompt from argv, streams NDJSON events to stdout.
 * Called by the Python ClaudeCodeAdapter as a subprocess.
 *
 * Usage: node cc-bridge.mjs <cwd> [--resume <session_id>] <prompt>
 *
 * Output: one JSON object per line:
 *   {"type":"text","text":"..."}
 *   {"type":"tool_start","tool":"Read"}
 *   {"type":"tool_use","tool":"Read","input":{...}}
 *   {"type":"tool_result","content":"..."}
 *   {"type":"result","result":"...","session_id":"...","cost":0.05}
 */

import { query } from "@anthropic-ai/claude-agent-sdk";

const args = process.argv.slice(2);
let cwd = args.shift();
let resumeSessionId = null;
if (args[0] === "--resume") {
  args.shift();
  resumeSessionId = args.shift();
}
const prompt = args.join(" ");

if (!cwd || !prompt) {
  console.error("Usage: node cc-bridge.mjs <cwd> [--resume <id>] <prompt>");
  process.exit(1);
}

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

try {
  const options = {
    maxTurns: 20,
    cwd,
    permissionMode: "bypassPermissions",
    includePartialMessages: true,
  };
  if (resumeSessionId) {
    options.resume = resumeSessionId;
  }

  const q = query({ prompt, options });

  let currentToolName = null;

  for await (const msg of q) {
    switch (msg.type) {
      case "stream_event": {
        const evt = msg.event;
        if (evt.type === "content_block_start") {
          if (evt.content_block?.type === "tool_use") {
            currentToolName = evt.content_block.name;
            emit({ type: "tool_start", tool: currentToolName, id: evt.content_block.id });
          }
        } else if (evt.type === "content_block_delta") {
          if (evt.delta?.type === "text_delta" && evt.delta.text) {
            emit({ type: "text", text: evt.delta.text });
          }
        } else if (evt.type === "content_block_stop") {
          currentToolName = null;
        }
        break;
      }

      case "assistant": {
        const content = msg.message?.content || [];
        for (const block of content) {
          if (block.type === "tool_use") {
            emit({
              type: "tool_use",
              tool: block.name,
              id: block.id,
              input: block.input,
            });
          }
        }
        break;
      }

      case "user": {
        // Tool results
        const content = msg.message?.content || [];
        for (const block of content) {
          if (block.type === "tool_result") {
            let resultContent = block.content;
            if (typeof resultContent !== "string") {
              resultContent = JSON.stringify(resultContent);
            }
            // Truncate large results
            if (resultContent.length > 2000) {
              resultContent = resultContent.substring(0, 2000) + `\n... (${resultContent.length} chars)`;
            }
            emit({ type: "tool_result", id: block.tool_use_id, content: resultContent });
          }
        }
        break;
      }

      case "result": {
        emit({
          type: "result",
          result: msg.result || "",
          session_id: msg.session_id || null,
          cost: msg.cost_usd || 0,
          duration_ms: msg.duration_ms || 0,
          turns: msg.num_turns || 0,
        });
        break;
      }
    }
  }
} catch (err) {
  emit({ type: "error", error: err.message });
  process.exit(1);
}
