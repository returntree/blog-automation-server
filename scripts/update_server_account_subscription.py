from __future__ import annotations

import argparse
import os
from pathlib import Path

from account_store import AccountStore
from client_api import call_admin_server_json


ROOT_DIR = Path(__file__).resolve().parents[1]
SERVER_DIR = ROOT_DIR / "server"
DATA_DIR = SERVER_DIR / "data"
ACCOUNTS_FILE = DATA_DIR / "accounts.json"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="서버 계정의 구독 정보를 변경합니다."
    )
    parser.add_argument("username", help="변경할 계정 아이디")
    parser.add_argument("--plan", dest="plan_name", help="플랜 이름")
    parser.add_argument("--seats", type=int, help="좌석 수")
    parser.add_argument("--expires-at", help="만료일(ISO8601 또는 YYYY-MM-DD)")
    parser.add_argument("--status", help="계정 상태(active, paused, expired 등)")
    parser.add_argument("--notes", help="관리 메모")
    parser.add_argument(
        "--server-base-url",
        default=os.getenv("BLOG_AUTOMATION_SERVER_URL", "").strip(),
        help="서버 주소. 미입력 시 로컬 accounts.json을 직접 수정합니다.",
    )
    parser.add_argument(
        "--admin-token",
        default=os.getenv("BLOG_AUTOMATION_ADMIN_TOKEN", "").strip(),
        help="관리자 토큰. 서버 모드에서만 필요합니다.",
    )
    return parser


def print_account_summary(account: dict) -> None:
    print("구독 정보 변경 완료")
    print(f"계정: {account.get('username', '')}")
    print(f"플랜: {account.get('plan_name', '')}")
    print(f"좌석 수: {account.get('seats', '')}")
    print(f"만료일: {account.get('expires_at') or ''}")
    print(f"상태: {account.get('status', '')}")
    if account.get("notes"):
        print(f"메모: {account.get('notes')}")


def update_remote(args: argparse.Namespace) -> int:
    if not args.admin_token:
        raise RuntimeError("서버 모드에서는 관리자 토큰이 필요합니다.")

    payload = {
        "plan_name": args.plan_name,
        "seats": args.seats,
        "expires_at": args.expires_at,
        "status": args.status,
        "notes": args.notes,
    }
    response = call_admin_server_json(
        base_url=args.server_base_url,
        admin_token=args.admin_token,
        endpoint=f"/admin/accounts/{args.username}/subscription",
        payload=payload,
        method="POST",
    )
    print_account_summary(response.get("account") or {})
    return 0


def update_local(args: argparse.Namespace) -> int:
    store = AccountStore(ACCOUNTS_FILE)
    updated = store.update_account_subscription(
        args.username,
        plan_name=args.plan_name,
        seats=args.seats,
        expires_at=args.expires_at,
        status=args.status,
        notes=args.notes,
    )
    if not updated:
        raise RuntimeError(f"계정을 찾지 못했습니다: {args.username}")
    print_account_summary(updated)
    return 0


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if not any(
        value is not None
        for value in (
            args.plan_name,
            args.seats,
            args.expires_at,
            args.status,
            args.notes,
        )
    ):
        raise RuntimeError("변경할 항목을 하나 이상 입력해 주세요.")

    if args.server_base_url:
        return update_remote(args)
    return update_local(args)


if __name__ == "__main__":
    raise SystemExit(main())
