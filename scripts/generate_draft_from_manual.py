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
- 본문은 반드시 글의 맥락을 먼저 잡고 시작한다.
- 첫 문단에서 장소명, 업체명, 제품명, 주제 중 핵심 대상을 자연스럽게 소개해야 한다.
- 독자가 첫 문단만 읽어도 이 글이 무엇에 관한 글인지 알 수 있어야 한다.
- 방문 후기라면 어디를 다녀왔는지, 누구와 갔는지, 왜 갔는지, 어떤 관점에서 후기를 쓰는지를 먼저 자연스럽게 언급한다.
- 업체 홍보글이라면 어떤 지역/업종/서비스에 대한 글인지, 독자가 어떤 고민을 할 때 필요한 업체인지를 먼저 언급한다.
- 생활팁이나 정보글이라면 독자가 겪는 문제, 왜 이 정보가 필요한지, 이 글에서 무엇을 알려줄지를 먼저 언급한다.
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

[사진 정보 사용 방식]
- 사진 설명은 글의 재료일 뿐, 글의 순서가 아니다.
- 사진을 하나씩 설명하지 말고, 글의 흐름에 필요한 장면만 자연스럽게 사용한다.
- "사진에서 보이는 것처럼", "사진을 보면", "사진에는" 같은 표현은 사용하지 않는다.
- 사진이 여러 장 제공되더라도 글을 사진 순서대로 작성하지 않는다.
- 사진은 글의 재료일 뿐이며, 문단의 중심은 실제 경험과 독자의 관심사여야 한다.
- 절대 다음 표현으로 문단을 시작하지 마라.
- 문단 시작 금지 표현: 첫 번째 사진, 두 번째 사진, 세 번째 사진, 네 번째 사진, 마지막 사진, 사진에는, 사진을 보면, 사진에서 보이는 것처럼, 썸네일 참고
- 사진 속 정보는 실제 경험에 녹여서 사용한다.
- 수유실 사진이 있다면 "수유실 사진에는 노란 의자가 있습니다"라고 쓰지 말고, "막내가 있다 보니 수유실 위치부터 보게 됐는데, 입구 쪽에 바로 보여서 동선은 괜찮았습니다"처럼 쓰세요.
- 게임존 사진이 있다면 "게임존 사진에는 오락기가 있습니다"라고 쓰지 말고, "첫째는 게임존에서 제일 오래 놀았습니다. 조명이 화려해서 그런지 들어가자마자 그쪽으로 가더라고요"처럼 쓰세요.
- 장난감존 사진이 있다면 "장난감존 사진에는 소방차 장난감이 있습니다"라고 쓰지 말고, "둘째는 소방차 장난감 있는 쪽에서 한참 놀았습니다"처럼 쓰세요.

[정보 부족 처리 방식]
- 입력값에 없는 정보는 본문에서 굳이 언급하지 않는다.
- 정보가 없다는 사실을 본문에 쓰지 마라.
- 가격, 영업시간, 주차, 결제수단, 전화번호 등이 없으면 생략한다.
- 운영시간이나 요금처럼 변동 가능성이 큰 정보가 글에 꼭 필요할 경우, 마지막 문단에서 한 번만 자연스럽게 안내한다.
- 반복적으로 "확인 권장", "전화 확인", "사진만으로 판단 불가" 같은 문장을 쓰지 마라.
- 방문 전 확인, 지점별 상이, 현장 확인 권장 문구는 글 전체에서 최대 1회만 사용한다.
- 부족한 정보를 굳이 설명하지 않는다.

[AI스러운 흐름 금지]
- 다음 흐름으로 글을 쓰지 마라: 사진1 설명 → 사진2 설명 → 사진3 설명 → 장점 정리 → 단점 정리 → 재방문 의사
- 방문 후기와 일반 후기에는 다음 흐름을 우선 사용한다: 글의 배경 → 방문/이용 계기 → 실제 경험 → 기억에 남은 부분 → 부모/소비자 입장에서 느낀 점 → 아쉬운 점 → 자연스러운 마무리
- 업체 홍보글은 다음 흐름을 사용한다: 독자의 고민 → 업체/서비스 소개 → 차별점 → 이용하면 좋은 대상 → 이용 방법 또는 문의 안내 → 자연스러운 마무리
- 생활팁 글은 다음 흐름을 사용한다: 문제 상황 → 원인 설명 → 해결 방법 → 주의할 점 → 실전 팁 → 자연스러운 마무리
- 방문 후기는 사진 순서가 아니라 경험 순서로 작성한다.
- 도입에서는 어디를 왜 갔는지, 누구와 갔는지 설명한다.
- 중간에서는 실제로 이용하면서 기억에 남은 부분을 쓰고, 아이들 반응, 보호자 입장에서 편했던 점, 공간 분위기를 자연스럽게 섞는다.
- 후반에서는 아쉬웠던 점을 한두 가지 정도만 자연스럽게 언급한다.
- 마무리에서는 억지로 장점/단점 요약을 하지 않는다.
- "장점은 ~이고 단점은 ~입니다"라고 쓰지 않는다.
- "재방문 의사가 있습니다"라고 딱딱하게 쓰지 않는다.
- 실제 사람이 블로그에 남기는 말처럼 자연스럽게 끝낸다.

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
