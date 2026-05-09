from __future__ import annotations

import json

from client_api import ClientApiError, get_available_plans, load_client_settings


def main() -> int:
    settings = load_client_settings()
    try:
        response = get_available_plans(settings)
    except ClientApiError as exc:
        print(f"실패 원인: {exc}")
        return 1

    print(json.dumps(response, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
