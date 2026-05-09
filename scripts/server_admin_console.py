from __future__ import annotations

import argparse
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from account_store import AccountStore
from auth import revoke_user_tokens
from client_api import ClientApiError, call_admin_server_json
from subscription_store import SubscriptionStore
from usage_store import UsageStore


ROOT_DIR = Path(__file__).resolve().parents[1]
SERVER_DIR = ROOT_DIR / "server"
DATA_DIR = SERVER_DIR / "data"
ACCOUNTS_FILE = DATA_DIR / "accounts.json"
USAGE_FILE = DATA_DIR / "usage_events.jsonl"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="서버 계정, 플랜, 사용량을 한 번에 관리하는 관리자 콘솔입니다."
    )
    parser.add_argument(
        "--server-base-url",
        default=os.getenv("BLOG_AUTOMATION_SERVER_URL", "").strip(),
        help="서버 주소입니다. 비워 두면 로컬 데이터 파일을 직접 수정합니다.",
    )
    parser.add_argument(
        "--admin-token",
        default=os.getenv("BLOG_AUTOMATION_ADMIN_TOKEN", "").strip(),
        help="서버 모드에서 사용할 관리자 토큰입니다.",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("plans", help="플랜 목록 조회")

    accounts_parser = subparsers.add_parser("accounts", help="계정 목록 조회")
    accounts_parser.add_argument("--overview", action="store_true", help="사용량 요약 포함 조회")

    billing_accounts_parser = subparsers.add_parser("billing-accounts", help="결제 연동 계정 조회")
    billing_accounts_parser.add_argument("--provider", help="특정 결제사로만 필터링")
    billing_accounts_parser.add_argument(
        "--all",
        action="store_true",
        help="결제 미연동 계정까지 함께 조회",
    )

    billing_issues_parser = subparsers.add_parser("billing-issues", help="조치 필요한 결제 계정 조회")
    billing_issues_parser.add_argument("--provider", help="특정 결제사로만 필터링")
    billing_issues_parser.add_argument(
        "--all",
        action="store_true",
        help="결제 미연동 계정까지 함께 조회",
    )
    billing_issues_parser.add_argument("--days", type=int, default=7, help="만료 임박 기준 일수")

    billing_issue_summary_parser = subparsers.add_parser(
        "billing-issue-summary",
        help="결제 이슈 계정 요약 통계 조회",
    )
    billing_issue_summary_parser.add_argument("--provider", help="특정 결제사로만 필터링")
    billing_issue_summary_parser.add_argument(
        "--all",
        action="store_true",
        help="결제 미연동 계정까지 함께 집계",
    )
    billing_issue_summary_parser.add_argument("--days", type=int, default=7, help="만료 임박 기준 일수")

    create_parser = subparsers.add_parser("create", help="계정 생성")
    create_parser.add_argument("--username", required=True)
    create_parser.add_argument("--password", required=True)
    create_parser.add_argument("--plan", dest="plan_name", default="basic")
    create_parser.add_argument("--seats", type=int, default=1)
    create_parser.add_argument("--expires-at")
    create_parser.add_argument("--status", default="active")
    create_parser.add_argument("--notes")

    status_parser = subparsers.add_parser("set-status", help="계정 상태 변경")
    status_parser.add_argument("--username", required=True)
    status_parser.add_argument("--status", required=True)

    subscription_parser = subparsers.add_parser("set-subscription", help="구독 정보 변경")
    subscription_parser.add_argument("--username", required=True)
    subscription_parser.add_argument("--plan", dest="plan_name")
    subscription_parser.add_argument("--seats", type=int)
    subscription_parser.add_argument("--expires-at")
    subscription_parser.add_argument("--status")
    subscription_parser.add_argument("--notes")

    billing_parser = subparsers.add_parser("set-billing", help="결제 연동 정보 변경")
    billing_parser.add_argument("--username", required=True)
    billing_parser.add_argument("--provider")
    billing_parser.add_argument("--customer-id")
    billing_parser.add_argument("--subscription-id")

    sync_billing_parser = subparsers.add_parser("sync-billing", help="결제사 기준으로 구독 상태 동기화")
    sync_billing_parser.add_argument("--username", required=True)
    sync_billing_parser.add_argument("--billing-token")
    sync_billing_parser.add_argument("--billing-provider")
    sync_billing_parser.add_argument("--billing-customer-id")
    sync_billing_parser.add_argument("--billing-subscription-id")
    sync_billing_parser.add_argument("--plan-name")
    sync_billing_parser.add_argument("--seats", type=int)
    sync_billing_parser.add_argument("--expires-at")
    sync_billing_parser.add_argument("--status")
    sync_billing_parser.add_argument("--notes")
    sync_billing_parser.add_argument("--event-type", default="billing_sync")
    sync_billing_parser.add_argument("--source", default="billing_provider")

    extend_parser = subparsers.add_parser("extend-expiry", help="구독 만료일 연장")
    extend_parser.add_argument("--username", required=True)
    extend_parser.add_argument("--days", type=int, required=True)
    extend_parser.add_argument("--notes")

    upgrade_parser = subparsers.add_parser("upgrade-plan", help="플랜 업그레이드")
    upgrade_parser.add_argument("--username", required=True)
    upgrade_parser.add_argument("--plan", dest="plan_name", required=True)
    upgrade_parser.add_argument("--seats", type=int)
    upgrade_parser.add_argument("--expires-at")
    upgrade_parser.add_argument("--notes")

    expiring_parser = subparsers.add_parser("expiring-soon", help="만료 임박 계정 조회")
    expiring_parser.add_argument("--days", type=int, default=7)

    enforce_parser = subparsers.add_parser("enforce-expiry", help="만료 계정을 expired 상태로 일괄 전환")
    enforce_parser.add_argument("--status", default="expired")

    password_parser = subparsers.add_parser("reset-password", help="비밀번호 재설정")
    password_parser.add_argument("--username", required=True)
    password_parser.add_argument("--password", required=True)

    events_parser = subparsers.add_parser("usage-events", help="사용 이벤트 조회")
    events_parser.add_argument("--username")
    events_parser.add_argument("--event-type")
    events_parser.add_argument("--stage")
    events_parser.add_argument("--status")
    events_parser.add_argument("--limit", type=int, default=20)

    summary_parser = subparsers.add_parser("usage-summary", help="사용량 요약 조회")
    summary_parser.add_argument("--username")

    history_parser = subparsers.add_parser("history", help="계정 변경 이력 조회")
    history_parser.add_argument("--username", required=True)
    history_parser.add_argument("--change-type")
    history_parser.add_argument("--limit", type=int, default=20)

    return parser


def is_remote_mode(args: argparse.Namespace) -> bool:
    return bool(args.server_base_url)


def require_admin_token(args: argparse.Namespace) -> None:
    if is_remote_mode(args) and not args.admin_token:
        raise RuntimeError("?쒕쾭 紐⑤뱶?먯꽌??愿由ъ옄 ?좏겙???꾩슂?⑸땲??")


def print_json(data: Any) -> None:
    print(json.dumps(data, ensure_ascii=False, indent=2))


def print_account(account: dict[str, Any]) -> None:
    print(f"- 계정: {account.get('username', '')}")
    print(f"  상태: {account.get('status', '')}")
    print(f"  플랜: {account.get('plan_name', '')}")
    print(f"  좌석 수: {account.get('seats', '')}")
    print(f"  만료일: {account.get('expires_at') or ''}")
    if "days_until_expiry" in account:
        print(f"  만료까지: {account.get('days_until_expiry')}일")
    if account.get("notes"):
        print(f"  메모: {account.get('notes')}")
    if account.get("billing_provider"):
        print(f"  결제사: {account.get('billing_provider')}")
    if account.get("billing_customer_id"):
        print(f"  怨좉컼 ID: {account.get('billing_customer_id')}")
    if account.get("billing_subscription_id"):
        print(f"  援щ룆 ID: {account.get('billing_subscription_id')}")
    if "drafts_used_this_month" in account or "images_used_this_month" in account:
        print(
            f"  이번 달 사용량: 초안 {account.get('drafts_used_this_month', 0)}, "
            f"이미지 {account.get('images_used_this_month', 0)}"
        )
    if "last_event_at" in account:
        print(f"  최근 사용 시각: {account.get('last_event_at') or ''}")
        print(f"  최근 단계: {account.get('last_stage') or ''}")
        print(f"  최근 상태: {account.get('last_status') or ''}")


def print_account_list(accounts: list[dict[str, Any]]) -> None:
    if not accounts:
        print("議고쉶??怨꾩젙???놁뒿?덈떎.")
        return
    print(f"珥?{len(accounts)}媛?怨꾩젙")
    for account in accounts:
        print_account(account)


def parse_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    normalized = value.strip()
    if not normalized:
        return None
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def format_datetime(value: datetime | None) -> str | None:
    if value is None:
        return None
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def get_account_record(args: argparse.Namespace, username: str) -> dict[str, Any]:
    if is_remote_mode(args):
        response = call_admin_server_json(
            base_url=args.server_base_url,
            admin_token=args.admin_token,
            endpoint="/admin/accounts/overview",
            method="GET",
        )
        for item in response.get("accounts", []):
            if item.get("username") == username:
                return item
        raise RuntimeError(f"怨꾩젙??李얠? 紐삵뻽?듬땲?? {username}")

    account = AccountStore().find_user(username)
    if not account:
        raise RuntimeError(f"怨꾩젙??李얠? 紐삵뻽?듬땲?? {username}")
    return account


def apply_subscription_update(
    args: argparse.Namespace,
    username: str,
    *,
    plan_name: str | None = None,
    seats: int | None = None,
    expires_at: str | None = None,
    status: str | None = None,
    notes: str | None = None,
    success_message: str = "援щ룆 ?뺣낫 蹂寃??꾨즺",
) -> int:
    payload = {
        "plan_name": plan_name,
        "seats": seats,
        "expires_at": expires_at,
        "status": status,
        "notes": notes,
    }

    if is_remote_mode(args):
        response = call_admin_server_json(
            base_url=args.server_base_url,
            admin_token=args.admin_token,
            endpoint=f"/admin/accounts/{username}/subscription",
            payload=payload,
            method="POST",
        )
        print(success_message)
        print_account(response.get("account", {}))
        return 0

    store = AccountStore()
    account = store.update_account_subscription(
        username,
        plan_name=plan_name,
        seats=seats,
        expires_at=expires_at,
        status=status,
        notes=notes,
    )
    if not account:
        raise RuntimeError(f"怨꾩젙??李얠? 紐삵뻽?듬땲?? {username}")
    revoke_user_tokens(username)
    print(success_message)
    print_account(account)
    return 0


def handle_plans(args: argparse.Namespace) -> int:
    if is_remote_mode(args):
        response = call_admin_server_json(
            base_url=args.server_base_url,
            admin_token=args.admin_token,
            endpoint="/plans",
            method="GET",
        )
        print_json(response)
        return 0

    store = AccountStore()
    print_json(store.plan_limits)
    return 0


def handle_accounts(args: argparse.Namespace) -> int:
    if is_remote_mode(args):
        endpoint = "/admin/accounts/overview" if args.overview else "/admin/accounts"
        response = call_admin_server_json(
            base_url=args.server_base_url,
            admin_token=args.admin_token,
            endpoint=endpoint,
            method="GET",
        )
        print_account_list(response.get("accounts", []))
        return 0

    store = AccountStore()
    accounts = store.list_accounts()
    if args.overview:
        overview_map = {
            item.get("username", ""): item
            for item in UsageStore().build_account_overview()
        }
        merged: list[dict[str, Any]] = []
        for account in accounts:
            extra = overview_map.get(account.get("username", ""), {})
            merged.append({**account, **extra})
        print_account_list(merged)
        return 0

    print_account_list(accounts)
    return 0


def handle_billing_accounts(args: argparse.Namespace) -> int:
    linked_only = not args.all

    if is_remote_mode(args):
        query_parts: list[str] = []
        if args.provider:
            query_parts.append(f"provider={urllib.parse.quote(str(args.provider))}")
        if not linked_only:
            query_parts.append("linked_only=false")

        endpoint = "/admin/accounts/billing"
        if query_parts:
            endpoint = f"{endpoint}?{'&'.join(query_parts)}"

        response = call_admin_server_json(
            base_url=args.server_base_url,
            admin_token=args.admin_token,
            endpoint=endpoint,
            method="GET",
        )
        print_account_list(response.get("accounts", []))
        return 0

    accounts = AccountStore().list_billing_accounts(
        provider=args.provider,
        linked_only=linked_only,
    )
    print_account_list(accounts)
    return 0


def handle_billing_issues(args: argparse.Namespace) -> int:
    linked_only = not args.all
    within_days = max(int(args.days or 7), 0)

    if is_remote_mode(args):
        query_parts: list[str] = [f"within_days={within_days}"]
        if args.provider:
            query_parts.append(f"provider={urllib.parse.quote(str(args.provider))}")
        if not linked_only:
            query_parts.append("linked_only=false")

        endpoint = f"/admin/accounts/billing-issues?{'&'.join(query_parts)}"
        response = call_admin_server_json(
            base_url=args.server_base_url,
            admin_token=args.admin_token,
            endpoint=endpoint,
            method="GET",
        )
        print_account_list(response.get("accounts", []))
        return 0

    accounts = AccountStore().list_billing_issue_accounts(
        provider=args.provider,
        linked_only=linked_only,
        soon_days=within_days,
    )
    print_account_list(accounts)
    return 0


def print_billing_issue_summary(summary: dict[str, Any]) -> None:
    print("결제 이슈 요약")
    print(f"- 점검한 계정 수: {summary.get('total_accounts_checked', 0)}")
    print(f"- 이슈가 있는 계정 수: {summary.get('accounts_with_issues', 0)}")
    print(f"- 결제 연동 계정만 포함: {'예' if summary.get('linked_only', True) else '아니오'}")
    print(f"- 만료 임박 기준: {summary.get('within_days', 7)}일")
    if summary.get("provider_filter"):
        print(f"- 결제사 필터: {summary.get('provider_filter')}")

    by_issue_type = summary.get("by_issue_type", {}) or {}
    if by_issue_type:
        print("- 이슈 유형별:")
        for issue_name, count in by_issue_type.items():
            print(f"  - {issue_name}: {count}")
    else:
        print("- 이슈 유형별: 없음")

    by_provider = summary.get("by_provider", {}) or {}
    if by_provider:
        print("- 결제사별 이슈 계정:")
        for provider_name, count in by_provider.items():
            print(f"  - {provider_name}: {count}")
    else:
        print("- 결제사별 이슈 계정: 없음")


def handle_billing_issue_summary(args: argparse.Namespace) -> int:
    linked_only = not args.all
    within_days = max(int(args.days or 7), 0)

    if is_remote_mode(args):
        query_parts: list[str] = [f"within_days={within_days}"]
        if args.provider:
            query_parts.append(f"provider={urllib.parse.quote(str(args.provider))}")
        if not linked_only:
            query_parts.append("linked_only=false")

        endpoint = f"/admin/accounts/billing-issues/summary?{'&'.join(query_parts)}"
        response = call_admin_server_json(
            base_url=args.server_base_url,
            admin_token=args.admin_token,
            endpoint=endpoint,
            method="GET",
        )
        print_billing_issue_summary(response)
        return 0

    summary = AccountStore().build_billing_issue_summary(
        provider=args.provider,
        linked_only=linked_only,
        soon_days=within_days,
    )
    print_billing_issue_summary(summary)
    return 0


def handle_create(args: argparse.Namespace) -> int:
    payload = {
        "username": args.username,
        "password": args.password,
        "plan_name": args.plan_name,
        "seats": args.seats,
        "expires_at": args.expires_at,
        "status": args.status,
        "notes": args.notes,
    }

    if is_remote_mode(args):
        response = call_admin_server_json(
            base_url=args.server_base_url,
            admin_token=args.admin_token,
            endpoint="/admin/accounts",
            payload=payload,
            method="POST",
        )
        print("怨꾩젙 ?앹꽦 ?꾨즺")
        print_account(response.get("account", {}))
        return 0

    store = AccountStore()
    account = store.upsert_account(
        username=args.username,
        password=args.password,
        plan_name=args.plan_name,
        seats=args.seats,
        expires_at=args.expires_at,
        status=args.status,
        notes=args.notes,
    )
    print("怨꾩젙 ?앹꽦 ?꾨즺")
    print_account(account)
    return 0


def handle_set_status(args: argparse.Namespace) -> int:
    if is_remote_mode(args):
        response = call_admin_server_json(
            base_url=args.server_base_url,
            admin_token=args.admin_token,
            endpoint=f"/admin/accounts/{args.username}/status",
            payload={"status": args.status},
            method="POST",
        )
        print("怨꾩젙 ?곹깭 蹂寃??꾨즺")
        print_account(response.get("account", {}))
        return 0

    store = AccountStore()
    account = store.set_account_status(args.username, args.status)
    if not account:
        raise RuntimeError(f"怨꾩젙??李얠? 紐삵뻽?듬땲?? {args.username}")
    revoke_user_tokens(args.username)
    print("怨꾩젙 ?곹깭 蹂寃??꾨즺")
    print_account(account)
    return 0


def handle_set_subscription(args: argparse.Namespace) -> int:
    return apply_subscription_update(
        args,
        args.username,
        plan_name=args.plan_name,
        seats=args.seats,
        expires_at=args.expires_at,
        status=args.status,
        notes=args.notes,
        success_message="援щ룆 ?뺣낫 蹂寃??꾨즺",
    )


def handle_set_billing(args: argparse.Namespace) -> int:
    if is_remote_mode(args):
        response = call_admin_server_json(
            base_url=args.server_base_url,
            admin_token=args.admin_token,
            endpoint=f"/admin/accounts/{args.username}/billing",
            payload={
                "billing_provider": args.provider,
                "billing_customer_id": args.customer_id,
                "billing_subscription_id": args.subscription_id,
            },
            method="POST",
        )
        print("寃곗젣 ?곕룞 ?뺣낫 蹂寃??꾨즺")
        print_account(response.get("account", {}))
        return 0

    store = AccountStore()
    account = store.update_account_billing(
        args.username,
        billing_provider=args.provider,
        billing_customer_id=args.customer_id,
        billing_subscription_id=args.subscription_id,
    )
    if not account:
        raise RuntimeError(f"怨꾩젙??李얠? 紐삵뻽?듬땲?? {args.username}")
    print("寃곗젣 ?곕룞 ?뺣낫 蹂寃??꾨즺")
    print_account(account)
    return 0


def handle_sync_billing(args: argparse.Namespace) -> int:
    payload: dict[str, Any] = {
        "username": args.username,
        "event_type": args.event_type,
        "source": args.source,
    }
    if args.billing_provider is not None:
        payload["billing_provider"] = args.billing_provider
    if args.billing_customer_id is not None:
        payload["billing_customer_id"] = args.billing_customer_id
    if args.billing_subscription_id is not None:
        payload["billing_subscription_id"] = args.billing_subscription_id
    if args.plan_name is not None:
        payload["plan_name"] = args.plan_name
    if args.seats is not None:
        payload["seats"] = args.seats
    if args.expires_at is not None:
        payload["expires_at"] = args.expires_at
    if args.status is not None:
        payload["status"] = args.status
    if args.notes is not None:
        payload["notes"] = args.notes

    if is_remote_mode(args):
        token = (args.billing_token or os.getenv("BILLING_WEBHOOK_TOKEN", "")).strip()
        if not token:
            raise RuntimeError("서버 모드에서는 결제 동기화 토큰이 필요합니다.")
        request = urllib.request.Request(
            url=f"{args.server_base_url.rstrip('/')}/billing/sync",
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={
                "Content-Type": "application/json; charset=utf-8",
                "X-Billing-Token": token,
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                data = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="ignore")
            raise RuntimeError(f"결제 동기화 요청 실패: HTTP {exc.code} {body}") from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"결제 동기화 요청 실패: {exc}") from exc

        print("결제 동기화 완료")
        print_account(data.get("account", {}))
        return 0

    store = AccountStore()
    account = store.update_account_subscription(
        args.username,
        plan_name=args.plan_name,
        seats=args.seats,
        expires_at=args.expires_at,
        status=args.status,
        notes=args.notes,
    )
    account = store.update_account_billing(
        args.username,
        billing_provider=args.billing_provider,
        billing_customer_id=args.billing_customer_id,
        billing_subscription_id=args.billing_subscription_id,
    ) or account
    if not account:
        raise RuntimeError(f"계정을 찾지 못했습니다. {args.username}")
    print("결제 동기화 완료")
    print_account(account)
    return 0


def handle_extend_expiry(args: argparse.Namespace) -> int:
    account = get_account_record(args, args.username)
    current_expiry = parse_datetime(account.get("expires_at"))
    now_utc = datetime.now(timezone.utc)
    base_time = current_expiry if current_expiry and current_expiry > now_utc else now_utc
    new_expiry = base_time + timedelta(days=args.days)
    merged_notes = args.notes if args.notes is not None else account.get("notes")
    return apply_subscription_update(
        args,
        args.username,
        plan_name=account.get("plan_name"),
        seats=account.get("seats"),
        expires_at=format_datetime(new_expiry),
        status=account.get("status", "active"),
        notes=merged_notes,
        success_message="援щ룆 留뚮즺???곗옣 ?꾨즺",
    )


def handle_upgrade_plan(args: argparse.Namespace) -> int:
    account = get_account_record(args, args.username)
    return apply_subscription_update(
        args,
        args.username,
        plan_name=args.plan_name,
        seats=args.seats if args.seats is not None else account.get("seats"),
        expires_at=args.expires_at if args.expires_at is not None else account.get("expires_at"),
        status=account.get("status", "active"),
        notes=args.notes if args.notes is not None else account.get("notes"),
        success_message="?뚮옖 ?낃렇?덉씠???꾨즺",
    )


def handle_expiring_soon(args: argparse.Namespace) -> int:
    if is_remote_mode(args):
        response = call_admin_server_json(
            base_url=args.server_base_url,
            admin_token=args.admin_token,
            endpoint=f"/admin/accounts/expiring-soon?days={args.days}",
            method="GET",
        )
        print_account_list(response.get("accounts", []))
        return 0

    accounts = AccountStore().list_expiring_accounts(args.days)
    print_account_list(accounts)
    return 0


def handle_enforce_expiry(args: argparse.Namespace) -> int:
    if is_remote_mode(args):
        response = call_admin_server_json(
            base_url=args.server_base_url,
            admin_token=args.admin_token,
            endpoint=f"/admin/accounts/enforce-expiry?expired_status={args.status}",
            method="POST",
        )
        print(response.get("message") or "留뚮즺 怨꾩젙 ?뺣━ ?꾨즺")
        print(f"蹂寃?怨꾩젙 ?? {response.get('updated_count', 0)}")
        print_account_list(response.get("accounts", []))
        return 0

    accounts = AccountStore().enforce_expired_accounts(expired_status=args.status)
    for account in accounts:
        username = account.get("username")
        if username:
            revoke_user_tokens(username)
    print("留뚮즺 怨꾩젙 ?뺣━ ?꾨즺")
    print(f"蹂寃?怨꾩젙 ?? {len(accounts)}")
    print_account_list(accounts)
    return 0


def handle_reset_password(args: argparse.Namespace) -> int:
    if is_remote_mode(args):
        response = call_admin_server_json(
            base_url=args.server_base_url,
            admin_token=args.admin_token,
            endpoint=f"/admin/accounts/{args.username}/reset-password",
            payload={"password": args.password},
            method="POST",
        )
        print("鍮꾨?踰덊샇 ?ъ꽕???꾨즺")
        print_account(response.get("account", {}))
        return 0

    store = AccountStore()
    account = store.find_user(args.username)
    if not account:
        raise RuntimeError(f"怨꾩젙??李얠? 紐삵뻽?듬땲?? {args.username}")
    updated = store.upsert_account(
        username=args.username,
        password=args.password,
        plan_name=account.get("plan_name", "basic"),
        seats=int(account.get("seats", 1)),
        expires_at=account.get("expires_at"),
        status=account.get("status", "active"),
        notes=account.get("notes"),
    )
    revoke_user_tokens(args.username)
    print("鍮꾨?踰덊샇 ?ъ꽕???꾨즺")
    print_account(updated)
    return 0


def handle_usage_events(args: argparse.Namespace) -> int:
    if is_remote_mode(args):
        endpoint = (
            f"/admin/usage/events?limit={args.limit}"
            + (f"&username={args.username}" if args.username else "")
            + (f"&event_type={args.event_type}" if args.event_type else "")
            + (f"&stage={args.stage}" if args.stage else "")
            + (f"&status={args.status}" if args.status else "")
        )
        response = call_admin_server_json(
            base_url=args.server_base_url,
            admin_token=args.admin_token,
            endpoint=endpoint,
            method="GET",
        )
        print_json(response)
        return 0

    store = UsageStore()
    events = store.list_events(
        username=args.username,
        event_type=args.event_type,
        stage=args.stage,
        status=args.status,
        limit=args.limit,
    )
    print_json({"events": events})
    return 0


def handle_usage_summary(args: argparse.Namespace) -> int:
    if is_remote_mode(args):
        endpoint = "/admin/usage/summary"
        if args.username:
            endpoint += f"?username={args.username}"
        response = call_admin_server_json(
            base_url=args.server_base_url,
            admin_token=args.admin_token,
            endpoint=endpoint,
            method="GET",
        )
        print_json(response)
        return 0

    summary = UsageStore().build_summary(username=args.username)
    print_json(summary)
    return 0


def handle_history(args: argparse.Namespace) -> int:
    if is_remote_mode(args):
        endpoint = f"/admin/accounts/{args.username}/history?limit={args.limit}"
        if args.change_type:
            endpoint += f"&change_type={args.change_type}"
        response = call_admin_server_json(
            base_url=args.server_base_url,
            admin_token=args.admin_token,
            endpoint=endpoint,
            method="GET",
        )
        print_json(response)
        return 0

    store = SubscriptionStore()
    items = store.list_events(
        username=args.username,
        change_type=args.change_type,
        limit=args.limit,
    )
    print_json({"ok": True, "items": items})
    return 0


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    require_admin_token(args)

    handlers = {
        "plans": handle_plans,
        "accounts": handle_accounts,
        "billing-accounts": handle_billing_accounts,
        "billing-issues": handle_billing_issues,
        "billing-issue-summary": handle_billing_issue_summary,
        "create": handle_create,
        "set-status": handle_set_status,
        "set-subscription": handle_set_subscription,
        "set-billing": handle_set_billing,
        "sync-billing": handle_sync_billing,
        "extend-expiry": handle_extend_expiry,
        "upgrade-plan": handle_upgrade_plan,
        "expiring-soon": handle_expiring_soon,
        "enforce-expiry": handle_enforce_expiry,
        "reset-password": handle_reset_password,
        "usage-events": handle_usage_events,
        "usage-summary": handle_usage_summary,
        "history": handle_history,
    }

    handler = handlers[args.command]
    try:
        return handler(args)
    except ClientApiError as exc:
        print(f"?쒕쾭 愿由ъ옄 ?묒뾽 ?ㅽ뙣: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
