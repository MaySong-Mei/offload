from __future__ import annotations

import argparse
import os
from pathlib import Path

from .http import create_http_server
from .service import HarnessService


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the Offload harness server.")
    parser.add_argument("--workspace", default=".offload", help="Workspace root for topic files and SQLite index.")
    parser.add_argument("--host", default="127.0.0.1", help="Bind host.")
    parser.add_argument("--port", type=int, default=8080, help="Bind port.")
    args = parser.parse_args()

    workspace = Path(args.workspace).resolve()
    service = HarnessService(workspace)
    server = create_http_server(args.host, args.port, service, auth_token=os.environ.get("OFFLOAD_API_TOKEN"))
    try:
        print(f"Offload server listening on http://{args.host}:{args.port} with workspace {workspace}")
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        service.close()


if __name__ == "__main__":
    main()

