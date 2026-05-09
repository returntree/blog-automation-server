from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .settings import get_server_settings


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


class SubscriptionStore:
    def __init__(self, data_file: Path | None = None) -> None:
        settings = get_server_settings()
        default_path = settings.data_dir / "subscription_history.jsonl"
        self.data_file = data_file or default_path
        self.data_file.parent.mkdir(parents=True, exist_ok=True)

    def append_event(
        self,
        username: str,
        change_type: str,
        actor: str = "",
        before: dict[str, Any] | None = None,
        after: dict[str, Any] | None = None,
        details: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        event = {
            "timestamp": _utc_now_iso(),
            "username": username,
            "change_type": change_type,
            "actor": actor or "",
            "before": before,
            "after": after,
            "details": details or {},
        }
        with self.data_file.open("a", encoding="utf-8") as file:
            file.write(json.dumps(event, ensure_ascii=False) + "\n")
        return event

    def _iter_events(self) -> list[dict[str, Any]]:
        if not self.data_file.exists():
            return []
        items: list[dict[str, Any]] = []
        with self.data_file.open("r", encoding="utf-8") as file:
            for line in file:
                text = line.strip()
                if not text:
                    continue
                try:
                    items.append(json.loads(text))
                except json.JSONDecodeError:
                    continue
        return items

    def list_events(
        self,
        username: str | None = None,
        change_type: str | None = None,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        records = self._iter_events()
        if username:
            records = [item for item in records if item.get("username") == username]
        if change_type:
            records = [item for item in records if item.get("change_type") == change_type]
        records.sort(key=lambda item: item.get("timestamp", ""), reverse=True)
        return records[: max(limit, 1)]
