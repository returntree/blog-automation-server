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
from client_api import call_server_json_with_token, get_admin_account_overview  # noqa: E402


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="서버 계정 목록을 조회합니다.")
    parser.add_argument("--status", help="계정 상태 필터(active, suspended, expired 등)")
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
    parser.add_argument(
        "--overview",
        action="store_true",
        help="사용량 요약까지 포함한 통합 개요를 함께 조회합니다.",
    )
    return parser


def _format_dict(data: dict | None) -> str:
    if not data:
        return "-"
    return ", ".join(f"{key}={value}" for key, value in sorted(data.items()))


def print_accounts(users: list[dict], overview: bool = False) -> int:
    if not users:
        print("조회된 계정이 없습니다.")
        return 0

    print(f"총 {len(users)}개 계정을 조회했습니다.")
    print("-" * 72)
    for index, user in enumerate(users, start=1):
        print(f"[{index}] 계정: {user.get('username')}")
        print(f"    플랜: {user.get('plan_name')}")
        print(f"    좌석 수: {user.get('seats')}")
        print(f"    만료일: {user.get('expires_at') or '없음'}")
        print(f"    상태: {user.get('status')}")
        if overview:
            print(f"    플랜 한도: {_format_dict(user.get('plan_limits'))}")
            print(f"    이번 달 사용량: {_format_dict(user.get('current_month_usage'))}")
            print(f"    사용 이벤트 수: {user.get('total_events', 0)}")
            print(f"    최근 이벤트: {user.get('last_event_type') or '-'}")
            print(f"    최근 단계: {user.get('last_stage') or '-'}")
            print(f"    최근 상태: {user.get('last_status') or '-'}")
            print(f"    최근 시각: {user.get('last_event_at') or '-'}")
        print("-" * 72)
    return 0


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.server_base_url and args.admin_token:
        if args.overview:
            response = get_admin_account_overview(args.server_base_url, args.admin_token)
        else:
            response = call_server_json_with_token(
                args.server_base_url,
                args.admin_token,
                "/admin/accounts",
                payload=None,
                method="GET",
            )
        users = response.get("accounts", [])
    else:
        store = AccountStore()
        data = store._read_data()
        users = data.get("users", [])

    if args.status:
        users = [user for user in users if user.get("status") == args.status]

    return print_accounts(users, overview=args.overview)


if __name__ == "__main__":
    raise SystemExit(main())
