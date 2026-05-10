from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

ROOT_DIR = Path(__file__).resolve().parents[1]
CLIENT_SETTINGS_PATH = ROOT_DIR / "config" / "client_settings.json"


def load_client_settings() -> dict[str, Any]:
    if not CLIENT_SETTINGS_PATH.exists():
        return {}
    try:
        return json.loads(CLIENT_SETTINGS_PATH.read_text(encoding="utf-8-sig"))
    except Exception:
        return {}


def normalize_base_url(value: str) -> str:
    value = value.strip().rstrip("/")
    if not value:
        raise ValueError("서버 주소가 비어 있습니다.")
    if not value.startswith(("http://", "https://")):
        value = "https://" + value
    return value


def request_json(method: str, url: str, payload: dict[str, Any] | None = None, token: str | None = None) -> dict[str, Any]:
    body = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json; charset=utf-8"
    if token:
        headers["Authorization"] = f"Bearer {token}"

    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=90) as response:
            raw = response.read().decode("utf-8", errors="replace")
            if not raw.strip():
                return {}
            return json.loads(raw)
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code}: {raw}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"서버 연결 실패: {exc.reason}") from exc


def print_ok(message: str) -> None:
    print(f"[확인] {message}")


def print_skip(message: str) -> None:
    print(f"[건너뜀] {message}")


def main() -> int:
    settings = load_client_settings()
    parser = argparse.ArgumentParser(description="blog_automation 서버 배포 상태를 빠르게 점검합니다.")
    parser.add_argument("--server-base-url", default=os.environ.get("BLOG_AUTOMATION_SERVER_URL") or settings.get("server_base_url") or "")
    parser.add_argument("--username", default=os.environ.get("BLOG_AUTOMATION_USERNAME") or settings.get("username") or "")
    parser.add_argument("--password", default=os.environ.get("BLOG_AUTOMATION_PASSWORD") or "")
    parser.add_argument("--token", default=os.environ.get("BLOG_AUTOMATION_CLIENT_TOKEN") or settings.get("access_token") or "")
    args = parser.parse_args()

    try:
        base_url = normalize_base_url(args.server_base_url)
        print(f"서버 주소: {base_url}")

        health = request_json("GET", f"{base_url}/health")
        if not health.get("ok"):
            raise RuntimeError(f"/health 응답이 정상 형식이 아닙니다: {health}")
        print_ok("/health 정상")

        plans = request_json("GET", f"{base_url}/plans")
        if isinstance(plans, dict) and "plans" in plans:
            count = len(plans.get("plans") or [])
        elif isinstance(plans, list):
            count = len(plans)
        else:
            count = 0
        print_ok(f"/plans 정상, 플랜 {count}개 확인")

        token = args.token.strip()
        if args.username.strip() and args.password.strip():
            login = request_json(
                "POST",
                f"{base_url}/auth/login",
                {"username": args.username.strip(), "password": args.password.strip()},
            )
            token = str(login.get("access_token") or login.get("token") or token).strip()
            account = login.get("account") or login.get("user") or {}
            print_ok(f"로그인 정상: {account.get('username', args.username.strip())}")
        else:
            print_skip("아이디/비밀번호가 없어 로그인 테스트는 건너뜁니다.")

        if token:
            subscription = request_json("GET", f"{base_url}/subscription/me", token=token)
            plan = subscription.get("plan") or subscription.get("plan_name") or subscription.get("subscription", {}).get("plan")
            status = subscription.get("status") or subscription.get("account_status") or subscription.get("subscription", {}).get("status")
            print_ok(f"구독 상태 확인: plan={plan or 'unknown'}, status={status or 'unknown'}")
        else:
            print_skip("토큰이 없어 /subscription/me 테스트는 건너뜁니다.")

        print("서버 기본 점검이 완료되었습니다.")
        return 0
    except Exception as exc:
        print(f"[실패] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
