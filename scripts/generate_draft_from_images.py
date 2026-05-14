import base64
import json
import mimetypes
import os
import sys
from pathlib import Path
from urllib import error, request

from client_api import call_server, is_server_mode, pick_response_payload, write_json_file
from progress_spinner import ProgressSpinner

BASE_DIR = Path(__file__).resolve().parent.parent
INPUT_FILE = BASE_DIR / "inputs" / "request.json"
RESEARCH_FILE = BASE_DIR / "research" / "latest_research.json"
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


def build_research_summary(research_payload: dict) -> str:
    return json.dumps(research_payload.get("research", {}), ensure_ascii=False, indent=2)


def build_image_item(path_str: str) -> dict:
    path = Path(path_str)
    mime_type = mimetypes.guess_type(path.name)[0] or "image/png"
    encoded = base64.b64encode(path.read_bytes()).decode("ascii")
    return {
        "type": "input_image",
        "image_url": f"data:{mime_type};base64,{encoded}",
    }


def build_thumbnail_prompt(data: dict, title: str) -> str:
    business_name = str(data.get("business_name", "")).strip()
    topic = str(data.get("topic", "")).strip()
    region = str(data.get("region", "")).strip()
    image_style = str(data.get("image_style", "")).strip()
    title_text = " ".join(title.split())[:15]

    parts = [
        "첫 번째 참고 이미지를 기반으로 블로그 대표 썸네일을 새로 생성",
        "원본 이미지의 전체 분위기와 업종 특성은 유지",
        "블로그 썸네일용 대표 장면으로 구도를 더 선명하고 안정적으로 정리",
        "과한 광고 포스터 느낌은 피하고 자연스럽고 신뢰감 있는 비주얼로 표현",
        "썸네일 문구는 짧은 한글 문구 1개만 사용",
        "문구는 반드시 지정한 문장을 그대로 정확하게 사용",
        "문구는 굵고 크게, 선명하게 표현",
        "문자가 깨지거나 잘리거나 흐려지지 않게 가독성 우선으로 처리",
        "글자 오타, 자모 분리, 비슷한 글자 치환이 생기지 않게 강하게 처리",
        "텍스트 효과보다 문구 가독성을 우선",
        "문구는 최대 2줄까지만 사용하고 중앙 또는 하단 안전영역 안에 크게 배치",
        "배경보다 문구가 먼저 읽히는 썸네일로 설계",
    ]
    if business_name:
        parts.append(f"포스팅 주체자는 {business_name}")
    if topic:
        parts.append(f"주제는 {topic}")
    if region:
        parts.append(f"지역 맥락은 {region}")
    if image_style:
        parts.append(f"이미지 스타일은 {image_style}")
    if title_text:
        parts.append(f"이미지 안에는 '{title_text}' 문구만 굵고 선명하게 배치")
    return ", ".join(parts)


def build_request_content(
    data: dict,
    research_payload: dict | None = None,
    image_items: list[dict] | None = None,
) -> list[dict]:
    image_paths = [str(path).strip() for path in data.get("selected_image_paths", []) if str(path).strip()]
    image_count = len(image_items) if image_items is not None else len(image_paths)
    body_image_count = max(0, image_count - 1)
    research_block = build_research_summary(research_payload) if research_payload else ""

    image_order_rules: list[str] = []
    for index in range(body_image_count):
        image_no = index + 2
        paragraph_no = index + 1
        image_order_rules.append(
            f"- 이미지 {image_no}번은 반드시 {paragraph_no}번째 문단과 직접 연결되도록 작성하세요."
        )

    order_block = "\n".join(image_order_rules) if image_order_rules else "- 본문용 이미지는 없습니다."

    user_prompt = f"""
너는 한국어 블로그 글을 작성하는 전문 작가다.
목표는 입력된 정보와 첨부 이미지를 바탕으로 네이버 블로그에 올릴 수 있는 자연스러운 글을 작성하는 것이다.

첨부한 이미지를 보고 사진 순서와 문단 순서가 맞는 블로그 초안을 JSON으로 작성하세요.
첫 번째 이미지는 썸네일 참고용이고, 두 번째 이미지부터는 본문에 실제로 들어갈 이미지입니다.

[입력 정보]
- 포스팅 주체자: {data.get("business_name", "")}
- 포스팅 소재: {data.get("topic", "")}
- 글 스타일: {data.get("writing_style", "")}
- 지역: {data.get("region", "")}
- 주요 독자: {data.get("target_audience", "")}
- 반드시 넣을 내용: {", ".join(data.get("must_include", []))}
- 본문용 이미지 수: {body_image_count}
- 이미지 스타일: {data.get("image_style", "")}

[리서치 참고 정보]
{research_block if research_block else "없음"}

[리서치 반영 규칙]
- 위 리서치 참고 정보가 있으면 포스팅 대상의 특징, 방문 포인트, 주제 전달 포인트를 원고에 자연스럽게 반영하세요.
- 단 실제 사진에서 보이지 않는 장면을 과장해서 쓰지 말고 사진 기반 묘사와 리서치 기반 설명의 균형을 맞추세요.
- 사진 문단은 사진 장면을 우선으로 쓰고, 리서치 정보는 설명 보강용으로만 사용하세요.
- 포스팅 주체자가 일반 블로거/방문자/내돈내산 후기 작성자라면 업체가 직접 말하는 "저희 가게", "저희 매장", "제공하고 있습니다" 같은 표현을 쓰지 마세요.
- 포스팅 주체자가 업체/브랜드라면 그때만 브랜드가 직접 안내하는 톤을 사용할 수 있습니다.
- 입력값에 없는 방문일, 결제 방식, 아이 나이, 동행 인원, 감정, 구매 사실, 효과, 성과를 지어내지 마세요.
- 광고/협찬/업체홍보 글을 내돈내산처럼 위장하지 마세요.
- "사진에서 보이는 것처럼", "오늘은 ~에 대해 알아보겠습니다", "전체적으로 만족스러운 경험이었습니다" 같은 AI스러운 표현은 피하세요.

[도입부 작성 규칙]
- 본문은 반드시 글의 맥락을 먼저 잡고 시작한다.
- 첫 문단에서 장소명, 업체명, 제품명, 주제 중 핵심 대상을 자연스럽게 소개해야 한다.
- 독자가 첫 문단만 읽어도 이 글이 무엇에 관한 글인지 알 수 있어야 한다.
- 방문 후기라면 어디를 다녀왔는지, 누구와 갔는지, 왜 갔는지, 어떤 관점에서 후기를 쓰는지를 먼저 자연스럽게 언급한다.
- 업체 홍보글이라면 어떤 지역/업종/서비스에 대한 글인지, 독자가 어떤 고민을 할 때 필요한 업체인지를 먼저 언급한다.
- 생활팁이나 정보글이라면 독자가 겪는 문제, 왜 이 정보가 필요한지, 이 글에서 무엇을 알려줄지를 먼저 언급한다.
- 본문은 절대 사진 설명이나 시설 설명으로 바로 시작하지 마라.
- 첫 문단에서는 반드시 다음 중 최소 2가지를 자연스럽게 포함해라.
  - 어떤 장소/업체/제품/주제를 소개하는 글인지
  - 누가 어떤 상황에서 방문하거나 이용했는지
  - 왜 이 글을 쓰게 되었는지
  - 독자가 이 글에서 어떤 정보를 얻을 수 있는지
  - 글의 핵심 키워드 또는 장소명
- 방문 후기라면 "이번에 아이들과 다녀온 곳은 ○○에 있는 ○○입니다.", "주말에 아이들 데리고 갈 만한 실내 놀이공간을 찾다가 ○○에 다녀왔습니다."처럼 글의 배경을 먼저 잡으세요.
- 업체 홍보글이라면 독자의 고민이나 상황에서 시작하세요.
- 생활팁/정보글이라면 문제 상황이나 궁금증에서 시작하세요.
- 첫 문단부터 수유실, 주차장, 내부 사진, 시설 세부 설명으로 바로 들어가지 마라.
- 사진 설명은 도입부 이후 본문 흐름에 맞춰 필요한 부분에만 자연스럽게 녹여라.

[사진 정보 사용 방식]
- 사진 설명은 글의 재료일 뿐, 글의 순서가 아니다.
- 사진을 하나씩 설명하지 말고, 글의 흐름에 필요한 장면만 자연스럽게 사용한다.
- "사진에서 보이는 것처럼", "사진을 보면", "사진에는" 같은 표현은 사용하지 않는다.

[정보 부족 처리 방식]
- 입력값에 없는 정보는 본문에서 굳이 언급하지 않는다.
- 정보가 없다는 사실을 본문에 쓰지 마라.
- 가격, 영업시간, 주차, 결제수단, 전화번호 등이 없으면 생략한다.
- 운영시간이나 요금처럼 변동 가능성이 큰 정보가 글에 꼭 필요할 경우, 마지막 문단에서 한 번만 자연스럽게 안내한다.
- 반복적으로 "확인 권장", "전화 확인", "사진만으로 판단 불가" 같은 문장을 쓰지 마라.

[AI스러운 흐름 금지]
- 다음 흐름으로 글을 쓰지 마라: 사진1 설명 → 사진2 설명 → 사진3 설명 → 장점 정리 → 단점 정리 → 재방문 의사
- 방문 후기와 일반 후기에는 다음 흐름을 우선 사용한다: 글의 배경 → 방문/이용 계기 → 실제 경험 → 기억에 남은 부분 → 부모/소비자 입장에서 느낀 점 → 아쉬운 점 → 자연스러운 마무리
- 업체 홍보글은 다음 흐름을 사용한다: 독자의 고민 → 업체/서비스 소개 → 차별점 → 이용하면 좋은 대상 → 이용 방법 또는 문의 안내 → 자연스러운 마무리
- 생활팁 글은 다음 흐름을 사용한다: 문제 상황 → 원인 설명 → 해결 방법 → 주의할 점 → 실전 팁 → 자연스러운 마무리

[이미지-문단 매칭 규칙]
{order_block}
- 이미지 순서를 바꾸지 마세요.
- 이미지와 맞지 않는 문단을 앞에 끼워 넣지 마세요.
- 최소한 본문용 이미지 개수만큼은 앞쪽 문단과 이미지 순서를 1:1로 대응하세요.
- 각 문단은 해당 이미지에서 실제로 보이는 장면, 메뉴, 공간, 분위기, 디테일을 반영하세요.

[작성 규칙]
1. 제목, 태그, 이미지 프롬프트를 제외한 본문만 최소 2500자 이상 작성하세요.
2. 문단은 최소 6개 이상 작성하세요.
3. 각 문단은 실제 블로그 본문처럼 충분히 길고 자연스럽게 작성하세요.
4. 같은 설명을 반복하지 말고 이미지 이름을 따라 초반-중반-후반 흐름으로 이어지게 작성하세요.
5. 문단마다 호흡을 다르게 만들고, 모든 사진을 억지로 설명하지 말고 필요한 정보만 자연스럽게 섞으세요.
6. JSON 외 설명은 출력하지 마세요.

[출력 형식]
{{
  "title": "제목",
  "paragraphs": [
    {{"text": "문단 내용"}}
  ],
  "tags": ["태그1", "태그2"]
}}
""".strip()

    content: list[dict] = [{"type": "input_text", "text": user_prompt}]
    if image_items is not None:
        content.extend(image_items)
    else:
        content.extend(build_image_item(path) for path in image_paths)
    return content


def extract_json_text(payload: dict) -> str:
    output_text = payload.get("output_text")
    if isinstance(output_text, str) and output_text.strip():
        return output_text.strip()

    for output_item in payload.get("output", []):
        for content_item in output_item.get("content", []):
            if content_item.get("type") in {"output_text", "text"}:
                text_value = content_item.get("text")
                if isinstance(text_value, str) and text_value.strip():
                    return text_value.strip()

    raise RuntimeError("보유 이미지 기반 초안 응답에서 JSON을 찾지 못했습니다.")


def request_result(content: list[dict]) -> dict:
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY 환경 변수가 설정되어 있지 않습니다.")

    body = {
        "model": MODEL,
        "input": [{"role": "user", "content": content}],
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

    spinner = ProgressSpinner("이미지를 분석하고 원고를 작성 중... 잠시만 기다려 주세요.")
    try:
        spinner.start()
        with request.urlopen(api_request, timeout=240) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        spinner.stop()
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"보유 이미지 기반 초안 생성 API 호출 실패: {detail}") from exc
    except error.URLError as exc:
        spinner.stop()
        raise RuntimeError("보유 이미지 기반 초안 생성 API 서버에 연결하지 못했습니다.") from exc

    spinner.stop("이미지 기반 원고 작성 완료")
    json_text = extract_json_text(payload)
    try:
        return json.loads(json_text)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"보유 이미지 기반 초안 JSON 파싱 실패: {exc}") from exc


def build_images_payload(image_paths: list[str]) -> list[dict]:
    items: list[dict] = []
    for index, path_str in enumerate(image_paths):
        file_name = "01_thumb" if index == 0 else f"{index + 1:02d}"
        item = {
            "file_name": file_name,
            "type": "thumbnail" if index == 0 else "body",
            "prompt": "",
        }
        if index == 0:
            item["reference_source_path"] = path_str
        else:
            item["source_path"] = path_str
        items.append(item)
    return items


def normalize_paragraphs(paragraphs: list, body_image_count: int) -> list[dict]:
    normalized: list[dict] = []
    for paragraph in paragraphs:
        if not isinstance(paragraph, dict):
            continue
        text = str(paragraph.get("text", "")).strip()
        if not text:
            continue
        normalized.append({"text": text})

    if len(normalized) < max(1, body_image_count):
        raise RuntimeError("이미지 순서를 맞출 만큼의 문단이 충분히 생성되지 않았습니다.")
    return normalized


def assign_images_to_paragraphs(result: dict, image_paths: list[str], request_data: dict) -> dict:
    body_image_count = max(0, len(image_paths) - 1)
    paragraphs = normalize_paragraphs(result.get("paragraphs", []), body_image_count)

    for index in range(body_image_count):
        image_name = f"{index + 2:02d}"
        paragraphs[index]["image_after"] = image_name

    result["paragraphs"] = paragraphs
    images = build_images_payload(image_paths)
    if images:
        images[0]["prompt"] = build_thumbnail_prompt(request_data, str(result.get("title", "")).strip())
    result["images"] = images
    return result


def run_server_mode(data: dict, research_payload: dict | None, image_paths: list[str], prompt_text: str) -> dict:
    image_items = [build_image_item(path) for path in image_paths]
    response = call_server(
        "/draft/generate-from-images",
        {
            "request": data,
            "research": research_payload,
            "image_paths": image_paths,
            "image_items": image_items,
            "prompt": prompt_text,
        },
    )
    result = pick_response_payload(response, "draft_result", "draft")
    return assign_images_to_paragraphs(result, image_paths, data)


def main() -> int:
    configure_console_encoding()
    try:
        data = read_json(INPUT_FILE)
        image_paths = [str(path).strip() for path in data.get("selected_image_paths", []) if str(path).strip()]
        research_payload = read_json(RESEARCH_FILE) if RESEARCH_FILE.exists() else None
        if not image_paths:
            raise RuntimeError("선택된 이미지 파일이 없습니다.")
        for path_str in image_paths:
            if not Path(path_str).exists():
                raise FileNotFoundError(f"선택된 이미지 파일을 찾지 못했습니다: {path_str}")

        content = build_request_content(data, research_payload)
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        (LOG_DIR / "last_image_to_draft_request.json").write_text(
            json.dumps({"image_paths": image_paths}, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        prompt_text = next(
            (item.get("text", "") for item in content if isinstance(item, dict) and item.get("type") == "input_text"),
            "",
        )
        if prompt_text:
            (LOG_DIR / "last_image_to_draft_prompt.txt").write_text(prompt_text, encoding="utf-8")

        if is_server_mode():
            print("server mode로 이미지 기반 초안을 요청합니다.", flush=True)
            result = run_server_mode(data, research_payload, image_paths, prompt_text)
        else:
            result = request_result(content)
            result = assign_images_to_paragraphs(result, image_paths, data)

        write_json_file(OUTPUT_FILE, result)
    except Exception as exc:
        print(f"실패 원인: {exc}", file=sys.stderr)
        return 1

    print(f"초안 저장 완료: {OUTPUT_FILE}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
