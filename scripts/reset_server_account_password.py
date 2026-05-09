from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys

ROOT_DIR = Path(__file__).resolve().parents[1]
SERVER_DIR = ROOT_DIR / "server"
if str(SERVER_DIR) not in sys.path:
    sys.path.insert(0, str(SERVER_DIR))

from app.account_store import AccountStore  # noqa: E402
from client_api import ClientApiError, call_server_json_with_token  # noqa: E402


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="blog_automation 서버 계정 비밀번호를 재설정합니다.")
    parser.add_argument("--username", required=True, help="대상 계정 아이디")
    parser.add_argument("--password", required=True, help="새 비밀번호")
    parser.add_argument("--server-base-url", default=os.environ.get("BLOG_AUTOMATION_SERVER_URL", ""), help="서버 API 주소")
    parser.add_argument("--admin-token", default=os.environ.get("BLOG_AUTOMATION_ADMIN_TOKEN", ""), help="관리자 토큰")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if args.server_base_url and args.admin_token:
        response = call_server_json_with_token(
            args.server_base_url,
            args.admin_token,
            f"/admin/accounts/{args.username}/reset-password",
            payload={"password": args.password},
            method="POST",
        )
        print("비밀번호 재설정 완료")
        print(f"계정: {response['account']['username']}")
        print("기존 로그인 토큰은 모두 만료 처리했습니다.")
        return 0

    store = AccountStore()
    account = store.find_user(args.username)
    if account is None:
        raise RuntimeError(f"계정을 찾을 수 없습니다: {args.username}")

    updated = store.upsert_account(
        username=account["username"],
        password=args.password,
        plan_name=account.get("plan_name", "starter"),
        seats=int(account.get("seats", 1)),
        expires_at=account.get("expires_at"),
        status=account.get("status", "active"),
        notes=account.get("notes"),
    )
    store.revoke_tokens_for_username(args.username)

    print("비밀번호 재설정 완료")
    print(f"계정: {updated['username']}")
    print("기존 로그인 토큰은 모두 만료 처리했습니다.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"비밀번호 재설정 실패: {exc}", file=sys.stderr)
        raise
