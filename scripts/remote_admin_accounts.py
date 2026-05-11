"""Remote admin helper for blog automation server.

Environment:
  BLOG_AUTOMATION_SERVER_URL=https://your-service.onrender.com
  BLOG_AUTOMATION_ADMIN_TOKEN=your-admin-token

Examples:
  python scripts/remote_admin_accounts.py status
  python scripts/remote_admin_accounts.py plans
  python scripts/remote_admin_accounts.py list
  python scripts/remote_admin_accounts.py create --username user1 --password pass --plan starter
  python scripts/remote_admin_accounts.py set-status --account-id 1 --status active
  python scripts/remote_admin_accounts.py set-subscription --account-id 1 --plan pro --days 30
  python scripts/remote_admin_accounts.py reset-password --account-id 1 --password newpass
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


SERVER_URL_ENV = "BLOG_AUTOMATION_SERVER_URL"
ADMIN_TOKEN_ENV = "BLOG_AUTOMATION_ADMIN_TOKEN"


def env_required(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise SystemExit(f"환경변수 {name} 값이 필요합니다.")
    return value.rstrip("/")


def request_json(method: str, path: str, payload: dict[str, Any] | None = None) -> Any:
    base_url = env_required(SERVER_URL_ENV)
    token = env_required(ADMIN_TOKEN_ENV)
    url = base_url + path
    data = None
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json; charset=utf-8"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            raw = response.read().decode("utf-8")
            return json.loads(raw) if raw else {"ok": True}
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            detail = json.loads(raw)
        except json.JSONDecodeError:
            detail = raw
        raise SystemExit(f"서버 요청 실패: HTTP {exc.code}\n{json.dumps(detail, ensure_ascii=False, indent=2)}")
    except urllib.error.URLError as exc:
        raise SystemExit(f"서버 연결 실패: {exc}")


def print_json(label: str, data: Any) -> None:
    print(label)
    print(json.dumps(data, ensure_ascii=False, indent=2))


def cmd_status(_: argparse.Namespace) -> None:
    print_json("서버 관리자 설정 상태", request_json("GET", "/admin/config/status"))


def cmd_plans(_: argparse.Namespace) -> None:
    print_json("구독 플랜 목록", request_json("GET", "/admin/plans"))


def cmd_list(_: argparse.Namespace) -> None:
    print_json("계정 목록", request_json("GET", "/admin/accounts"))


def cmd_create(args: argparse.Namespace) -> None:
    payload = {
        "username": args.username,
        "password": args.password,
        "plan": args.plan,
        "status": args.status,
    }
    if args.memo:
        payload["memo"] = args.memo
    print_json("계정 생성 결과", request_json("POST", "/admin/accounts", payload))


def cmd_set_status(args: argparse.Namespace) -> None:
    payload = {"status": args.status}
    print_json("계정 상태 변경 결과", request_json("PATCH", f"/admin/accounts/{args.account_id}/status", payload))


def cmd_reset_password(args: argparse.Namespace) -> None:
    payload = {"password": args.password}
    print_json("비밀번호 재설정 결과", request_json("POST", f"/admin/accounts/{args.account_id}/reset-password", payload))


def cmd_set_subscription(args: argparse.Namespace) -> None:
    payload: dict[str, Any] = {"plan": args.plan}
    if args.days is not None:
        payload["days"] = args.days
    if args.expires_at:
        payload["expires_at"] = args.expires_at
    print_json("구독 변경 결과", request_json("PATCH", f"/admin/accounts/{args.account_id}/subscription", payload))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="blog automation 서버 원격 관리자 도구")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("status", help="서버 설정 상태 확인")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("plans", help="구독 플랜 목록 확인")
    p.set_defaults(func=cmd_plans)

    p = sub.add_parser("list", help="계정 목록 확인")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("create", help="계정 생성")
    p.add_argument("--username", required=True)
    p.add_argument("--password", required=True)
    p.add_argument("--plan", default="starter")
    p.add_argument("--status", default="active")
    p.add_argument("--memo", default="")
    p.set_defaults(func=cmd_create)

    p = sub.add_parser("set-status", help="계정 상태 변경")
    p.add_argument("--account-id", required=True, type=int)
    p.add_argument("--status", required=True)
    p.set_defaults(func=cmd_set_status)

    p = sub.add_parser("reset-password", help="계정 비밀번호 재설정")
    p.add_argument("--account-id", required=True, type=int)
    p.add_argument("--password", required=True)
    p.set_defaults(func=cmd_reset_password)

    p = sub.add_parser("set-subscription", help="계정 구독 변경")
    p.add_argument("--account-id", required=True, type=int)
    p.add_argument("--plan", required=True)
    p.add_argument("--days", type=int)
    p.add_argument("--expires-at", default="")
    p.set_defaults(func=cmd_set_subscription)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())