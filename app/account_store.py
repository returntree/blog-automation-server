from __future__ import annotations

import hashlib
import json
import secrets
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from .settings import get_server_settings


ACTIVE_ACCOUNT_STATUSES = {"active", "trialing", "paid", "ok"}
_UNSET = object()


class AccountStore:
    def __init__(self) -> None:
        settings = get_server_settings()
        self.root_dir = Path(__file__).resolve().parents[2]
        self.data_dir = settings.data_dir
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.accounts_path = self.data_dir / "accounts.json"
        self.settings = settings
        self._ensure_seed_data()

    def _ensure_seed_data(self) -> None:
        if self.accounts_path.exists():
            return

        demo_record = {
            "users": [
                {
                    "username": self.settings.demo_username,
                    "password_hash": self._hash_password(self.settings.demo_password),
                    "plan_name": self.settings.default_plan,
                    "seats": 1,
                    "expires_at": None,
                    "status": "active",
                    "notes": "기본 데모 계정",
                    "billing_provider": None,
                    "billing_customer_id": None,
                    "billing_subscription_id": None,
                }
            ],
            "tokens": {},
        }
        self._write_data(demo_record)

    def _read_data(self) -> dict[str, Any]:
        with self.accounts_path.open("r", encoding="utf-8") as file:
            return json.load(file)

    def _write_data(self, data: dict[str, Any]) -> None:
        with self.accounts_path.open("w", encoding="utf-8") as file:
            json.dump(data, file, ensure_ascii=False, indent=2)

    @staticmethod
    def _hash_password(password: str) -> str:
        return hashlib.sha256(password.encode("utf-8")).hexdigest()

    def find_user(self, username: str) -> dict[str, Any] | None:
        data = self._read_data()
        for user in data.get("users", []):
            if user.get("username") == username:
                return user
        return None

    def verify_password(self, user: dict[str, Any], password: str) -> bool:
        return user.get("password_hash") == self._hash_password(password)

    @staticmethod
    def _parse_expires_at(expires_at: str | None) -> datetime | None:
        if not expires_at:
            return None

        value = str(expires_at).strip()
        if not value:
            return None

        try:
            if len(value) == 10:
                parsed = datetime.fromisoformat(f"{value}T23:59:59+00:00")
            else:
                normalized = value.replace("Z", "+00:00")
                parsed = datetime.fromisoformat(normalized)
                if parsed.tzinfo is None:
                    parsed = parsed.replace(tzinfo=timezone.utc)
            return parsed.astimezone(timezone.utc)
        except ValueError:
            return None

    def evaluate_account_access(self, account: dict[str, Any]) -> tuple[bool, str]:
        status = str(account.get("status") or "").strip().lower()
        if status not in ACTIVE_ACCOUNT_STATUSES:
            return False, "현재 계정은 활성 상태가 아닙니다."

        expires_at = self._parse_expires_at(account.get("expires_at"))
        if expires_at is not None and expires_at < datetime.now(timezone.utc):
            return False, "구독이 만료되어 더 이상 사용할 수 없습니다."

        return True, "사용 가능한 계정입니다."

    def get_plan_limits(self, account: dict[str, Any]) -> dict[str, int]:
        plan_name = str(account.get("plan_name") or self.settings.default_plan or "starter").strip() or "starter"
        limits = self.settings.plan_limits.get(plan_name, {})
        return {str(key): int(value) for key, value in limits.items()}

    def generate_access_token(self, username: str) -> str:
        data = self._read_data()
        token = secrets.token_urlsafe(32)
        tokens = data.setdefault("tokens", {})
        tokens[token] = username
        self._write_data(data)
        return token

    def find_username_by_token(self, token: str) -> str | None:
        data = self._read_data()
        return data.get("tokens", {}).get(token)

    def revoke_access_token(self, token: str) -> bool:
        data = self._read_data()
        tokens = data.get("tokens", {})
        if token in tokens:
            tokens.pop(token, None)
            self._write_data(data)
            return True
        return False

    def revoke_tokens_for_username(self, username: str) -> int:
        data = self._read_data()
        tokens = data.get("tokens", {})
        removed = [token for token, token_username in tokens.items() if token_username == username]
        for token in removed:
            tokens.pop(token, None)
        if removed:
            self._write_data(data)
        return len(removed)

    def list_accounts(self) -> list[dict[str, Any]]:
        data = self._read_data()
        users = data.get("users", [])
        return sorted(users, key=lambda item: item.get("username", ""))

    def list_billing_accounts(
        self,
        *,
        provider: str | None = None,
        linked_only: bool = True,
    ) -> list[dict[str, Any]]:
        normalized_provider = str(provider or "").strip().lower()
        accounts: list[dict[str, Any]] = []

        for user in self.list_accounts():
            billing_provider = str(user.get("billing_provider") or "").strip()
            billing_customer_id = str(user.get("billing_customer_id") or "").strip()
            billing_subscription_id = str(user.get("billing_subscription_id") or "").strip()

            is_linked = bool(billing_provider or billing_customer_id or billing_subscription_id)
            if linked_only and not is_linked:
                continue
            if normalized_provider and billing_provider.lower() != normalized_provider:
                continue

            accounts.append(user)

        return accounts

    def list_billing_issue_accounts(
        self,
        *,
        provider: str | None = None,
        linked_only: bool = True,
        soon_days: int = 7,
        reference_time: datetime | None = None,
    ) -> list[dict[str, Any]]:
        now_utc = reference_time or datetime.now(timezone.utc)
        accounts: list[dict[str, Any]] = []
        for user in self.list_billing_accounts(provider=provider, linked_only=linked_only):
            issues: list[str] = []
            status = str(user.get("status") or "").strip().lower()
            expires_at = self._parse_expires_at(user.get("expires_at"))
            days_until_expiry: int | None = None

            if not str(user.get("billing_provider") or "").strip():
                issues.append("missing_provider")
            if not str(user.get("billing_customer_id") or "").strip():
                issues.append("missing_customer_id")
            if not str(user.get("billing_subscription_id") or "").strip():
                issues.append("missing_subscription_id")

            if status not in ACTIVE_ACCOUNT_STATUSES:
                issues.append("inactive")

            if expires_at is not None:
                delta = expires_at - now_utc
                days_until_expiry = max(delta.days, 0)
                if expires_at <= now_utc or status == "expired":
                    issues.append("expired")
                elif days_until_expiry <= int(soon_days):
                    issues.append("expiring_soon")
            elif status == "expired":
                issues.append("expired")

            if not issues:
                continue

            item = dict(user)
            item["days_until_expiry"] = days_until_expiry
            item["billing_issues"] = sorted(set(issues))
            accounts.append(item)

        return sorted(
            accounts,
            key=lambda item: (
                0 if "expired" in item.get("billing_issues", []) else 1,
                item.get("days_until_expiry") if item.get("days_until_expiry") is not None else 999999,
                item.get("username", ""),
            ),
        )

    def build_billing_issue_summary(
        self,
        *,
        provider: str | None = None,
        linked_only: bool = True,
        soon_days: int = 7,
        reference_time: datetime | None = None,
    ) -> dict[str, Any]:
        checked_accounts = self.list_billing_accounts(provider=provider, linked_only=linked_only)
        issue_accounts = self.list_billing_issue_accounts(
            provider=provider,
            linked_only=linked_only,
            soon_days=soon_days,
            reference_time=reference_time,
        )

        by_issue_type: dict[str, int] = {}
        by_provider: dict[str, int] = {}
        for item in issue_accounts:
            billing_provider = str(item.get("billing_provider") or "").strip() or "unlinked"
            by_provider[billing_provider] = by_provider.get(billing_provider, 0) + 1
            for issue in item.get("billing_issues", []):
                normalized_issue = str(issue).strip()
                if not normalized_issue:
                    continue
                by_issue_type[normalized_issue] = by_issue_type.get(normalized_issue, 0) + 1

        return {
            "total_accounts_checked": len(checked_accounts),
            "accounts_with_issues": len(issue_accounts),
            "linked_only": linked_only,
            "within_days": int(soon_days),
            "provider_filter": str(provider or "").strip() or None,
            "by_issue_type": dict(sorted(by_issue_type.items(), key=lambda item: item[0])),
            "by_provider": dict(sorted(by_provider.items(), key=lambda item: item[0])),
        }

    def list_expiring_accounts(
        self,
        days: int,
        *,
        reference_time: datetime | None = None,
    ) -> list[dict[str, Any]]:
        now_utc = reference_time or datetime.now(timezone.utc)
        target_utc = now_utc + timedelta(days=int(days))
        expiring: list[dict[str, Any]] = []
        for user in self.list_accounts():
            status = str(user.get("status") or "").strip().lower()
            if status not in ACTIVE_ACCOUNT_STATUSES:
                continue
            expires_at = self._parse_expires_at(user.get("expires_at"))
            if expires_at is None:
                continue
            if now_utc <= expires_at <= target_utc:
                expiring.append(user)
        return sorted(
            expiring,
            key=lambda item: self._parse_expires_at(item.get("expires_at")) or datetime.max.replace(tzinfo=timezone.utc),
        )

    def enforce_expired_accounts(
        self,
        *,
        expired_status: str = "expired",
        reference_time: datetime | None = None,
    ) -> list[dict[str, Any]]:
        now_utc = reference_time or datetime.now(timezone.utc)
        data = self._read_data()
        users = data.get("users", [])
        updated: list[dict[str, Any]] = []
        for user in users:
            status = str(user.get("status") or "").strip().lower()
            if status not in ACTIVE_ACCOUNT_STATUSES:
                continue
            expires_at = self._parse_expires_at(user.get("expires_at"))
            if expires_at is None or expires_at > now_utc:
                continue
            user["status"] = expired_status
            updated.append(dict(user))
        if updated:
            self._write_data(data)
        return sorted(updated, key=lambda item: item.get("username", ""))

    def set_account_status(self, username: str, status: str) -> dict[str, Any] | None:
        data = self._read_data()
        users = data.get("users", [])
        for user in users:
            if user.get("username") == username:
                user["status"] = status
                self._write_data(data)
                return user
        return None

    def update_account_subscription(
        self,
        username: str,
        *,
        plan_name: str | None = None,
        seats: int | None = None,
        expires_at: str | None = None,
        status: str | None = None,
        notes: str | None = None,
    ) -> dict[str, Any] | None:
        data = self._read_data()
        users = data.get("users", [])
        for user in users:
            if user.get("username") != username:
                continue

            if plan_name is not None:
                user["plan_name"] = str(plan_name).strip()
            if seats is not None:
                user["seats"] = int(seats)
            if expires_at is not None:
                cleaned_expires_at = str(expires_at).strip()
                user["expires_at"] = cleaned_expires_at or None
            if status is not None:
                user["status"] = str(status).strip()
            if notes is not None:
                user["notes"] = str(notes)

            self._write_data(data)
            return user
        return None

    def update_account_billing(
        self,
        username: str,
        *,
        billing_provider: Any = _UNSET,
        billing_customer_id: Any = _UNSET,
        billing_subscription_id: Any = _UNSET,
    ) -> dict[str, Any] | None:
        data = self._read_data()
        users = data.get("users", [])

        def _normalize(value: Any) -> Any:
            if value is _UNSET:
                return _UNSET
            if value is None:
                return None
            text = str(value).strip()
            return text or None

        normalized = {
            "billing_provider": _normalize(billing_provider),
            "billing_customer_id": _normalize(billing_customer_id),
            "billing_subscription_id": _normalize(billing_subscription_id),
        }

        for user in users:
            if user.get("username") != username:
                continue
            for key, value in normalized.items():
                if value is not _UNSET:
                    user[key] = value
            self._write_data(data)
            return user
        return None

    def upsert_account(
        self,
        username: str,
        password: str,
        plan_name: str,
        seats: int = 1,
        expires_at: str | None = None,
        status: str = "active",
        notes: str | None = None,
        billing_provider: str | None = None,
        billing_customer_id: str | None = None,
        billing_subscription_id: str | None = None,
    ) -> dict[str, Any]:
        data = self._read_data()
        users = data.setdefault("users", [])
        password_hash = self._hash_password(password)
        new_record = {
            "username": username,
            "password_hash": password_hash,
            "plan_name": plan_name,
            "seats": int(seats),
            "expires_at": expires_at,
            "status": status,
            "notes": notes,
            "billing_provider": billing_provider,
            "billing_customer_id": billing_customer_id,
            "billing_subscription_id": billing_subscription_id,
        }

        for index, user in enumerate(users):
            if user.get("username") == username:
                for key in ("billing_provider", "billing_customer_id", "billing_subscription_id"):
                    if new_record.get(key) is None:
                        new_record[key] = user.get(key)
                users[index] = new_record
                self._write_data(data)
                return new_record

        users.append(new_record)
        self._write_data(data)
        return new_record
