import json
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib import error, request

from client_api import call_server, is_server_mode, pick_response_payload, write_json_file
from progress_spinner import ProgressSpinner

BASE_DIR = Path(__file__).resolve().parent.parent
INPUT_FILE = BASE_DIR / "inputs" / "request.json"
TEMPLATE_FILE = BASE_DIR / "templates" / "research_prompt_template.txt"
OUTPUT_FILE = BASE_DIR / "research" / "latest_research.json"
LOG_DIR = BASE_DIR / "logs"
MODEL = os.getenv("OPENAI_RESEARCH_MODEL", os.getenv("OPENAI_MODEL", "gpt-5-mini"))
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


def build_prompt(request_data: dict[str, Any], template: str) -> str:
    replacements = {
        "{business_name}": request_data["business_name"],
        "{topic}": request_data["topic"],
        "{writing_style}": request_data["writing_style"],
        "{region}": request_data.get("region", ""),
        "{target_audience}": request_data.get("target_audience", ""),
        "{must_include}": ", ".join(request_data.get("must_include", [])),
    }
    prompt = template
    for key, value in replacements.items():
        prompt = prompt.replace(key, value)
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

    raise ValueError("리서치 응답에서 JSON 본문을 찾지 못했습니다.")


def request_research(prompt: str) -> dict[str, Any]:
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY 환경 변수가 설정되어 있지 않습니다.")

    request_body = {
        "model": MODEL,
        "input": prompt,
        "tools": [{"type": "web_search"}],
        "tool_choice": "auto",
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

    spinner = ProgressSpinner("온라인 리서치 수집 중... 잠시만 기다려 주세요.")
    try:
        spinner.start()
        with request.urlopen(api_request, timeout=240) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        spinner.stop()
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"리서치 API 호출 실패: {detail}") from exc
    except error.URLError as exc:
        spinner.stop()
        raise RuntimeError("리서치 API 서버에 연결하지 못했습니다.") from exc

    spinner.stop("온라인 리서치 수집 완료")
    return extract_output_json(payload)


def save_result(result: dict[str, Any]) -> None:
    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    wrapped = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "request_file": str(INPUT_FILE),
        "research": result,
    }
    OUTPUT_FILE.write_text(json.dumps(wrapped, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def run_server_mode(request_data: dict[str, Any], prompt: str) -> None:
    response = call_server(
        "/research/generate",
        {
            "request": request_data,
            "prompt": prompt,
        },
    )
    research_result = pick_response_payload(response, "research", "research_result")
    if "generated_at" in research_result and "research" in research_result:
        write_json_file(OUTPUT_FILE, research_result)
        return
    save_result(research_result)


def main() -> int:
    configure_console_encoding()
    try:
        print(f"입력 파일 읽는 중: {INPUT_FILE}", flush=True)
        request_data = read_json(INPUT_FILE)
        print(f"리서치 템플릿 읽는 중: {TEMPLATE_FILE}", flush=True)
        template = read_text(TEMPLATE_FILE)
        prompt = build_prompt(request_data, template)

        LOG_DIR.mkdir(parents=True, exist_ok=True)
        (LOG_DIR / "last_research_prompt.txt").write_text(prompt, encoding="utf-8")
        print("리서치 프롬프트 저장 완료", flush=True)

        if is_server_mode():
            run_server_mode(request_data, prompt)
        else:
            result = request_research(prompt)
            save_result(result)
    except Exception as exc:
        print(f"실패 원인: {exc}", file=sys.stderr)
        return 1

    print(f"리서치 저장 완료: {OUTPUT_FILE}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
