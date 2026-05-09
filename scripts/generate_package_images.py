import base64
import json
import mimetypes
import os
import sys
import uuid
from pathlib import Path
from typing import Any
from urllib import error, request

from client_api import call_server_image, is_server_mode, load_client_settings

BASE_DIR = Path(__file__).resolve().parent.parent
JOBS_DIR = BASE_DIR / "jobs"
IMAGE_API_URL = "https://api.openai.com/v1/images/generations"
IMAGE_EDIT_API_URL = "https://api.openai.com/v1/images/edits"
IMAGE_SIZE = os.getenv("OPENAI_IMAGE_SIZE", "1536x1024")
THUMBNAIL_IMAGE_MODEL = os.getenv("OPENAI_THUMBNAIL_IMAGE_MODEL", "gpt-image-1.5")
THUMBNAIL_IMAGE_QUALITY = os.getenv("OPENAI_THUMBNAIL_IMAGE_QUALITY", "medium")
BODY_IMAGE_MODEL = os.getenv("OPENAI_BODY_IMAGE_MODEL", "gpt-image-1-mini")
BODY_IMAGE_QUALITY = os.getenv("OPENAI_BODY_IMAGE_QUALITY", "low")


def configure_console_encoding() -> None:
    for stream_name in ("stdout", "stderr"):
        stream = getattr(sys, stream_name, None)
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")


def find_latest_package_dir() -> Path:
    candidates = [path for path in JOBS_DIR.glob("upload_package_*") if path.is_dir()]
    if not candidates:
        raise FileNotFoundError("최신 업로드 패키지 폴더를 찾지 못했습니다.")
    return max(candidates, key=lambda path: path.stat().st_mtime)


def resolve_package_dir() -> Path:
    if len(sys.argv) >= 2 and str(sys.argv[1]).strip():
        package_dir = Path(sys.argv[1]).expanduser().resolve()
        if not package_dir.exists():
            raise FileNotFoundError(f"지정한 업로드 패키지 폴더를 찾지 못했습니다: {package_dir}")
        return package_dir
    return find_latest_package_dir()


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8-sig") as file:
        return json.load(file)


def resolve_image_profile(item: dict[str, Any]) -> tuple[str, str]:
    item_type = str(item.get("type", "")).strip().lower()
    if item_type == "thumbnail":
        return THUMBNAIL_IMAGE_MODEL, THUMBNAIL_IMAGE_QUALITY
    return BODY_IMAGE_MODEL, BODY_IMAGE_QUALITY


def request_image_via_server(
    prompt: str,
    model: str,
    quality: str,
    reference_image_path: Path | None = None,
) -> str:
    settings = load_client_settings()
    return call_server_image(
        prompt=prompt,
        model=model,
        quality=quality,
        reference_image_path=str(reference_image_path) if reference_image_path else None,
        settings=settings,
    )


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
    payload = json.dumps(body).encode("utf-8")
    api_request = request.Request(
        IMAGE_API_URL,
        data=payload,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with request.urlopen(api_request, timeout=300) as response:
            response_data = json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        detail = raw
        try:
            detail = json.loads(raw).get("error", {}).get("message", raw)
        except json.JSONDecodeError:
            pass
        raise RuntimeError(f"OpenAI 이미지 생성 API 호출 실패 (상태 코드 {exc.code}): {detail}") from exc
    except error.URLError as exc:
        raise RuntimeError("OpenAI 이미지 생성 API 서버에 연결하지 못했습니다.") from exc

    data = response_data.get("data")
    if not isinstance(data, list) or not data:
        raise RuntimeError("이미지 생성 응답에 data 항목이 없습니다.")

    image_base64 = data[0].get("b64_json")
    if not image_base64:
        raise RuntimeError("이미지 생성 응답에 b64_json 데이터가 없습니다.")
    return image_base64


def build_multipart_body(fields: dict[str, str], file_field_name: str, file_path: Path) -> tuple[bytes, str]:
    boundary = f"----CodexBoundary{uuid.uuid4().hex}"
    file_bytes = file_path.read_bytes()
    mime_type = mimetypes.guess_type(file_path.name)[0] or "application/octet-stream"
    chunks: list[bytes] = []

    for key, value in fields.items():
        chunks.append(f"--{boundary}\r\n".encode("utf-8"))
        chunks.append(f'Content-Disposition: form-data; name="{key}"\r\n\r\n'.encode("utf-8"))
        chunks.append(str(value).encode("utf-8"))
        chunks.append(b"\r\n")

    chunks.append(f"--{boundary}\r\n".encode("utf-8"))
    chunks.append(
        (
            f'Content-Disposition: form-data; name="{file_field_name}"; filename="{file_path.name}"\r\n'
            f"Content-Type: {mime_type}\r\n\r\n"
        ).encode("utf-8")
    )
    chunks.append(file_bytes)
    chunks.append(b"\r\n")
    chunks.append(f"--{boundary}--\r\n".encode("utf-8"))
    return b"".join(chunks), boundary


def request_edited_image_base64(prompt: str, reference_image_path: Path, model: str, quality: str) -> str:
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY 환경 변수가 설정되어 있지 않습니다.")

    body, boundary = build_multipart_body(
        {
            "model": model,
            "prompt": prompt,
            "size": IMAGE_SIZE,
            "quality": quality,
        },
        "image",
        reference_image_path,
    )
    api_request = request.Request(
        IMAGE_EDIT_API_URL,
        data=body,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
        method="POST",
    )

    try:
        with request.urlopen(api_request, timeout=300) as response:
            response_data = json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        detail = raw
        try:
            detail = json.loads(raw).get("error", {}).get("message", raw)
        except json.JSONDecodeError:
            pass
        raise RuntimeError(f"참고 이미지 기반 썸네일 생성 실패 (상태 코드 {exc.code}): {detail}") from exc
    except error.URLError as exc:
        raise RuntimeError("참고 이미지 기반 썸네일 생성 서버에 연결하지 못했습니다.") from exc

    data = response_data.get("data")
    if not isinstance(data, list) or not data:
        raise RuntimeError("참고 이미지 기반 썸네일 생성 응답에 data 항목이 없습니다.")

    image_base64 = data[0].get("b64_json")
    if not image_base64:
        raise RuntimeError("참고 이미지 기반 썸네일 생성 응답에 b64_json 데이터가 없습니다.")
    return image_base64


def save_image(image_base64: str, output_path: Path) -> None:
    output_path.write_bytes(base64.b64decode(image_base64))


def main() -> int:
    configure_console_encoding()
    server_mode = is_server_mode()

    package_dir = resolve_package_dir()
    prompts_path = package_dir / "image_prompts.json"
    prompt_data = read_json(prompts_path)
    items = prompt_data.get("items", [])
    if not isinstance(items, list) or not items:
        raise RuntimeError("image_prompts.json에 생성할 이미지 항목이 없습니다.")

    success_files: list[str] = []
    failed_items: list[tuple[str, str]] = []

    for item in items:
        if not isinstance(item, dict):
            continue

        file_name = str(item.get("file_name", "")).strip()
        prompt = str(item.get("prompt", "")).strip()
        relative_output = str(item.get("output_path", f"images/{file_name}.png")).strip()
        output_path = package_dir / relative_output.replace("/", os.sep)
        source_path = str(item.get("source_path", "")).strip()
        reference_source_path = str(item.get("reference_source_path", "")).strip()
        model, quality = resolve_image_profile(item)

        if not file_name:
            failed_items.append(("(빈 파일명)", "file_name이 비어 있습니다."))
            continue

        if output_path.exists():
            success_files.append(output_path.name)
            print(f"기존 이미지 유지: {output_path.name}")
            continue

        if source_path:
            failed_items.append((file_name, f"사용자 제공 이미지가 패키지에 없습니다: {output_path}"))
            continue

        if reference_source_path:
            reference_path = Path(reference_source_path)
            if not reference_path.exists():
                failed_items.append((file_name, f"참고 이미지 파일을 찾지 못했습니다: {reference_path}"))
                continue
            if not prompt:
                failed_items.append((file_name, "참고 이미지 기반 썸네일 프롬프트가 비어 있습니다."))
                continue
            try:
                if server_mode:
                    image_base64 = request_image_via_server(prompt, model, quality, reference_path)
                else:
                    image_base64 = request_edited_image_base64(prompt, reference_path, model, quality)
                output_path.parent.mkdir(parents=True, exist_ok=True)
                save_image(image_base64, output_path)
                success_files.append(output_path.name)
                print(f"참고 이미지 기반 썸네일 생성 완료: {output_path.name} ({model}, {quality})")
            except Exception as exc:
                failed_items.append((file_name, str(exc)))
                print(f"썸네일 생성 실패: {file_name} - {exc}", file=sys.stderr)
            continue

        if not prompt:
            failed_items.append((file_name, "프롬프트가 비어 있습니다."))
            continue

        try:
            if server_mode:
                image_base64 = request_image_via_server(prompt, model, quality)
            else:
                image_base64 = request_image_base64(prompt, model, quality)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            save_image(image_base64, output_path)
            success_files.append(output_path.name)
            print(f"생성 완료: {output_path.name} ({model}, {quality})")
        except Exception as exc:
            failed_items.append((file_name, str(exc)))
            print(f"생성 실패: {file_name} - {exc}", file=sys.stderr)

    print(f"패키지 폴더: {package_dir}")

    if failed_items:
        print("실패한 이미지 목록:", file=sys.stderr)
        for item_file_name, message in failed_items:
            print(f"- {item_file_name}: {message}", file=sys.stderr)
        if success_files:
            print("성공한 이미지 파일:", ", ".join(success_files))
        return 1

    print("생성된 이미지 파일:", ", ".join(success_files))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
