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


def normalize_body_length(result: dict) -> dict:
    normalized = dict(result)
    paragraphs = [dict(item) for item in normalized.get("paragraphs", []) if isinstance(item, dict)]
    if not paragraphs:
        return normalized

    title = str(normalized.get("title") or "이번 방문").strip()
    additions = [
        f"{title}를 정리하면서 가장 먼저 떠올린 부분은 방문 전 기대했던 점과 실제로 확인한 내용의 차이였습니다. 짧은 정보만 보고 판단하면 분위기, 동선, 대기 흐름, 이용 편의성을 놓치기 쉬운데, 직접 경험해 보니 결과 자체보다 그 과정에서 느껴지는 현실적인 기준이 더 중요하게 다가왔습니다.",
        "전체적인 인상은 한 가지 표현으로 단정하기보다 첫 느낌, 이용 중 확인한 부분, 마무리 후 남는 생각을 나눠 보는 편이 자연스러웠습니다. 처음에는 눈에 보이는 구성이나 분위기가 먼저 들어왔고, 시간이 지나면서 가격대, 접근성, 응대, 동행자와 함께 이용하기 좋은지 같은 요소를 함께 보게 됐습니다.",
        "분위기는 방문 시간대나 이용 상황에 따라 꽤 다르게 느껴질 수 있습니다. 사람이 몰리는 시간에는 활기 있는 대신 조금 번잡할 수 있고, 비교적 한산한 시간에는 공간과 서비스를 더 천천히 볼 수 있습니다. 그래서 목적이 분명한 방문이라면 피크 시간대를 살짝 피하는 것도 만족도를 높이는 방법이라고 느꼈습니다.",
        "비용은 단순히 비싸다, 저렴하다로만 보기보다 구성, 위치, 편의성, 주변 선택지까지 함께 놓고 판단하는 게 맞았습니다. 같은 금액이라도 어떤 목적의 방문인지에 따라 만족도가 달라질 수 있고, 필요한 부분을 제대로 충족했는지에 따라 체감도 달라집니다. 방문 전 최신 정보를 확인하면 예산을 잡는 데 도움이 됩니다.",
        "전체적으로는 기대 포인트를 어디에 두느냐에 따라 만족도가 달라질 수 있는 경험이었습니다. 특별한 시간을 기대한다면 핵심 장점을 중심으로 보는 편이 좋고, 가볍게 들르는 일정이라면 이동과 대기 여유를 먼저 보는 편이 좋겠습니다. 저는 다시 이용한다면 조금 덜 붐비는 시간에 차분하게 확인해 보고 싶습니다.",
        "주차나 이동 편의성도 실제 만족도에 영향을 줬습니다. 목적지에 도착하기 전까지는 핵심 서비스만 생각하기 쉽지만, 막상 방문해 보면 차를 세울 수 있는지, 입구를 찾기 쉬운지, 주변에 함께 들를 만한 곳이 있는지가 전체 경험을 좌우합니다. 특히 여러 명이 함께 움직일 때는 이런 요소가 더 중요하게 느껴졌습니다.",
        "응대는 과하게 친절하다는 느낌보다 필요한 안내가 적당히 이어지는지가 더 중요했습니다. 이용 과정이 복잡하지 않고, 기본 안내나 대기 안내가 자연스럽게 이뤄지면 처음 방문한 사람도 크게 헤매지 않습니다. 바쁜 시간대에는 응대 속도가 조금 달라질 수 있으니 여유 있게 보는 편이 좋겠습니다.",
        "사진을 찍어 기록하기에도 무난했습니다. 전체 분위기와 가까운 디테일을 함께 남겨두면 나중에 경험을 떠올리기 쉽고, 공간 사진은 사람이 적은 방향으로 조심스럽게 찍는 편이 좋았습니다. 방문 후기를 쓰는 입장에서는 이런 기록이 실제 분위기를 전달하는 데 꽤 도움이 됐습니다.",
        "함께 간 사람의 반응도 참고할 만했습니다. 저는 전체적인 균형과 재방문 의사를 중심으로 봤고, 동행자는 편의성과 대기 시간, 체감 만족도를 더 중요하게 보았습니다. 이런 차이를 함께 적어두면 한 사람의 취향에만 치우치지 않은 후기가 되고, 방문을 고민하는 분들에게도 조금 더 현실적인 기준이 됩니다.",
        "방문 전에는 최신 운영 정보와 이용 조건을 한 번 더 확인하는 편이 좋습니다. 온라인에 남아 있는 정보가 실제 상황과 다를 수 있고, 예약이나 현장 사정에 따라 이용 흐름이 달라지는 경우도 있습니다. 특히 멀리서 찾아가는 일정이라면 전화나 지도 앱 확인을 해두는 것이 안전합니다.",
        "이용 방식은 처음 방문이라면 가장 기본적인 선택지를 중심으로 잡고, 여유가 있으면 추가 옵션을 확인하는 방식이 무난했습니다. 처음부터 많은 것을 한 번에 결정하기보다 인원, 시간, 목적에 맞춰 고르면 만족도가 높습니다. 선택이 어렵다면 현장 안내나 최근 후기를 참고하는 것도 방법입니다.",
        "재방문 여부를 묻는다면 저는 조건부로 다시 가볼 만하다고 정리하고 싶습니다. 붐비는 시간의 대기와 이동을 감안할 수 있다면 장점이 분명했고, 조용한 경험을 원한다면 시간대를 조절하는 것이 좋아 보였습니다. 기대치를 현실적으로 잡고 방문하면 후회보다는 참고할 만한 경험이 될 가능성이 큽니다.",
        "마지막으로 이 후기는 특정 장점만 강조하기보다 실제로 방문이나 이용을 고민하는 분들이 궁금해할 부분을 기준으로 정리했습니다. 분위기, 비용, 편의성, 만족도는 사람마다 받아들이는 기준이 다르기 때문에 제 경험은 참고용으로 봐주시면 좋겠습니다. 방문 계획이 있다면 최신 정보와 본인 일정에 맞춰 한 번 더 확인해 보세요.",
    ]

    while get_body_length({"paragraphs": paragraphs}) < MIN_REVISED_BODY_LENGTH and additions:
        paragraphs.append({"text": additions.pop(0)})

    body_length = get_body_length({"paragraphs": paragraphs})
    if body_length > MAX_REVISED_BODY_LENGTH:
        kept: list[dict] = []
        current_length = 0
        for paragraph in paragraphs:
            text = str(paragraph.get("text", "")).strip()
            separator_length = 2 if kept else 0
            next_length = current_length + separator_length + len(text)
            if next_length <= MAX_REVISED_BODY_LENGTH:
                kept.append({**paragraph, "text": text})
                current_length = next_length
                continue
            remaining = MAX_REVISED_BODY_LENGTH - current_length - separator_length
            if remaining > 80:
                kept.append({**paragraph, "text": text[:remaining].rstrip()})
            break
        paragraphs = kept or paragraphs

    normalized["paragraphs"] = paragraphs
    return normalized


def build_revision_input(prompt: str, payload: dict) -> str:
    current_result = payload.get("current_result") or {}
    instruction = str(payload.get("instruction") or "").strip()
    if is_body_revision_request(instruction):
        scope_instruction = (
            "- 본문 수정/재작성 요청이므로 paragraphs 배열을 반드시 전체 반환하세요.\n"
            "- paragraphs는 5~7개 문단 객체로 구성하고, 각 text는 300~450자 정도로 작성하세요.\n"
            "- paragraphs 배열 전체의 text 합계가 2000자 미만이면 실패입니다. 충분히 길게 작성하세요.\n"
            "- 현재 초안이 짧아도 방문 계기, 매장 분위기, 주문 메뉴, 맛과 양, 가격 느낌, 아쉬운 점, 재방문 의사를 자연스럽게 확장하세요."
        )
    else:
        scope_instruction = (
            "- 전체를 다시 작성할 필요가 없으면 수정된 필드만 반환해도 됩니다.\n"
            "- 수정 요청이 제목이나 태그에만 해당하면 해당 필드만 반환하세요.\n"
            "- 본문 수정 요청이 아니라면 paragraphs를 반환하지 말고 현재 본문을 그대로 유지하세요."
        )
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
{scope_instruction}
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
        "max_output_tokens": 5000,
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
