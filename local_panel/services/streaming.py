"""Integration helpers for the remote streaming server."""
from __future__ import annotations

import logging
import os
from typing import Dict, Tuple, Any

import requests

LOGGER = logging.getLogger(__name__)


def _config() -> Dict[str, Any]:
    """Return streaming API configuration derived from environment variables."""
    base = (os.environ.get("STREAMING_API_BASE_URL", "") or "").strip()
    if base.endswith("/"):
        base = base.rstrip("/")
    token = (os.environ.get("STREAMING_API_TOKEN", "") or "").strip()
    timeout_raw = os.environ.get("STREAMING_API_TIMEOUT", "") or "10"
    try:
        timeout = int(timeout_raw)
    except (TypeError, ValueError):
        timeout = 10
    
    # New SSH and reload config
    host = (os.environ.get("STREAM_SERVER_IP", "") or "").strip()
    user = (os.environ.get("STREAMING_SERVER_USER", "") or "").strip()
    password = (os.environ.get("STREAMING_SERVER_PASS", "") or "").strip()
    reload_url = f"http://{host}:5001/channels/reload" if host else ""

    user_endpoint = (os.environ.get("STREAMING_API_USER_ENDPOINT", "/api/users") or "/api/users").strip()
    channel_endpoint = (os.environ.get("STREAMING_API_CHANNEL_ENDPOINT", "/api/channels") or "/api/channels").strip()
    if not user_endpoint.startswith("/"):
        user_endpoint = f"/{user_endpoint}"
    if not channel_endpoint.startswith("/"):
        channel_endpoint = f"/{channel_endpoint}"
    return {
        "base": base,
        "token": token,
        "timeout": timeout if timeout > 0 else 10,
        "user_endpoint": user_endpoint.rstrip("/"),
        "channel_endpoint": channel_endpoint.rstrip("/"),
        "ssh_host": host,
        "ssh_user": user,
        "ssh_pass": password,
        "reload_url": reload_url,
    }


def _request(method: str, path: str, *, json: Dict[str, Any] | None = None, params: Dict[str, Any] | None = None) -> Tuple[bool, Any]:
    """Perform an authenticated HTTP request against the streaming API."""
    cfg = _config()
    if not cfg["base"] or not cfg["token"]:
        # If using file-based sync, we might not have the base API configured, which is fine.
        if "reload" in path:
             pass
        else:
            return True, "Streaming API not configured"

    url = path if path.startswith('http') else f'{cfg["base"]}{path}'
    headers = {
        "Authorization": f'Bearer {cfg["token"]}',
        "Content-Type": "application/json",
    }

    try:
        response = requests.request(
            method,
            url,
            json=json,
            params=params,
            timeout=cfg["timeout"],
            headers=headers,
        )
        response.raise_for_status()
        if response.content and "application/json" in response.headers.get("Content-Type", ""):
            return True, response.json()
        return True, response.text or "ok"
    except Exception as exc:  # noqa: BLE001
        LOGGER.exception("Streaming API request failed: %s %s", method, url)
        return False, str(exc)


class StreamingService:
    """Operations for syncing subscribers and channels to the streaming backend."""

    @staticmethod
    def is_configured() -> bool:
        cfg = _config()
        # Consider it configured if either the API or the SSH details are present
        return bool(cfg["base"] and cfg["token"]) or bool(cfg["ssh_host"] and cfg["ssh_user"] and cfg["ssh_pass"])

    @staticmethod
    def sync_user(user, action: str, plain_password: str | None = None) -> Tuple[bool, Any]:
        """Create, update, or delete a user on the streaming server.

        Args:
            user: User model instance
            action: 'create', 'update', or 'delete'
            plain_password: Plain text password (optional, required for create action)
        """
        cfg = _config()
        endpoint = cfg["user_endpoint"]
        payload = {
            "username": user.username,
            "token": user.token,
            "email": getattr(user, "email", ""),
            "max_connections": getattr(user, "max_connections", 1),
            "is_active": getattr(user, "is_active", True),
            "expires_at": getattr(user, "expiry_date", None).isoformat() if getattr(user, "expiry_date", None) else None,
        }

        # Add password if provided (passwords are not stored in plaintext)
        if plain_password:
            payload["password"] = plain_password

        if action == "create":
            return _request("POST", endpoint, json=payload)
        if action == "update":
            return _request("PUT", f"{endpoint}/{user.username}", json=payload)
        if action == "delete":
            return _request("DELETE", f"{endpoint}/{user.username}")
        return False, f"Unsupported user sync action: {action}"

    @staticmethod
    def sync_channel(channel, action: str) -> Tuple[bool, Any]:
        """Create, update, or delete a channel definition on the streaming server."""
        cfg = _config()
        endpoint = cfg["channel_endpoint"]
        payload = {
            "channel_id": channel.channel_id,
            "name": channel.name,
            "category": channel.category,
            "source_url": channel.source_url,
            "logo_url": getattr(channel, "logo_url", ""),
            "is_active": getattr(channel, "is_active", True),
            "quality": getattr(channel, "quality", "medium"),
        }

        if action == "create":
            return _request("POST", endpoint, json=payload)
        if action == "update":
            return _request("PUT", f"{endpoint}/{channel.channel_id}", json=payload)
        if action == "delete":
            return _request("DELETE", f"{endpoint}/{channel.channel_id}")
        return False, f"Unsupported channel sync action: {action}"

    @staticmethod
    def fetch_channels(limit: int | None = None) -> Tuple[bool, Any]:
        """Retrieve the full channel catalog from the streaming server."""
        cfg = _config()
        params: Dict[str, Any] | None = None
        if limit is not None:
            params = {"limit": limit}
        return _request("GET", cfg["channel_endpoint"], params=params)

    @staticmethod
    def sync_channels_via_file(channels, app) -> Tuple[int, int, list]:
        """
        Syncs channels by generating a channels.txt file, uploading it via SFTP,
        and triggering a reload on the streaming server.
        """
        import io
        import paramiko

        cfg = _config()
        if not all([cfg["ssh_host"], cfg["ssh_user"], cfg["ssh_pass"], cfg["reload_url"]]):
            return 0, len(channels), [getattr(c, 'channel_id', 'unknown') for c in channels]

        content = ""
        for channel in channels:
            fields = [
                str(channel.channel_id or ''),
                str(channel.name or ''),
                str(channel.source_url or ''),
                str(channel.logo_url or ''),
                str(channel.category or 'General'),
                str(channel.quality or 'medium'),
                str(getattr(channel, 'order', '')),
                str(getattr(channel, 'category_order', '')),
            ]
            content += "|".join(fields) + "\n"

        try:
            # Use an in-memory file-like object
            with io.StringIO(content) as file_obj:
                # Establish SSH connection
                with paramiko.SSHClient() as ssh:
                    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
                    ssh.connect(
                        hostname=cfg["ssh_host"],
                        username=cfg["ssh_user"],
                        password=cfg["ssh_pass"],
                        port=22,
                        timeout=15
                    )

                    # Upload the file via SFTP
                    with ssh.open_sftp() as sftp:
                        remote_path = "/opt/streamapp/channels.txt"
                        sftp.putfo(file_obj, remote_path)

            # Trigger the reload endpoint
            success, detail = _request("POST", cfg["reload_url"])
            if not success:
                raise Exception(f"Reload endpoint failed: {detail}")

            # The response from the reload endpoint might contain the count
            if isinstance(detail, dict) and 'count' in detail:
                success_count = detail['count']
                failure_count = len(channels) - success_count
                return success_count, failure_count, []
            
            return len(channels), 0, []

        except Exception as e:
            LOGGER.exception("File-based channel sync failed.")
            return 0, len(channels), [getattr(c, 'channel_id', 'unknown') for c in channels]
