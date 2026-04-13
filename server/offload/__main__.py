from __future__ import annotations

import argparse
import os
import socket
from pathlib import Path

from .http import create_http_server
from .projects import ProjectScanner
from .repo_offload import InitRunner
from .service import HarnessService
from .tunnel import TunnelManager


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the Offload harness server.")
    parser.add_argument("--workspace", default=".offload", help="Workspace root for topic files and SQLite index.")
    parser.add_argument("--host", default="0.0.0.0", help="Bind host (0.0.0.0 for LAN access).")
    parser.add_argument("--port", type=int, default=8080, help="Bind port.")
    parser.add_argument("--projects-root", default=str(Path.home() / "code"), help="Root directory to scan for git projects.")
    args = parser.parse_args()

    workspace = Path(args.workspace).resolve()
    projects_root = Path(args.projects_root).resolve() if args.projects_root else None

    # Discover project paths before creating the service (needed for reindex)
    temp_scanner = ProjectScanner(projects_root)
    project_paths = [p.path for p in temp_scanner.list_projects()]

    service = HarnessService(workspace, project_paths=project_paths)
    init_runner = InitRunner(event_bus=service.event_bus)
    scanner = ProjectScanner(projects_root, init_runner=init_runner)
    tunnel_mgr = TunnelManager(port=args.port)
    server = create_http_server(args.host, args.port, service, scanner=scanner, init_runner=init_runner, auth_token=os.environ.get("OFFLOAD_API_TOKEN"), tunnel_manager=tunnel_mgr)
    try:
        service.start_sensors()
        print(f"Offload server listening on http://{args.host}:{args.port} with workspace {workspace}")

        # LAN IP
        if args.host == "0.0.0.0":
            try:
                s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                s.connect(("8.8.8.8", 80))
                lan_ip = s.getsockname()[0]
                s.close()
                print(f"  LAN: http://{lan_ip}:{args.port}")
            except OSError:
                pass

        # Remote access — probe tunnels
        tunnels = tunnel_mgr.probe_all()
        for t in tunnels:
            if t.status == "connected":
                print(f"  Remote ({t.method}): {t.url}")
            elif t.available:
                print(f"  {t.method}: available but {t.status}")
                # Auto-start cloudflared if tailscale not connected
                if t.method == "cloudflared" and not any(x.status == "connected" for x in tunnels):
                    print(f"  Starting cloudflared tunnel...")
                    result = tunnel_mgr.start_cloudflared()
                    if result and result.url:
                        print(f"  Remote (cloudflared): {result.url}")
                    elif result:
                        print(f"  cloudflared failed: {result.error}")

        print(f"Projects root: {projects_root}")
        print(f"Sensors: {len(service.sensor_runner.list_sensors())} registered")
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        tunnel_mgr.stop()
        server.server_close()
        service.close()


if __name__ == "__main__":
    main()

