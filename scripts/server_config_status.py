from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request


def _normalize_base_url(value: str) -> str:
    return value.strip().rstrip("/")


def _request_status(base_url: str, token: str) -> dict:
    url = f"{base_url}/admin/config/status"
    request = urllib.request.Request(url)
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Accept", "application/json")
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = response.read().decode("utf-8")
    return json.loads(payload)


def _print_bool(label: str, value: bool, *, warn_only: bool = False) -> bool:
    if value:
        print(f"[확인] {label}")
        return True
    prefix = "[주의]" if warn_only else "[실패]"
    print(f"{prefix} {label}")
    return warn_only


def main() -> int:
    parser = argparse.ArgumentParser(description="Render 서버 환경변수 상태를 안전하게 점검합니다.")
    parser.add_argument("--server-base-url", default=os.getenv("BLOG_AUTOMATION_SERVER_BASE_URL", "").strip())
    parser.add_argument("--token", default=os.getenv("BLOG_AUTOMATION_ADMIN_TOKEN", "").strip() or os.getenv("API_AUTH_TOKEN", "").strip())
    args = parser.parse_args()

    base_url = _normalize_base_url(args.server_base_url)
    token = args.token.strip()
    if not base_url:
        print("[실패] --server-base-url 또는 BLOG_AUTOMATION_SERVER_BASE_URL 값이 필요합니다.")
        return 2
    if not token:
        print("[실패] --token 또는 BLOG_AUTOMATION_ADMIN_TOKEN 값이 필요합니다.")
        return 2

    print(f"서버 환경 점검: {base_url}")
    try:
        status = _request_status(base_url, token)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        print(f"[실패] 관리자 점검 API 호출 실패: HTTP {exc.code}")
        print(body)
        return 1
    except Exception as exc:
        print(f"[실패] 관리자 점검 API 호출 실패: {exc}")
        return 1

    checks = []
    checks.append(_print_bool("APP_ENV가 production입니다.", status.get("environment") == "production", warn_only=True))
    checks.append(_print_bool("APP_BASE_URL이 설정되어 있습니다.", bool(status.get("app_base_url_configured"))))
    checks.append(_print_bool("OPENAI_API_KEY가 설정되어 있습니다.", bool(status.get("openai_api_key_configured"))))
    checks.append(_print_bool("API_AUTH_TOKEN이 설정되어 있습니다.", bool(status.get("api_auth_token_configured"))))
    checks.append(_print_bool("DATA_DIR이 존재합니다.", bool(status.get("data_dir_exists"))))
    checks.append(_print_bool("DATA_DIR에 쓰기가 가능합니다.", bool(status.get("data_dir_writable"))))
    checks.append(_print_bool("DEMO_USERNAME이 설정되어 있습니다.", bool(status.get("demo_username_configured")), warn_only=True))
    checks.append(_print_bool("DEMO_PASSWORD가 설정되어 있습니다.", bool(status.get("demo_password_configured")), warn_only=True))
    checks.append(_print_bool("DEMO_PASSWORD가 기본값이 아닙니다.", not bool(status.get("demo_password_uses_default")), warn_only=True))
    checks.append(_print_bool("BILLING_WEBHOOK_TOKEN이 설정되어 있습니다.", bool(status.get("billing_webhook_token_configured")), warn_only=True))

    print(f"기본 플랜: {status.get('default_plan')}")
    print(f"플랜 개수: {status.get('plan_count')}")
    print(f"DATA_DIR: {status.get('data_dir')}")
    print(f"허용 Origin: {status.get('allow_origins')}")

    if all(checks):
        print("서버 환경 점검 완료: 치명적인 문제를 찾지 못했습니다.")
        return 0
    print("서버 환경 점검 완료: 수정이 필요한 항목이 있습니다.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
