from __future__ import annotations

import argparse
import json
from urllib.parse import urlencode

from client_api import call_admin_server_json


def main() -> int:
    parser = argparse.ArgumentParser(description="List usage events from the server.")
    parser.add_argument("--server-base-url", required=True)
    parser.add_argument("--admin-token", required=True)
    parser.add_argument("--username", default="")
    parser.add_argument("--event-type", default="")
    parser.add_argument("--stage", default="")
    parser.add_argument("--status", default="")
    parser.add_argument("--limit", type=int, default=100)
    args = parser.parse_args()

    query: dict[str, str | int] = {"limit": max(1, min(args.limit, 1000))}
    if args.username.strip():
        query["username"] = args.username.strip()
    if args.event_type.strip():
        query["event_type"] = args.event_type.strip()
    if args.stage.strip():
        query["stage"] = args.stage.strip()
    if args.status.strip():
        query["status"] = args.status.strip()

    endpoint = "/admin/usage/events?" + urlencode(query)

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
