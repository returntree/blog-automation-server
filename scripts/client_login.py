from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

ROOT_DIR = Path(__file__).resolve().parents[1]
CONFIG_DIR = ROOT_DIR / "config"
CLIENT_SETTINGS_PATH = CONFIG_DIR / "client_settings.json"


def load_settings() -> dict[str, Any]:
    if CLIENT_SETTINGS_PATH.exists():
        with CLIENT_SETTINGS_PATH.open("r", encoding="utf-8-sig") as file:
            return json.load(file)
    return {}


def save_settings(settings: dict[str, Any]) -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with CLIENT_SETTINGS_PATH.open("w", encoding="utf-8") as file:
        json.dump(settings, file, ensure_ascii=False, indent=2)


def login(base_url: str, username: str, password: str) -> dict[str, Any]:
    payload = {
        "username": username,
        "password": password,
    }
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/auth/login",
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
        headers={"Content-Type": "application/json; charset=utf-8"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"로그인 요청 실패({exc.code}): {raw}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"서버 연결 실패: {exc.reason}") from exc


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="blog_automation 클라이언트 로그인")
    parser.add_argument("--server-base-url", required=True, help="예: http://127.0.0.1:8000")
    parser.add_argument("--username", required=True, help="계정 아이디")
    parser.add_argument("--password", required=True, help="계정 비밀번호")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    response = login(args.server_base_url, args.username, args.password)
    token = response.get("access_token")
    account = response.get("account") or {}
    if not token:
        raise RuntimeError("로그인 응답에 access_token이 없습니다.")

    settings = load_settings()
    settings["client_mode"] = "server"
    settings["server_base_url"] = args.server_base_url.rstrip("/")
    settings["api_auth_token"] = token
    settings["username"] = args.username
    settings["plan_name"] = account.get("plan_name")
    settings["account_status"] = account.get("status")
    settings["account_expires_at"] = account.get("expires_at")
    save_settings(settings)

    print("로그인 성공")
    print(f"계정: {args.username}")
    print(f"플랜: {account.get('plan_name', 'unknown')}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"로그인 실패: {exc}", file=sys.stderr)
        raise
