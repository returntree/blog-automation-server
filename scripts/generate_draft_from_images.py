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
        parts.append(f"업체는 {business_name}")
    if topic:
        parts.append(f"주제는 {topic}")
    if region:
        parts.append(f"지역 맥락은 {region}")
    if image_style:
        parts.append(f"이미지 스타일은 {image_style}")
    if title_text:
        parts.append(f"이미지 안에는 '{title_text}' 문구만 굵고 선명하게 배치")
    return ", ".join(parts)


def build_request_content(data: dict, research_payload: dict | None = None) -> list[dict]:
    image_paths = [str(path).strip() for path in data.get("selected_image_paths", []) if str(path).strip()]
    body_image_count = max(0, len(image_paths) - 1)
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
당신은 실제 사진을 분석해 그 사진 순서에 맞는 블로그 초안을 만드는 작성 도우미입니다.

첨부한 이미지를 보고 사진 순서와 문단 순서가 맞는 블로그 초안을 JSON으로 작성하세요.
첫 번째 이미지는 썸네일 참고용이고, 두 번째 이미지부터는 본문에 실제로 들어갈 이미지입니다.

[입력 정보]
- 업체명: {data.get("business_name", "")}
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
- 위 리서치 참고 정보가 있으면 업체 소개, 서비스 특징, 주제 전달 포인트를 원고에 자연스럽게 반영하세요.
- 단 실제 사진에서 보이지 않는 장면을 과장해서 쓰지 말고 사진 기반 묘사와 리서치 기반 설명의 균형을 맞추세요.
- 사진 문단은 사진 장면을 우선으로 쓰고, 리서치 정보는 설명 보강용으로만 사용하세요.

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
5. JSON 외 설명은 출력하지 마세요.

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
    response = call_server(
        "/draft/generate-from-images",
        {
            "request": data,
            "research": research_payload,
            "image_paths": image_paths,
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
