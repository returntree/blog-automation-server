import json
import os
import sys
from pathlib import Path
from urllib import error, request

from client_api import call_server, is_server_mode, pick_response_payload, write_json_file

BASE_DIR = Path(__file__).resolve().parent.parent
ACTION_FILE = BASE_DIR / "inputs" / "draft_review_action.json"
RESULT_FILE = BASE_DIR / "jobs" / "latest_result.json"
MODEL = os.getenv("OPENAI_MODEL", "gpt-5-mini")
RESPONSES_API_URL = "https://api.openai.com/v1/responses"
MIN_REVISED_BODY_LENGTH = 2000
MAX_REVISED_BODY_LENGTH = 2500


def configure_console_encoding() -> None:
    for stream_name in ("stdout", "stderr"):
        stream = getattr(sys, stream_name, None)
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")


def extract_output_json(payload: dict) -> dict:
    output_text = payload.get("output_text")
    if isinstance(output_text, str) and output_text.strip():
        return json.loads(output_text)

    parts: list[str] = []
    for item in payload.get("output", []):
        for content in item.get("content", []):
            text_value = content.get("text")
            if isinstance(text_value, str) and text_value.strip():
                parts.append(text_value)

    if parts:
        return json.loads("\n".join(parts))

    raise RuntimeError("AI 수정 응답에서 JSON을 찾지 못했습니다.")


def validate_and_merge(current_result: dict, revised: dict) -> dict:
    if not isinstance(revised, dict):
        raise RuntimeError("AI 수정 결과가 JSON 객체 형태가 아닙니다.")

    merged = dict(current_result)
    merged.update(revised)

    if not isinstance(merged.get("title"), str) or not merged.get("title", "").strip():
        raise RuntimeError("AI 수정 결과의 title이 비어 있습니다.")
    if not isinstance(merged.get("paragraphs"), list) or not merged.get("paragraphs"):
        raise RuntimeError("AI 수정 결과의 paragraphs가 없습니다.")
    if not isinstance(merged.get("images"), list) or not merged.get("images"):
        raise RuntimeError("AI 수정 결과의 images가 없습니다.")
    if not isinstance(merged.get("tags"), list) or not merged.get("tags"):
        raise RuntimeError("AI 수정 결과의 tags가 없습니다.")

    return merged


def get_body_length(result: dict) -> int:
    paragraphs = result.get("paragraphs") or []
    text = "\n\n".join(str(item.get("text", "")) for item in paragraphs if isinstance(item, dict))
    return len(text.strip())


def is_body_revision_request(instruction: str) -> bool:
    text = str(instruction or "").strip().lower()
    if not text:
        return False
    if ("제목만" in text or "태그만" in text) and not any(
        keyword in text for keyword in ("본문", "원고", "글", "문단", "재작성", "말투", "문체", "톤", "후기", "블로거")
    ):
        return False
    return any(
        keyword in text
        for keyword in ("본문", "원고", "글", "문단", "재작성", "말투", "문체", "톤", "후기", "블로거", "자연스럽", "작성")
    )


def build_length_retry_instruction(instruction: str, body_length: int) -> str:
    return (
        f"{instruction}\n\n"
        f"이전 AI 수정 결과의 본문 길이는 {body_length}자입니다. "
        f"본문 수정/재작성 요청이므로 본문을 반드시 {MIN_REVISED_BODY_LENGTH}자 이상 "
        f"{MAX_REVISED_BODY_LENGTH}자 이하로 다시 작성하세요. "
        "5~7개 문단으로 나누고, 각 문단은 300~450자 정도로 작성하세요. "
        "제목, 태그, 이미지 프롬프트는 불필요하게 바꾸지 마세요."
    )


def is_body_length_in_target(result: dict) -> bool:
    body_length = get_body_length(result)
    return MIN_REVISED_BODY_LENGTH <= body_length <= MAX_REVISED_BODY_LENGTH


def build_revision_input(prompt: str, payload: dict) -> str:
    current_result = payload.get("current_result") or {}
    instruction = str(payload.get("instruction") or "").strip()
    return f"""
{prompt}

[현재 초안 JSON]
{json.dumps(current_result, ensure_ascii=False, indent=2)}

[수정 요청]
{instruction}

[작업 지침]
- 반드시 JSON 객체만 출력하세요.
- title, paragraphs, images, tags 구조를 유지하세요.
- 수정 요청과 관련 없는 images 배열은 삭제하거나 비우지 마세요.
- 전체를 다시 작성할 필요가 없으면 수정된 필드만 반환해도 됩니다.
- 수정 요청이 제목이나 태그에만 해당하면 해당 필드만 반환하세요.
- 본문 수정 요청이 아니라면 paragraphs를 반환하지 말고 현재 본문을 그대로 유지하세요.
- 본문 수정이나 재작성 요청이면 본문을 5~7개 문단으로 나누고, 제목/태그/이미지 프롬프트를 제외한 본문만 반드시 2000자 이상 2500자 이하로 맞추세요.
- 본문 재작성 시 각 문단은 300~450자 정도로 작성하고, 방문 계기/분위기/메뉴/맛/가격/재방문 의사를 자연스럽게 포함하세요.
""".strip()


def request_revision(prompt: str, payload: dict) -> dict:
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY 환경 변수가 설정되어 있지 않습니다.")

    body = {
        "model": MODEL,
        "input": build_revision_input(prompt, payload),
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
        with request.urlopen(api_request, timeout=180) as response:
            return json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"AI 수정 API 호출 실패: {detail}") from exc
    except (TimeoutError, error.URLError) as exc:
        raise RuntimeError("AI 수정 API 연결 시간이 초과되었거나 서버에 연결하지 못했습니다.") from exc


def run_server_mode(current_result: dict, instruction: str) -> dict:
    response = call_server(
        "/draft/revise",
        {
            "action": "ai",
            "current_result": current_result,
            "instruction": instruction,
        },
    )
    revised = pick_response_payload(response, "revised_result", "draft_result", "draft")
    return validate_and_merge(current_result, revised)


def main() -> int:
    configure_console_encoding()
    action = json.loads(ACTION_FILE.read_text(encoding="utf-8-sig"))
    current_result = json.loads(RESULT_FILE.read_text(encoding="utf-8-sig"))
    instruction = str(action.get("ai_instruction", "")).strip()
    if not instruction:
        print("AI 수정 요청이 비어 있습니다.", file=sys.stderr)
        return 1

    if is_server_mode():
        try:
            print("server mode로 AI 수정 요청을 전달합니다.", flush=True)
            merged = run_server_mode(current_result, instruction)
            write_json_file(RESULT_FILE, merged)
            print(f"AI 수정 저장 완료: {RESULT_FILE}")
            return 0
        except Exception as exc:
            print(f"AI 수정 실패: {exc}", file=sys.stderr)
            return 1

    prompt = f"""
현재 블로그 초안 JSON을 수정하세요.

[현재 초안 JSON]
{json.dumps(current_result, ensure_ascii=False, indent=2)}

[수정 요청]
{instruction}

[작업 지시]
- 반드시 JSON만 출력하세요.
- title, paragraphs, images, tags 구조를 유지하세요.
- images의 file_name, type, 순서를 유지하세요.
- 문단을 바꾸더라도 images 배열 자체는 비틀리지 마세요.
- 본문을 수정하는 경우 본문을 5~7개 문단으로 나누고, 제목/태그/이미지 프롬프트를 제외한 본문만 반드시 2000자 이상 2500자 이하로 맞추세요.
""".strip()

    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        print("OPENAI_API_KEY 환경 변수가 설정되어 있지 않습니다.", file=sys.stderr)
        return 1

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
        print("AI 수정 반영 중... 잠시만 기다려 주세요.", flush=True)
        with request.urlopen(api_request, timeout=180) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        print(f"AI 수정 API 호출 실패: {detail}", file=sys.stderr)
        return 1
    except error.URLError as exc:
        print(f"AI 수정 API 연결 실패: {exc}", file=sys.stderr)
        return 1

    try:
        revised = extract_output_json(payload)
        merged = validate_and_merge(current_result, revised)
    except Exception as exc:
        print(f"AI 수정 결과 검증 실패: {exc}", file=sys.stderr)
        return 1

    write_json_file(RESULT_FILE, merged)
    print(f"AI 수정 저장 완료: {RESULT_FILE}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
