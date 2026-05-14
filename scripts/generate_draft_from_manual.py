import json
import os
import sys
from pathlib import Path
from urllib import error, request

from client_api import call_server, is_server_mode, pick_response_payload, write_json_file

BASE_DIR = Path(__file__).resolve().parent.parent
INPUT_FILE = BASE_DIR / "inputs" / "request.json"
OUTPUT_FILE = BASE_DIR / "jobs" / "latest_result.json"
LOG_DIR = BASE_DIR / "logs"
MODEL = os.getenv("OPENAI_MODEL", "gpt-5-mini")
RESPONSES_API_URL = "https://api.openai.com/v1/responses"


def configure_console_encoding() -> None:
    for stream_name in ("stdout", "stderr"):
        stream = getattr(sys, stream_name, None)
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")


def read_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8-sig") as file:
        return json.load(file)


def build_prompt(data: dict) -> str:
    title = str(data.get("manual_title", "")).strip()
    body = str(data.get("manual_body", "")).strip()
    tags = str(data.get("manual_tags", "")).strip()
    business_name = str(data.get("business_name", "")).strip()
    topic = str(data.get("topic", "")).strip()
    writing_style = str(data.get("writing_style", "")).strip()
    image_count = int(data.get("image_count", 8))
    return f"""
너는 한국어 블로그 글을 작성하는 전문 작가다.

아래 사용자가 입력한 원고를 최대한 유지하면서 업로드용 JSON 구조로 정리하세요.

[입력 정보]
- 포스팅 주체자: {business_name}
- 포스팅 소재: {topic}
- 글 스타일: {writing_style}
- 이미지 개수: {image_count}

[보유 원고 제목]
{title}

[보유 원고 본문]
{body}

[보유 태그]
{tags}

[작업 지시]
1. 사용자가 준 제목과 본문을 최대한 유지하세요.
2. 본문은 paragraphs[].text 구조로 나누세요.
3. 제목, 태그, 이미지 프롬프트를 제외한 본문만 2500자 이상이어야 합니다.
4. 이미지 프롬프트는 원고 기반으로 작성하고, 본문 이미지는 글자 없는 장면 중심으로 작성하세요.
5. 태그는 블로그용 해시태그 형태로 정리하세요.
6. 포스팅 주체자가 일반 블로거/방문자/내돈내산 후기 작성자라면 업체가 직접 말하는 "저희 가게", "저희 매장", "제공하고 있습니다" 같은 표현을 쓰지 마세요.
7. 포스팅 주체자가 업체/브랜드라면 그때만 브랜드가 직접 안내하는 톤을 사용할 수 있습니다.
8. 입력 원고에 없는 경험, 감정, 구매 사실, 방문 사실, 효과, 성과를 새로 만들지 마세요.
9. "오늘은 ~에 대해 알아보겠습니다", "전체적으로 만족스러운 경험이었습니다" 같은 AI스러운 표현을 추가하지 마세요.
10. JSON 외 설명은 출력하지 마세요.

[도입부 작성 규칙]
- 본문은 절대 사진 설명이나 시설 설명으로 바로 시작하지 마라.
- 보유 원고를 최대한 유지하되, 원고를 새로 보완하거나 확장해야 한다면 이 도입부 규칙을 우선 적용하세요.
- 첫 문단에서는 반드시 다음 중 최소 2가지를 자연스럽게 포함해라.
  - 어떤 장소/업체/제품/주제를 소개하는 글인지
  - 누가 어떤 상황에서 방문하거나 이용했는지
  - 왜 이 글을 쓰게 되었는지
  - 독자가 이 글에서 어떤 정보를 얻을 수 있는지
  - 글의 핵심 키워드 또는 장소명
- 첫 문단부터 수유실, 주차장, 내부 사진, 시설 세부 설명으로 바로 들어가지 마라.
- 사진 설명은 도입부 이후 본문 흐름에 맞춰 필요한 부분에만 자연스럽게 녹여라.

[출력 형식]
{{
  "title": "최종 제목",
  "paragraphs": [
    {{"text": "문단 내용", "image_after": "02"}}
  ],
  "images": [
    {{"file_name": "01_thumb", "type": "thumbnail", "prompt": "썸네일 프롬프트"}},
    {{"file_name": "02", "type": "body", "prompt": "본문 이미지 프롬프트"}}
  ],
  "tags": ["태그1", "태그2"]
}}
""".strip()


def extract_output_json(payload: dict) -> dict:
    output_text = payload.get("output_text")
    if isinstance(output_text, str) and output_text.strip():
        return json.loads(output_text)

    for output_item in payload.get("output", []):
        for content_item in output_item.get("content", []):
            text_value = content_item.get("text")
            if isinstance(text_value, str) and text_value.strip():
                return json.loads(text_value)

    raise RuntimeError("보유 원고 정리 응답에서 JSON을 찾지 못했습니다.")


def request_result(prompt: str) -> dict:
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY 환경 변수가 설정되어 있지 않습니다.")

    body = {
        "model": MODEL,
        "input": prompt,
        "text": {"format": {"type": "json_object"}},
    }
    api_request = request.Request(
        RESPONSES_API_URL,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        print("보유 원고 정리 중... 잠시만 기다려 주세요.", flush=True)
        with request.urlopen(api_request, timeout=180) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"보유 원고 정리 API 호출 실패: {detail}") from exc
    except error.URLError as exc:
        raise RuntimeError("보유 원고 정리 API 서버에 연결하지 못했습니다.") from exc

    print("보유 원고 정리 완료", flush=True)
    return extract_output_json(payload)


def run_server_mode(data: dict, prompt: str) -> dict:
    response = call_server(
        "/draft/generate-from-manual",
        {
            "request": data,
            "prompt": prompt,
        },
    )
    return pick_response_payload(response, "draft_result", "draft")


def main() -> int:
    configure_console_encoding()
    try:
        print(f"입력 파일 읽는 중: {INPUT_FILE}", flush=True)
        data = read_json(INPUT_FILE)
        prompt = build_prompt(data)
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        (LOG_DIR / "last_manual_draft_prompt.txt").write_text(prompt, encoding="utf-8")
        print("보유 원고 프롬프트 저장 완료", flush=True)
        if is_server_mode():
            print("server mode로 보유 원고 정리를 요청합니다.", flush=True)
            result = run_server_mode(data, prompt)
        else:
            result = request_result(prompt)
        write_json_file(OUTPUT_FILE, result)
    except Exception as exc:
        print(f"실패 원인: {exc}", file=sys.stderr)
        return 1

    print(f"초안 저장 완료: {OUTPUT_FILE}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
