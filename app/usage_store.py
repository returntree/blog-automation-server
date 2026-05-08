from __future__ import annotations

import json
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .settings import get_server_settings

METERED_EVENT_TYPES = {
    "draft_generated": "monthly_drafts",
    "image_generated": "monthly_images",
}


class UsageStore:
    def __init__(self, path: Path | None = None) -> None:
        settings = get_server_settings()
        data_dir = settings.data_dir
        data_dir.mkdir(parents=True, exist_ok=True)
        self.path = path or (data_dir / "usage_events.jsonl")

    def append_event(
        self,
        *,
        username: str,
        event_type: str,
        stage: str = "",
        status: str = "",
        details: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        payload = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "username": username,
            "event_type": event_type,
            "stage": stage,
            "status": status,
            "details": details or {},
        }
        with self.path.open("a", encoding="utf-8") as file:
            file.write(json.dumps(payload, ensure_ascii=False) + "\n")
        return payload

    def _iter_events(self) -> list[dict[str, Any]]:
        if not self.path.exists():
            return []

        events: list[dict[str, Any]] = []
        with self.path.open("r", encoding="utf-8") as file:
            for line in file:
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                events.append(event)
        return events

    @staticmethod
    def _parse_timestamp(value: str) -> datetime | None:
        text = str(value or "").strip()
        if not text:
            return None
        try:
            return datetime.fromisoformat(text.replace("Z", "+00:00"))
        except ValueError:
            return None

    def list_events(
        self,
        *,
        username: str | None = None,
        event_type: str | None = None,
        stage: str | None = None,
        status: str | None = None,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        events: list[dict[str, Any]] = []
        for event in self._iter_events():
            if username and event.get("username") != username:
                continue
            if event_type and event.get("event_type") != event_type:
                continue
            if stage and event.get("stage") != stage:
                continue
            if status and event.get("status") != status:
                continue
            events.append(event)

        events.sort(key=lambda item: str(item.get("timestamp", "")), reverse=True)
        return events[: max(1, int(limit))]

    def build_summary(self, *, username: str | None = None) -> dict[str, Any]:
        event_type_counter: Counter[str] = Counter()
        status_counter: Counter[str] = Counter()
        stage_counter: Counter[str] = Counter()
        username_counter: Counter[str] = Counter()
        total_events = 0

        for event in self._iter_events():
            event_username = str(event.get("username", "")).strip()
            if username and event_username != username:
                continue

            total_events += 1
            event_type_counter[str(event.get("event_type", "")).strip() or "unknown"] += 1
            status_counter[str(event.get("status", "")).strip() or "unspecified"] += 1
            stage_counter[str(event.get("stage", "")).strip() or "unspecified"] += 1
            username_counter[event_username or "unknown"] += 1

        return {
            "total_events": total_events,
            "by_event_type": dict(event_type_counter),
            "by_status": dict(status_counter),
            "by_stage": dict(stage_counter),
            "by_username": dict(username_counter),
        }

    def build_current_month_usage(self, *, username: str | None = None) -> dict[str, int]:
        now = datetime.now(timezone.utc)
        counts: Counter[str] = Counter()

        for event in self._iter_events():
            event_username = str(event.get("username", "")).strip()
            if username and event_username != username:
                continue

            event_type = str(event.get("event_type", "")).strip()
            metric_key = METERED_EVENT_TYPES.get(event_type)
            if not metric_key:
                continue

            event_time = self._parse_timestamp(str(event.get("timestamp", "")))
            if event_time is None:
                continue
            if event_time.year != now.year or event_time.month != now.month:
                continue

            counts[metric_key] += 1

        return dict(counts)

    def build_account_overview(self) -> dict[str, dict[str, Any]]:
        overview: dict[str, dict[str, Any]] = {}
        month_usage_map: dict[str, Counter[str]] = {}

        now = datetime.now(timezone.utc)
        for event in self._iter_events():
            username = str(event.get("username", "")).strip() or "unknown"
            item = overview.setdefault(
                username,
                {
                    "username": username,
                    "total_events": 0,
                    "last_event_at": "",
                    "last_event_type": "",
                    "last_stage": "",
                    "last_status": "",
                    "by_event_type": Counter(),
                    "by_status": Counter(),
                },
            )

            item["total_events"] += 1

            event_type = str(event.get("event_type", "")).strip() or "unknown"
            event_status = str(event.get("status", "")).strip() or "unspecified"
            event_stage = str(event.get("stage", "")).strip()
            timestamp = str(event.get("timestamp", "")).strip()

            item["by_event_type"][event_type] += 1
            item["by_status"][event_status] += 1

            metric_key = METERED_EVENT_TYPES.get(event_type)
            event_time = self._parse_timestamp(timestamp)
            if metric_key and event_time and event_time.year == now.year and event_time.month == now.month:
                month_usage_map.setdefault(username, Counter())[metric_key] += 1

            if not item["last_event_at"] or timestamp > item["last_event_at"]:
                item["last_event_at"] = timestamp
                item["last_event_type"] = event_type
                item["last_stage"] = event_stage
                item["last_status"] = event_status

        result: dict[str, dict[str, Any]] = {}
        for username, item in overview.items():
            result[username] = {
                "username": username,
                "total_events": int(item["total_events"]),
                "last_event_at": item["last_event_at"],
                "last_event_type": item["last_event_type"],
                "last_stage": item["last_stage"],
                "last_status": item["last_status"],
                "by_event_type": dict(item["by_event_type"]),
                "by_status": dict(item["by_status"]),
                "current_month_usage": dict(month_usage_map.get(username, Counter())),
            }
        return result
