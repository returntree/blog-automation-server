from __future__ import annotations

import argparse
import json
from urllib.parse import urlencode

from client_api import call_admin_server_json


def main() -> int:
    parser = argparse.ArgumentParser(description="Get usage summary from the server.")
    parser.add_argument("--server-base-url", required=True)
    parser.add_argument("--admin-token", required=True)
    parser.add_argument("--username", default="")
    args = parser.parse_args()

    endpoint = "/admin/usage/summary"
    if args.username.strip():
        endpoint += "?" + urlencode({"username": args.username.strip()})

    response = call_admin_server_json(
        args.server_base_url,
        args.admin_token,
        endpoint,
        method="GET",
    )
    print(json.dumps(response, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
