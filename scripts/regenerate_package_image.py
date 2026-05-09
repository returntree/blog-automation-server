import base64
import json
import os
import sys
from pathlib import Path
from urllib import request

from client_api import call_server_image, is_server_mode, load_client_settings

BASE_DIR = Path(__file__).resolve().parent.parent
JOBS_DIR = BASE_DIR / "jobs"
ACTION_FILE = BASE_DIR / "inputs" / "image_review_action.json"
IMAGE_API_URL = "https://api.openai.com/v1/images/generations"
IMAGE_SIZE = os.getenv("OPENAI_IMAGE_SIZE", "1536x1024")
THUMBNAIL_IMAGE_MODEL = os.getenv("OPENAI_THUMBNAIL_IMAGE_MODEL", "gpt-image-1.5")
THUMBNAIL_IMAGE_QUALITY = os.getenv("OPENAI_THUMBNAIL_IMAGE_QUALITY", "medium")
BODY_IMAGE_MODEL = os.getenv("OPENAI_BODY_IMAGE_MODEL", "gpt-image-1-mini")
BODY_IMAGE_QUALITY = os.getenv("OPENAI_BODY_IMAGE_QUALITY", "low")


def find_latest_package_dir() -> Path:
    candidates = [path for path in JOBS_DIR.glob("upload_package_*") if path.is_dir()]
    if not candidates:
        raise FileNotFoundError("최신 업로드 패키지 폴더를 찾지 못했습니다.")
    return max(candidates, key=lambda path: path.stat().st_mtime)


def resolve_image_profile(item: dict) -> tuple[str, str]:
    item_type = str(item.get("type", "")).strip().lower()
    if item_type == "thumbnail":
        return THUMBNAIL_IMAGE_MODEL, THUMBNAIL_IMAGE_QUALITY
    return BODY_IMAGE_MODEL, BODY_IMAGE_QUALITY


def request_image_base64(prompt: str, model: str, quality: str) -> str:
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY 환경 변수가 설정되어 있지 않습니다.")

    body = {
        "model": model,
        "prompt": prompt,
        "size": IMAGE_SIZE,
        "quality": quality,
    }
    api_request = request.Request(
        IMAGE_API_URL,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with request.urlopen(api_request, timeout=300) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return payload["data"][0]["b64_json"]


def request_image_via_server(prompt: str, model: str, quality: str) -> str:
    settings = load_client_settings()
    return call_server_image(
        prompt=prompt,
        model=model,
        quality=quality,
        settings=settings,
    )


def main() -> int:
    action = json.loads(ACTION_FILE.read_text(encoding="utf-8-sig"))
    server_mode = is_server_mode()
    package_dir_value = str(action.get("package_dir", "")).strip()
    package_dir = Path(package_dir_value) if package_dir_value else find_latest_package_dir()
    if not package_dir.exists():
        raise FileNotFoundError(f"패키지 폴더를 찾지 못했습니다: {package_dir}")
    prompts_path = package_dir / "image_prompts.json"
    prompts = json.loads(prompts_path.read_text(encoding="utf-8-sig"))

    selected_file_name = str(action.get("file_name", "")).strip()
    instruction = str(action.get("instruction", "")).strip()
    if not selected_file_name or not instruction:
        print("재생성할 이미지와 요청 내용을 모두 입력해야 합니다.", file=sys.stderr)
        return 1

    target_item = None
    for item in prompts.get("items", []):
        if str(item.get("file_name", "")).strip() == selected_file_name:
            target_item = item
            break

    if not target_item:
        print(f"재생성 대상 이미지를 찾지 못했습니다: {selected_file_name}", file=sys.stderr)
        return 1

    if str(target_item.get("source_path", "")).strip():
        print("사용자 제공 이미지는 자동 재생성할 수 없습니다.", file=sys.stderr)
        return 1

    model, quality = resolve_image_profile(target_item)
    updated_prompt = f"{target_item.get('prompt', '').strip()}\n\n[재생성 요청]\n{instruction}"
    if server_mode:
        image_base64 = request_image_via_server(updated_prompt, model, quality)
    else:
        image_base64 = request_image_base64(updated_prompt, model, quality)

    output_path = package_dir / str(target_item.get("output_path", f"images/{selected_file_name}.png")).replace("/", os.sep)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(base64.b64decode(image_base64))

    target_item["prompt"] = updated_prompt
    prompts_path.write_text(json.dumps(prompts, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"이미지 재생성 완료: {output_path} ({model}, {quality})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
