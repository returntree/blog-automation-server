import argparse
import sys

from client_api import ClientApiError, get_subscription_status, load_client_settings


def main() -> int:
    parser = argparse.ArgumentParser(description="Check client login status.")
    parser.add_argument("--base-url", default=None)
    args = parser.parse_args()

    try:
        settings = load_client_settings()
        if args.base_url:
            settings["server_base_url"] = args.base_url.strip()
        payload = get_subscription_status(settings)
        account = payload.get("account") or {}
        remaining_usage = payload.get("remaining_usage") or {}
        username = str(account.get("username") or settings.get("username") or "").strip()
        status = str(account.get("status") or settings.get("account_status") or "unknown").strip().lower()
        plan = str(account.get("plan_name") or settings.get("plan_name") or "").strip()
        expires_at = str(account.get("expires_at") or settings.get("account_expires_at") or "").strip()
        message = str(payload.get("message") or "login status ok").strip()
        days_until_expiry = payload.get("days_until_expiry")
        drafts_remaining = remaining_usage.get("monthly_drafts")
        images_remaining = remaining_usage.get("monthly_images")
        is_expired = bool(payload.get("is_expired"))

        print(f"USERNAME: {username}")
        print(f"STATUS: {status}")
        print(f"PLAN: {plan}")
        print(f"EXPIRES_AT: {expires_at}")
        print(f"DAYS_UNTIL_EXPIRY: {'' if days_until_expiry is None else days_until_expiry}")
        print(f"DRAFTS_REMAINING: {'' if drafts_remaining is None else drafts_remaining}")
        print(f"IMAGES_REMAINING: {'' if images_remaining is None else images_remaining}")
        print(f"IS_EXPIRED: {'true' if is_expired else 'false'}")
        print(f"MESSAGE: {message}")
        return 0
    except ClientApiError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
