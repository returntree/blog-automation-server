from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys


ROOT_DIR = Path(__file__).resolve().parents[1]
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create or update a blog_automation server account."
    )
    parser.add_argument("--username", required=True, help="Login username")
    parser.add_argument("--password", required=True, help="Login password")
    parser.add_argument("--plan", default="starter", help="Plan name")
    parser.add_argument("--seats", type=int, default=1, help="Seat count")
    parser.add_argument("--expires-at", default=None, help="Expiration date, e.g. 2026-12-31")
    parser.add_argument("--status", default="active", help="Account status")
    parser.add_argument("--notes", default="", help="Admin notes")
    parser.add_argument(
        "--server-base-url",
        default=os.environ.get("BLOG_AUTOMATION_SERVER_URL", ""),
        help="Server API base URL",
    )
    parser.add_argument(
        "--admin-token",
        default=os.environ.get("BLOG_AUTOMATION_ADMIN_TOKEN", ""),
        help="Admin API token",
    )
    return parser.parse_args()


def print_account(account: dict) -> None:
    print("Account saved")
    print(f"username: {account.get('username', '')}")
    print(f"plan_name: {account.get('plan_name', '')}")
    print(f"seats: {account.get('seats', 0)}")
    print(f"expires_at: {account.get('expires_at') or ''}")
    print(f"status: {account.get('status', '')}")


def save_remote(args: argparse.Namespace) -> int:
    from client_api import ClientApiError, call_server_json_with_token  # noqa: E402

    try:
        response = call_server_json_with_token(
            args.server_base_url,
            args.admin_token,
            "/admin/accounts",
            payload={
                "username": args.username,
                "password": args.password,
                "plan_name": args.plan,
                "seats": args.seats,
                "expires_at": args.expires_at,
                "status": args.status,
                "notes": args.notes,
            },
            method="POST",
        )
    except ClientApiError as exc:
        print(f"Remote account save failed: {exc}", file=sys.stderr)
        return 1
    print_account(response.get("account", response))
    return 0


def save_local(args: argparse.Namespace) -> int:
    from app.account_store import AccountStore  # noqa: E402

    store = AccountStore()
    account = store.upsert_account(
        username=args.username,
        password=args.password,
        plan_name=args.plan,
        seats=args.seats,
        expires_at=args.expires_at,
        status=args.status,
        notes=args.notes,
    )
    store.revoke_tokens_for_username(args.username)
    print_account(account)
    return 0


def main() -> int:
    args = parse_args()
    if args.server_base_url and args.admin_token:
        return save_remote(args)
    return save_local(args)


if __name__ == "__main__":
    raise SystemExit(main())
