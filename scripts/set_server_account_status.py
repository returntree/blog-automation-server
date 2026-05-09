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
from client_api import call_server_json_with_token  # noqa: E402

VALID_STATUS = {"active", "suspended", "expired", "disabled"}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="서버 계정 상태를 변경합니다.")
    parser.add_argument("username", help="대상 계정 아이디")
    parser.add_argument("status", help="변경할 상태")
    parser.add_argument("--server-base-url", default=os.environ.get("BLOG_AUTOMATION_SERVER_URL", ""), help="서버 API 주소")
    parser.add_argument("--admin-token", default=os.environ.get("BLOG_AUTOMATION_ADMIN_TOKEN", ""), help="관리자 토큰")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    status = args.status.strip().lower()
    if status not in VALID_STATUS:
        parser.error(f"status는 다음 값만 사용할 수 있습니다: {', '.join(sorted(VALID_STATUS))}")

    if args.server_base_url and args.admin_token:
        response = call_server_json_with_token(
            args.server_base_url,
            args.admin_token,
            f"/admin/accounts/{args.username}/status",
            payload={"status": status},
            method="POST",
        )
        print("계정 상태 변경 완료")
        print(f"계정: {response['account']['username']}")
        print(f"새 상태: {response['account']['status']}")
        return 0

    store = AccountStore()
    data = store._read_data()
    users = data.get("users", [])

    for user in users:
        if user.get("username") == args.username:
            user["status"] = status
            store._write_data(data)
            print("계정 상태 변경 완료")
            print(f"계정: {args.username}")
            print(f"새 상태: {status}")
            return 0

    print(f"대상 계정을 찾지 못했습니다: {args.username}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
