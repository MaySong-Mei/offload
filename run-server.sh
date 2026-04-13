#!/bin/bash
# Auto-restart wrapper for the offload server.
# Restarts on crash (exit != 0 and != SIGINT/SIGTERM).

PROJECTS_ROOT="${1:-$HOME/code}"

while true; do
    echo "[$(date '+%H:%M:%S')] Starting offload server (projects-root=$PROJECTS_ROOT)..."
    /opt/homebrew/bin/python3.12 -m server.offload --projects-root "$PROJECTS_ROOT"
    EXIT_CODE=$?

    # Clean exit (Ctrl-C or SIGTERM) — don't restart
    if [ $EXIT_CODE -eq 0 ] || [ $EXIT_CODE -eq 130 ] || [ $EXIT_CODE -eq 143 ]; then
        echo "[$(date '+%H:%M:%S')] Server stopped cleanly (exit $EXIT_CODE)."
        break
    fi

    echo "[$(date '+%H:%M:%S')] Server crashed (exit $EXIT_CODE). Restarting in 2s..."
    sleep 2
done
