import json
import shutil
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

BASE_DIR = Path(__file__).resolve().parent.parent
SOURCE_FILE = BASE_DIR / "jobs" / "latest_result.json"
REQUEST_FILE = BASE_DIR / "inputs" / "request.json"
JOBS_DIR = BASE_DIR / "jobs"
PARAGRAPH_SEPARATOR = "\n\n\n"


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8-sig") as file:
        return json.load(file)


def load_request_data() -> dict[str, Any]:
    if not REQUEST_FILE.exists():
        return {}
    try:
        return read_json(REQUEST_FILE)
    except Exception:
        return {}


def make_output_dir(reuse_dir: Path | None = None) -> Path:
    if reuse_dir is not None:
        reuse_dir.mkdir(parents=True, exist_ok=True)
        (reuse_dir / "images").mkdir(parents=True, exist_ok=True)
        return reuse_dir

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_dir = JOBS_DIR / f"upload_package_{timestamp}"
    output_dir.mkdir(parents=True, exist_ok=False)
    (output_dir / "images").mkdir()
    return output_dir


def find_natural_breakpoint(sentence: str, target_length: int = 40) -> int:
    if len(sentence) <= target_length:
        return -1

    candidates = [
        ", ",
        ",",
        " 그리고 ",
        " 또한 ",
        " 특히 ",
        " 하지만 ",
        " 따라서 ",
        " 동시에 ",
        " 위해 ",
        "에서 ",
        "으로 ",
    ]

    best_index = -1
    best_distance = 10**9
    for token in candidates:
        start = 0
        while True:
            index = sentence.find(token, start)
            if index < 0:
                break
            break_index = index + len(token.rstrip())
            if 18 <= break_index <= len(sentence) - 10:
                distance = abs(target_length - break_index)
                if distance < best_distance:
                    best_distance = distance
                    best_index = break_index
            start = index + 1
    return best_index


def wrap_long_sentence(sentence: str, target_length: int = 40) -> str:
    sentence = sentence.strip()
    if len(sentence) <= target_length:
        return sentence

    lines: list[str] = []
    remaining = sentence
    while len(remaining) > target_length:
        break_index = find_natural_breakpoint(remaining, target_length)
        if break_index < 0:
            break
        lines.append(remaining[:break_index].strip())
        remaining = remaining[break_index:].strip()

    if remaining:
        lines.append(remaining)

    return "\n".join(lines)


def format_paragraph_text(text: str) -> str:
    normalized = " ".join(text.split())
    if not normalized:
        return ""

    formatted_sentences: list[str] = []
    sentence = ""
    for char in normalized:
        sentence += char
        if char in ".!?":
            cleaned = sentence.strip()
            if cleaned:
                formatted_sentences.append(wrap_long_sentence(cleaned))
            sentence = ""

    if sentence.strip():
        formatted_sentences.append(wrap_long_sentence(sentence.strip()))

    return "\n".join(part for part in formatted_sentences if part)


def build_intro_paragraph(title: str, request_data: dict[str, Any]) -> str:
    return ""


def build_packaged_paragraphs(title: str, paragraphs: list[dict[str, Any]], request_data: dict[str, Any]) -> list[str]:
    cleaned_paragraphs = [
        format_paragraph_text(paragraph.get("text", "").strip())
        for paragraph in paragraphs
        if isinstance(paragraph, dict) and isinstance(paragraph.get("text"), str) and paragraph.get("text").strip()
    ]
    packaged_paragraphs: list[str] = []
    packaged_paragraphs.extend([paragraph for paragraph in cleaned_paragraphs if paragraph])
    return packaged_paragraphs


def build_post_markdown(title: str, packaged_paragraphs: list[str]) -> str:
    return f"# {title.strip()}{PARAGRAPH_SEPARATOR}{PARAGRAPH_SEPARATOR.join(packaged_paragraphs)}\n"


def resolve_packaged_image_name(item: dict[str, Any]) -> str:
    file_name = str(item.get("file_name", "")).strip()
    source_path = str(item.get("source_path", "")).strip()
    if source_path:
        suffix = Path(source_path).suffix.strip().lower()
        if suffix:
            return f"{file_name}{suffix}"
    return f"{file_name}.png"


def build_manifest(source: Path, title: str, paragraphs: list[dict[str, Any]], images: list[dict[str, Any]], packaged_paragraph_count: int) -> dict[str, Any]:
    image_map = {
        item.get("file_name"): item
        for item in images
        if isinstance(item, dict) and item.get("file_name")
    }

    manifest = {
        "source_result": str(source),
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "title": title,
        "paragraph_count": packaged_paragraph_count,
        "image_insertions": [],
    }

    thumbnail_info = image_map.get("01_thumb")
    if thumbnail_info:
        packaged_name = resolve_packaged_image_name(thumbnail_info)
        manifest["image_insertions"].append(
            {
                "position": "after_title",
                "file_name": "01_thumb",
                "type": thumbnail_info.get("type", "thumbnail"),
                "placeholder_path": f"images/{packaged_name}",
            }
        )

    for index, paragraph in enumerate(paragraphs, start=1):
        if not isinstance(paragraph, dict):
            continue
        file_name = paragraph.get("image_after")
        if not file_name or file_name == "01_thumb":
            continue
        image_info = image_map.get(file_name, {})
        packaged_name = resolve_packaged_image_name(image_info)
        manifest["image_insertions"].append(
            {
                "position": "before_paragraph",
                "paragraph_index": index + 1,
                "file_name": file_name,
                "type": image_info.get("type", "unknown"),
                "placeholder_path": f"images/{packaged_name}",
            }
        )

    return manifest


def build_thumbnail_text(title: str) -> str:
    normalized = " ".join(title.replace(":", " ").replace("|", " ").replace("-", " ").split())
    summary_candidates: list[tuple[tuple[str, ...], str]] = [
        (("위험물", "보관", "운영", "원칙"), "위험물 보관 운영원칙"),
        (("위험물", "보관", "규정", "준수"), "위험물 보관 규정준수"),
        (("평택", "위험물", "보관"), "평택 위험물 보관"),
        (("위험물", "보관", "안전"), "위험물 보관 안전관리"),
        (("위험물", "보관"), "위험물 보관 가이드"),
        (("규정", "준수"), "규정준수 운영체크"),
        (("비상", "대응"), "비상대응 운영체계"),
    ]

    for keywords, short_text in summary_candidates:
        if all(keyword in normalized for keyword in keywords):
            return short_text[:15]

    chunks = [chunk.strip() for chunk in normalized.replace(":", " ").split() if chunk.strip()]
    selected_words: list[str] = []
    current_length = 0
    for chunk in chunks:
        extra = len(chunk) if not selected_words else len(chunk) + 1
        if current_length + extra > 15:
            break
        selected_words.append(chunk)
        current_length += extra

    if selected_words:
        return " ".join(selected_words)[:15]
    return normalized.replace(" ", "")[:15]


def normalize_thumbnail_prompt(prompt: str, thumbnail_text: str, image_style: str) -> str:
    prompt = prompt.strip()
    thumbnail_text = thumbnail_text.strip()
    style_clause = f"전체 스타일은 {image_style}, " if image_style else ""
    if not prompt:
        prompt = "블로그 대표 썸네일 이미지"
    return (
        f"{prompt}, {style_clause}네이버 블로그용 완성형 대표 썸네일 이미지, "
        f"이미지 안에는 '{thumbnail_text}' 문구만 정확히 그대로 사용, "
        "문구는 임의로 바꾸거나 줄이거나 다른 표현으로 치환하지 말고 지정 문장을 그대로 유지, "
        "문구는 굵고 크고 선명한 고가독성 한글 타이포그래피로 표현, "
        "장식적인 손글씨체나 과한 효과보다 단순하고 또렷한 한글 서체 느낌을 우선, "
        "글자가 깨지거나 찌그러지거나 잘리거나 겹치지 않게 가장 우선으로 처리, "
        "한글 자모가 분리되거나 오탈자나 이상한 철자가 나오지 않게 가장 강하게 처리, "
        "문구는 최대 2줄까지만 허용하고 각 줄은 짧고 균형 있게 정리, "
        "문구는 중앙 또는 하단 안전영역의 넓은 여백 위에 크게 배치, "
        "배경은 너무 복잡하지 않게 두고 문구 뒤에는 밝고 깔끔한 여백이 보이도록 구성, "
        "짧은 문구 1개 외 다른 텍스트 금지, "
        "광고 포스터 느낌보다 자연스럽고 신뢰감 있는 블로그 썸네일 비주얼로 정리"
    )


def normalize_body_image_prompt(prompt: str, image_style: str) -> str:
    prompt = prompt.strip()
    style_clause = f"전체 스타일은 {image_style}, " if image_style else ""
    if not prompt:
        prompt = "블로그 본문용 현장 이미지"
    return (
        f"{prompt}, {style_clause}블로그 본문 삽입용 이미지로 생성, "
        "이미지 안에는 글자, 간판 문구, 설명 문장, 포스터 텍스트, 워터마크, 로고성 문구를 넣지 말 것, "
        "장면, 인물, 사물, 배경, 구도, 조명, 분위기만으로 내용을 전달할 것, "
        "자연스럽고 깔끔하며 신뢰감 있는 비주얼로 구성"
    )


def build_image_prompts(title: str, images: list[dict[str, Any]], image_style: str) -> dict[str, Any]:
    def sort_key(item: dict[str, Any]) -> tuple[int, str]:
        file_name = str(item.get("file_name", ""))
        return (0 if file_name == "01_thumb" else 1, file_name)

    thumbnail_text = build_thumbnail_text(title)
    items = []
    for item in sorted(images, key=sort_key):
        if not isinstance(item, dict):
            continue
        file_name = item.get("file_name", "")
        prompt = item.get("prompt", "")
        packaged_name = resolve_packaged_image_name(item)
        normalized_prompt = (
            normalize_thumbnail_prompt(prompt, thumbnail_text, image_style)
            if file_name == "01_thumb"
            else normalize_body_image_prompt(prompt, image_style)
        )
        prompt_item = {
            "file_name": file_name,
            "type": item.get("type", ""),
            "prompt": normalized_prompt,
            "output_path": f"images/{packaged_name}",
        }
        source_path = str(item.get("source_path", "")).strip()
        if source_path:
            prompt_item["source_path"] = source_path
        reference_source_path = str(item.get("reference_source_path", "")).strip()
        if reference_source_path:
            prompt_item["reference_source_path"] = reference_source_path
        items.append(prompt_item)

    return {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "items": items,
    }


def build_tags_text(tags: list[Any]) -> str:
    normalized_tags: list[str] = []
    for tag in tags:
        if not isinstance(tag, str):
            continue
        cleaned = tag.strip()
        if not cleaned:
            continue
        if not cleaned.startswith("#"):
            cleaned = f"#{cleaned.replace(' ', '')}"
        normalized_tags.append(cleaned)
    return " ".join(normalized_tags) + "\n"


def write_text(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def copy_provided_images(images: list[dict[str, Any]], images_dir: Path) -> None:
    for item in images:
        if not isinstance(item, dict):
            continue
        source_path = str(item.get("source_path", "")).strip()
        if not source_path:
            continue
        source = Path(source_path)
        if not source.exists():
            raise FileNotFoundError(f"사용자 제공 이미지 파일을 찾지 못했습니다: {source}")
        target = images_dir / resolve_packaged_image_name(item)
        shutil.copy2(source, target)


def load_image_style() -> str:
    if not REQUEST_FILE.exists():
        return ""
    try:
        request_data = read_json(REQUEST_FILE)
    except Exception:
        return ""
    return str(request_data.get("image_style", "")).strip()


def parse_reuse_dir() -> Path | None:
    if len(sys.argv) < 2:
        return None
    raw = str(sys.argv[1]).strip()
    if not raw:
        return None
    return Path(raw).expanduser().resolve()


def main() -> int:
    result = read_json(SOURCE_FILE)
    reuse_dir = parse_reuse_dir()
    output_dir = make_output_dir(reuse_dir)
    image_style = load_image_style()
    request_data = load_request_data()

    title = str(result.get("title", "")).strip()
    tags = result.get("tags", [])
    paragraphs = result.get("paragraphs", [])
    images = result.get("images", [])
    packaged_paragraphs = build_packaged_paragraphs(title, paragraphs, request_data)

    copy_provided_images(images, output_dir / "images")
    write_text(output_dir / "title.txt", f"{title}\n")
    write_text(output_dir / "post.md", build_post_markdown(title, packaged_paragraphs))
    write_text(output_dir / "tags.txt", build_tags_text(tags))
    write_json(output_dir / "manifest.json", build_manifest(SOURCE_FILE, title, paragraphs, images, len(packaged_paragraphs)))
    write_json(output_dir / "image_prompts.json", build_image_prompts(title, images, image_style))

    print(output_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
