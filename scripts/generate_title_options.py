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
TEMPLATE_FILE = BASE_DIR / "templates" / "title_options_prompt_template.txt"
OUTPUT_FILE = BASE_DIR / "research" / "title_options.json"
LOG_DIR = BASE_DIR / "logs"
MODEL = os.getenv("OPENAI_MODEL", "gpt-5-mini")
RESPONSES_API_URL = "https://api.openai.com/v1/responses"


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
        "{research_summary}": build_research_summary(research_payload),
        "{title_option_count}": str(request_data.get("title_option_count", 5)),
    }
    prompt = template
    for key, value in replacements.items():
        prompt = prompt.replace(key, value)

    extra_request = str(request_data.get("title_extra_request", "")).strip()
    if extra_request:
        prompt += (
            "\n\n[추가 요청]\n"
            f"{extra_request}\n"
            "위 추가 요청을 반영해서 제목 후보를 다시 구성하세요."
        )
    return prompt


def extract_output_json(payload: dict[str, Any]) -> dict[str, Any]:
    if isinstance(payload.get("output_parsed"), dict):
        return payload["output_parsed"]

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

    raise ValueError("제목 후보 응답에서 JSON을 찾지 못했습니다.")


def request_title_options(prompt: str) -> dict[str, Any]:
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

    spinner = ProgressSpinner("제목 후보 생성 중... 잠시만 기다려 주세요.")
    try:
        spinner.start()
        with request.urlopen(api_request, timeout=120) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        spinner.stop()
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"제목 후보 API 호출 실패: {detail}") from exc
    except error.URLError as exc:
        spinner.stop()
        raise RuntimeError("제목 후보 API 서버에 연결하지 못했습니다.") from exc

    spinner.stop("제목 후보 생성 완료")
    return extract_output_json(payload)


def run_server_mode(
    request_data: dict[str, Any], research_payload: dict[str, Any], prompt: str
) -> dict[str, Any]:
    response = call_server(
        "/titles/generate",
        {
            "request": request_data,
            "research": research_payload,
            "prompt": prompt,
        },
    )
    return pick_response_payload(response, "title_options_result", "title_options")


def main() -> int:
    configure_console_encoding()
    try:
        print(f"입력 파일 읽는 중: {INPUT_FILE}", flush=True)
        request_data = read_json(INPUT_FILE)
        print(f"리서치 파일 읽는 중: {RESEARCH_FILE}", flush=True)
        research_payload = read_json(RESEARCH_FILE)
        print(f"제목 템플릿 읽는 중: {TEMPLATE_FILE}", flush=True)
        template = read_text(TEMPLATE_FILE)
        prompt = build_prompt(request_data, research_payload, template)

        LOG_DIR.mkdir(parents=True, exist_ok=True)
        (LOG_DIR / "last_title_options_prompt.txt").write_text(prompt, encoding="utf-8")
        print("제목 후보 프롬프트 저장 완료", flush=True)

        if is_server_mode():
            result = run_server_mode(request_data, research_payload, prompt)
        else:
            result = request_title_options(prompt)

        desired_count = max(1, int(request_data.get("title_option_count", 5)))
        if isinstance(result.get("title_options"), list):
            result["title_options"] = result["title_options"][:desired_count]
        write_json_file(OUTPUT_FILE, result)
    except Exception as exc:
        print(f"실패 원인: {exc}", file=sys.stderr)
        return 1

    print(f"제목 후보 저장 완료: {OUTPUT_FILE}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
