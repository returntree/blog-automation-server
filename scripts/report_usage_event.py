from __future__ import annotations

import argparse
import sys

from client_api import ClientApiError, post_usage_event


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="blog_automation 서버 사용 이벤트를 기록합니다.")
    parser.add_argument("--event-type", required=True, help="이벤트 종류")
    parser.add_argument("--stage", default="", help="작업 단계")
    parser.add_argument("--status", default="", help="이벤트 상태")
    parser.add_argument("--message", default="", help="메시지")
    parser.add_argument("--package-dir", default="", help="관련 패키지 경로")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    details: dict[str, str] = {}
    if args.message:
        details["message"] = args.message
    if args.package_dir:
        details["package_dir"] = args.package_dir

    response = post_usage_event(
        args.event_type,
        stage=args.stage,
        status=args.status,
        details=details,
    )
    event = response.get("event", {})
    print(
        f"usage event recorded: {event.get('event_type', args.event_type)} "
        f"/ stage={event.get('stage', args.stage)} / status={event.get('status', args.status)}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ClientApiError as exc:
        print(f"사용 이벤트 기록 실패: {exc}", file=sys.stderr)
        raise
