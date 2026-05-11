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
        description="blog_automation 서버 계정을 생성하거나 갱신합니다."
    )
    parser.add_argument("--username", required=True, help="계정 아이디")
    parser.add_argument("--password", required=True, help="계정 비밀번호")
    parser.add_argument("--plan", default="starter", help="플랜 이름")
    parser.add_argument("--seats", type=int, default=1, help="사용 좌석 수")
    parser.add_argument("--expires-at", default=None, help="만료일 예: 2026-12-31")
    parser.add_argument("--status", default="active", help="계정 상태")
    parser.add_argument("--notes", default="", help="메모")
    parser.add_argument(
        "--server-base-url",
        default=os.environ.get("BLOG_AUTOMATION_SERVER_URL", ""),
        help="서버 API 주소",
    )
    parser.add_argument(
        "--admin-token",
        default=os.environ.get("BLOG_AUTOMATION_ADMIN_TOKEN", ""),
        help="관리자 토큰",
    )
    return parser.parse_args()


def print_account(account: dict) -> None:
    print("계정 저장 완료")
    print(f"계정: {account['username']}")
    print(f"플랜: {account.get('plan_name') or ''}")
    print(f"좌석 수: {account.get('seats') or 0}")
    print(f"만료일: {account.get('expires_at') or ''}")
    print(f"상태: {account.get('status') or ''}")


def main() -> int:
    args = parse_args()

    if args.server_base_url and args.admin_token:
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
            print(f"서버 계정 저장 실패: {exc}", file=sys.stderr)
            return 1
        print_account(response["account"])
        return 0

    from app.account_store import AccountStore  # noqa: E402
    from app.auth import revoke_user_tokens  # noqa: E402

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
    revoke_user_tokens(args.username)
    print_account(account)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
