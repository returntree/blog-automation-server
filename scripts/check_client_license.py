from __future__ import annotations

import sys

from client_api import ClientApiError, get_auth_me, is_server_mode, load_client_settings, save_client_settings

ACTIVE_STATUSES = {"active", "trialing", "paid", "ok"}


def main() -> int:
    settings = load_client_settings()

    if not is_server_mode(settings):
        print("로컬 모드입니다. 서버 라이선스 확인을 건너뜁니다.")
        return 0

    if not settings.get("license_check_on_start", True):
        print("시작 시 라이선스 확인이 꺼져 있어 건너뜁니다.")
        return 0

    token = str(settings.get("api_auth_token") or "").strip()
    if not token:
        print("저장된 서버 로그인 토큰이 없습니다. 먼저 로그인해 주세요.", file=sys.stderr)
        return 2

    try:
        result = get_auth_me(settings)
    except ClientApiError as exc:
        print(f"라이선스 확인 실패: {exc}", file=sys.stderr)
        return 2

    account = result.get("account") or {}
    status = str(account.get("status") or "").strip().lower()
    if status not in ACTIVE_STATUSES:
        print("현재 계정은 사용 가능한 상태가 아닙니다.", file=sys.stderr)
        return 3

    settings["username"] = str(account.get("username") or settings.get("username") or "").strip()
    settings["plan_name"] = str(account.get("plan_name") or settings.get("plan_name") or "").strip()
    settings["account_status"] = status
    settings["account_expires_at"] = str(account.get("expires_at") or settings.get("account_expires_at") or "").strip()
    save_client_settings(settings)

    print("서버 라이선스 확인 완료")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
