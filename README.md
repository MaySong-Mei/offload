# Offload

Offload is a remote-first human-agent harness for turning raw idea dumps into structured topics, feedback loops, plan documents, and manually triggered execution runs.

This repository currently contains:

- A zero-dependency Python server daemon with filesystem-first topic storage, SQLite indexing, REST APIs, and WebSocket event streaming.
- A native iOS SwiftUI client source tree and Xcode project for browsing topics, approving plans, and responding to feedback.

## Server

Run the server from the repository root:

```bash
python3 -m server.offload --workspace .offload --host 127.0.0.1 --port 8080
```

Optional authentication:

```bash
OFFLOAD_API_TOKEN=dev-token python3 -m server.offload --workspace .offload
```

## Tests

```bash
python3 -m unittest discover -s tests -v
```

To validate the iOS client from the command line without signing:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project clients/ios/OffloadClient/OffloadClient.xcodeproj \
  -scheme OffloadClient \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/offload-ios-derived \
  CODE_SIGNING_ALLOWED=NO build
```

## Topic Layout

Each topic is stored under:

```text
<workspace>/topics/<topic-id>/
  topic.md
  requirement.md
  plan.md
  notes.md
  state.json
  feedback/
  runs/
  artifacts/
```

The filesystem is the source of truth. SQLite is used as an index and event store for fast listing, unread feedback queues, and event replay.

## Notes

- The server tests cover topic persistence, approval gates, run artifact writes, and restart reindexing.
- HTTP socket tests may be skipped in restricted sandboxes that do not allow binding a local port.
