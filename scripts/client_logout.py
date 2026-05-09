import argparse
import sys

from client_api import ClientApiError, clear_saved_auth, load_client_settings, logout, save_client_settings


def main() -> int:
    parser = argparse.ArgumentParser(description="Logout client and clear local token.")
    parser.add_argument("--base-url", default=None)
    args = parser.parse_args()

    settings = load_client_settings()
    if args.base_url:
        settings["server_base_url"] = args.base_url.strip()
        save_client_settings(settings)

    token = str(settings.get("api_auth_token") or "").strip()
    if not token:
        clear_saved_auth(settings)
        print("MESSAGE: 저장된 로그인 정보가 없어 바로 정리했습니다.")
        return 0

    try:
        logout(settings)
        clear_saved_auth(settings)
        print("MESSAGE: 로그아웃 완료. 저장된 토큰을 정리했습니다.")
        return 0
    except ClientApiError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
