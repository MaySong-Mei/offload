"""Remote access tunnel manager.

On startup, probes for available tunnel methods and activates the best one.
Priority: Tailscale (if connected) > cloudflared > none.

The tunnel status is exposed via /remote endpoint for the iOS client to discover.
"""
from __future__ import annotations

import subprocess
import threading
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional


@dataclass
class TunnelInfo:
    method: str           # "tailscale", "cloudflared", "none"
    available: bool
    url: Optional[str] = None
    ip: Optional[str] = None
    status: str = "disconnected"   # "connected", "connecting", "disconnected", "error"
    error: Optional[str] = None
    version: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "method": self.method,
            "available": self.available,
            "url": self.url,
            "ip": self.ip,
            "status": self.status,
            "error": self.error,
            "version": self.version,
        }


class TunnelManager:
    """Discovers and manages remote access tunnels."""

    def __init__(self, port: int = 8080):
        self._port = port
        self._tunnels: Dict[str, TunnelInfo] = {}
        self._cloudflared_proc: Optional[subprocess.Popen] = None
        self._lock = threading.Lock()

    def probe_all(self) -> List[TunnelInfo]:
        """Probe all supported tunnel methods. Returns list of results."""
        results = []
        results.append(self._probe_tailscale())
        results.append(self._probe_cloudflared())
        with self._lock:
            for t in results:
                self._tunnels[t.method] = t
        return results

    def get_active_tunnel(self) -> Optional[TunnelInfo]:
        """Return the best active tunnel, or None."""
        with self._lock:
            # Prefer tailscale if connected
            ts = self._tunnels.get("tailscale")
            if ts and ts.status == "connected":
                return ts
            # Then cloudflared
            cf = self._tunnels.get("cloudflared")
            if cf and cf.status == "connected":
                return cf
            return None

    def get_all_tunnels(self) -> List[Dict[str, Any]]:
        """Return status of all probed tunnels."""
        with self._lock:
            return [t.to_dict() for t in self._tunnels.values()]

    def start_cloudflared(self) -> Optional[TunnelInfo]:
        """Start a cloudflared quick tunnel. Returns tunnel info with public URL."""
        info = self._tunnels.get("cloudflared")
        if not info or not info.available:
            return None
        if info.status == "connected":
            return info

        try:
            # cloudflared tunnel --url http://localhost:PORT
            # Quick tunnel mode — no account needed, gives a random URL
            proc = subprocess.Popen(
                ["cloudflared", "tunnel", "--url", f"http://localhost:{self._port}"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self._cloudflared_proc = proc

            # cloudflared prints the URL to stderr
            # Read stderr in a thread to find the URL
            url_found = threading.Event()
            tunnel_url: List[str] = []

            def _read_stderr():
                for line in proc.stderr:
                    line = line.strip()
                    if ".trycloudflare.com" in line:
                        # Extract URL
                        import re
                        match = re.search(r'https://[^\s]+\.trycloudflare\.com', line)
                        if match:
                            tunnel_url.append(match.group(0))
                            url_found.set()

            reader = threading.Thread(target=_read_stderr, daemon=True)
            reader.start()

            # Wait up to 15s for URL
            if url_found.wait(timeout=15):
                with self._lock:
                    info.url = tunnel_url[0]
                    info.status = "connected"
                    self._tunnels["cloudflared"] = info
                return info
            else:
                with self._lock:
                    info.status = "error"
                    info.error = "Timed out waiting for tunnel URL"
                    self._tunnels["cloudflared"] = info
                return info

        except Exception as e:
            with self._lock:
                info.status = "error"
                info.error = str(e)
                self._tunnels["cloudflared"] = info
            return info

    def stop(self) -> None:
        """Stop any running tunnels."""
        if self._cloudflared_proc:
            self._cloudflared_proc.terminate()
            try:
                self._cloudflared_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._cloudflared_proc.kill()
            self._cloudflared_proc = None

    # --- Probes ---

    def _probe_tailscale(self) -> TunnelInfo:
        """Check if Tailscale is installed and connected."""
        try:
            version_result = subprocess.run(
                ["tailscale", "version"],
                capture_output=True, text=True, timeout=5,
            )
            if version_result.returncode != 0:
                return TunnelInfo(method="tailscale", available=False, error="tailscale not working")

            version = version_result.stdout.strip().splitlines()[0] if version_result.stdout.strip() else None

            # Check if connected
            status_result = subprocess.run(
                ["tailscale", "status", "--json"],
                capture_output=True, text=True, timeout=5,
            )
            if status_result.returncode == 0:
                import json
                try:
                    data = json.loads(status_result.stdout)
                    backend_state = data.get("BackendState", "")
                    if backend_state == "Running":
                        # Get our tailscale IP
                        ip_result = subprocess.run(
                            ["tailscale", "ip", "-4"],
                            capture_output=True, text=True, timeout=5,
                        )
                        ip = ip_result.stdout.strip() if ip_result.returncode == 0 else None
                        url = f"http://{ip}:{self._port}" if ip else None
                        return TunnelInfo(
                            method="tailscale", available=True, version=version,
                            ip=ip, url=url, status="connected",
                        )
                    else:
                        return TunnelInfo(
                            method="tailscale", available=True, version=version,
                            status="disconnected", error=f"Tailscale state: {backend_state}",
                        )
                except (json.JSONDecodeError, KeyError):
                    pass

            return TunnelInfo(
                method="tailscale", available=True, version=version,
                status="disconnected", error="Could not determine status",
            )

        except FileNotFoundError:
            return TunnelInfo(method="tailscale", available=False, error="Not installed")
        except Exception as e:
            return TunnelInfo(method="tailscale", available=False, error=str(e))

    def _probe_cloudflared(self) -> TunnelInfo:
        """Check if cloudflared is installed."""
        try:
            result = subprocess.run(
                ["cloudflared", "--version"],
                capture_output=True, text=True, timeout=5,
            )
            if result.returncode == 0:
                version = result.stdout.strip().splitlines()[0] if result.stdout.strip() else None
                return TunnelInfo(
                    method="cloudflared", available=True, version=version,
                    status="disconnected",
                )
            return TunnelInfo(method="cloudflared", available=False, error=f"Exit {result.returncode}")
        except FileNotFoundError:
            return TunnelInfo(method="cloudflared", available=False, error="Not installed. brew install cloudflared")
        except Exception as e:
            return TunnelInfo(method="cloudflared", available=False, error=str(e))
