import json
import os
import sys
from pathlib import Path
from typing import Any
from urllib import error, request

from client_api import call_server, is_server_mode, pick_response_payload, write_json_file
from progress_spinner import ProgressSpinner

BASE_DIR = Path(__file__).resolve().parent.parent
INPUT_FILE = BASE_DIR / "inputs" / "request.json"
RESEARCH_FILE = BASE_DIR / "research" / "latest_research.json"
TEMPLATE_FILE = BASE_DIR / "templates" / "blog_prompt_template.txt"
OUTPUT_FILE = BASE_DIR / "jobs" / "latest_result.json"
LOG_DIR = BASE_DIR / "logs"
MODEL = os.getenv("OPENAI_MODEL", "gpt-5-mini")
RESPONSES_API_URL = "https://api.openai.com/v1/responses"
MIN_BODY_LENGTH = 2500
TARGET_BODY_LENGTH = 3200
MAX_DRAFT_ATTEMPTS = 3


class BodyTooShortError(RuntimeError):
    pass


def configure_console_encoding() -> None:
    for stream_name in ("stdout", "stderr"):
        stream = getattr(sys, stream_name, None)
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8-sig") as file:
        return json.load(file)


def read_text(path: Path) -> str:
    with path.open("r", encoding="utf-8-sig") as file:
        return file.read()


def build_research_summary(research_payload: dict[str, Any]) -> str:
    return json.dumps(research_payload.get("research", {}), ensure_ascii=False, indent=2)


def build_prompt(request_data: dict[str, Any], research_payload: dict[str, Any], template: str) -> str:
    replacements = {
        "{business_name}": request_data["business_name"],
        "{topic}": request_data["topic"],
        "{writing_style}": request_data["writing_style"],
        "{region}": request_data.get("region", ""),
        "{target_audience}": request_data.get("target_audience", ""),
        "{must_include}": ", ".join(request_data.get("must_include", [])),
        "{image_count}": str(request_data.get("image_count", 8)),
        "{selected_title}": request_data.get("selected_title", ""),
        "{research_summary}": build_research_summary(research_payload),
    }
    prompt = template
    for key, value in replacements.items():
        prompt = prompt.replace(key, value)

    image_style = str(request_data.get("image_style", "")).strip()
    if image_style:
        prompt += (
            "\n\n[이미지 스타일]\n"
            f"이미지 전체 스타일은 '{image_style}' 기준으로 통일감을 주되, 썸네일과 본문 이미지는 역할이 다르게 보이도록 설계하세요.\n"
            "본문 이미지는 같은 화면이 반복되지 않게 하고, 선택한 스타일 안에서도 장면과 구도를 다양하게 나눠 생성하세요."
        )
    return prompt


def extract_output_json(payload: dict[str, Any]) -> dict[str, Any]:
    if isinstance(payload.get("output_parsed"), dict):
        return payload["output_parsed"]

    output_text = payload.get("output_text")
    if isinstance(output_text, str) and output_text.strip():
        return json.loads(output_text)

    output_parts: list[str] = []
    for item in payload.get("output", []):
        for content in item.get("content", []):
            text_value = content.get("text")
            if isinstance(text_value, str) and text_value.strip():
                output_parts.append(text_value)

    if output_parts:
        return json.loads("\n".join(output_parts))

    raise ValueError("초안 생성 응답에서 JSON 본문을 찾지 못했습니다.")


def get_body_text(result: dict[str, Any]) -> str:
    paragraphs = result.get("paragraphs", [])
    return "\n\n".join(
        paragraph.get("text", "").strip()
        for paragraph in paragraphs
        if isinstance(paragraph, dict) and isinstance(paragraph.get("text"), str) and paragraph.get("text").strip()
    )


def validate_body_length(result: dict[str, Any]) -> int:
    body_text = get_body_text(result)
    body_length = len(body_text)
    if body_length < MIN_BODY_LENGTH:
        shortage = MIN_BODY_LENGTH - body_length
        raise BodyTooShortError(
            f"본문 길이가 {body_length}자로 부족합니다. 제목, 태그, 이미지 프롬프트를 제외한 본문만 최소 {MIN_BODY_LENGTH}자 이상이어야 합니다. 현재 {shortage}자 정도 더 필요합니다."
        )
    return body_length


def request_draft(prompt: str, attempt_number: int) -> dict[str, Any]:
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY 환경 변수가 설정되어 있지 않습니다.")

    request_body = {
        "model": MODEL,
        "input": prompt,
        "text": {"format": {"type": "json_object"}},
    }
    api_request = request.Request(
        RESPONSES_API_URL,
        data=json.dumps(request_body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    spinner = ProgressSpinner(f"원고 작성 중... ({attempt_number}/{MAX_DRAFT_ATTEMPTS})")
    try:
        spinner.start()
        with request.urlopen(api_request, timeout=180) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        spinner.stop()
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"초안 생성 API 호출 실패: {detail}") from exc
    except error.URLError as exc:
        spinner.stop()
        raise RuntimeError("초안 생성 API 서버에 연결하지 못했습니다.") from exc

    spinner.stop(f"원고 작성 응답 수신 완료 ({attempt_number}/{MAX_DRAFT_ATTEMPTS})")
    return extract_output_json(payload)


def run_server_mode(request_data: dict[str, Any], research_payload: dict[str, Any], prompt: str) -> dict[str, Any]:
    response = call_server(
        "/draft/generate",
        {
            "request": request_data,
            "research": research_payload,
            "prompt": prompt,
            "minimum_body_length": MIN_BODY_LENGTH,
            "target_body_length": TARGET_BODY_LENGTH,
            "max_attempts": MAX_DRAFT_ATTEMPTS,
        },
    )
    return pick_response_payload(response, "draft_result", "draft")


def build_retry_prompt(prompt: str, attempt_number: int) -> str:
    desired_length = TARGET_BODY_LENGTH + ((attempt_number - 2) * 400)
    return (
        f"{prompt}\n\n"
        "[보정 지시]\n"
        "이전 응답은 본문이 너무 짧았습니다.\n"
        f"제목, 태그, 이미지 프롬프트를 제외한 본문만 최소 {MIN_BODY_LENGTH}자 이상으로 작성하고, 가능하면 {desired_length}자 이상으로 더 길고 자세하게 작성하세요.\n"
        "각 문단은 실제 게시 가능한 블로그 문단처럼 충분히 길고 구체적으로 작성하세요.\n"
        "JSON 외 설명은 출력하지 마세요.\n"
    )


def main() -> int:
    configure_console_encoding()
    try:
        print(f"입력 파일 읽는 중: {INPUT_FILE}", flush=True)
        request_data = read_json(INPUT_FILE)
        if not request_data.get("selected_title"):
            raise RuntimeError("selected_title 값이 없습니다. 제목 후보 선택 단계를 먼저 실행해 주세요.")
        print(f"리서치 파일 읽는 중: {RESEARCH_FILE}", flush=True)
        research_payload = read_json(RESEARCH_FILE)
        print(f"블로그 템플릿 읽는 중: {TEMPLATE_FILE}", flush=True)
        template = read_text(TEMPLATE_FILE)
        prompt = build_prompt(request_data, research_payload, template)

        LOG_DIR.mkdir(parents=True, exist_ok=True)
        (LOG_DIR / "last_blog_prompt.txt").write_text(prompt, encoding="utf-8")
        print("블로그 프롬프트 저장 완료", flush=True)

        if is_server_mode():
            print("server mode로 초안 생성을 요청합니다.", flush=True)
            result = run_server_mode(request_data, research_payload, prompt)
            body_length = validate_body_length(result)
            print(f"본문 길이 검증 통과: {body_length}자", flush=True)
        else:
            current_prompt = prompt
            result: dict[str, Any] = {}
            for attempt_number in range(1, MAX_DRAFT_ATTEMPTS + 1):
                result = request_draft(current_prompt, attempt_number)
                try:
                    body_length = validate_body_length(result)
                    print(f"본문 길이 검증 통과: {body_length}자", flush=True)
                    break
                except BodyTooShortError as exc:
                    if attempt_number >= MAX_DRAFT_ATTEMPTS:
                        raise
                    print(str(exc), flush=True)
                    print(
                        f"본문이 짧아 재시도 프롬프트를 준비합니다... ({attempt_number + 1}/{MAX_DRAFT_ATTEMPTS})",
                        flush=True,
                    )
                    current_prompt = build_retry_prompt(prompt, attempt_number + 1)
                    (LOG_DIR / f"last_blog_prompt_retry_{attempt_number + 1}.txt").write_text(
                        current_prompt,
                        encoding="utf-8",
                    )

        write_json_file(OUTPUT_FILE, result)
    except Exception as exc:
        print(f"실패 원인: {exc}", file=sys.stderr)
        return 1

    print(f"초안 저장 완료: {OUTPUT_FILE}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
