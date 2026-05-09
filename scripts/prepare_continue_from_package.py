import json
import re
import sys
from pathlib import Path
from typing import Any

BASE_DIR = Path(__file__).resolve().parent.parent
RESULT_PATH = BASE_DIR / "jobs" / "latest_result.json"
REQUEST_PATH = BASE_DIR / "inputs" / "request.json"


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def split_blocks(text: str) -> list[str]:
    normalized = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not normalized:
        return []
    blocks = re.split(r"\n\s*\n+", normalized)
    return [block.strip() for block in blocks if block.strip()]


def normalize_paragraph_text(block: str) -> str:
    lines = [line.strip() for line in block.replace("\r\n", "\n").replace("\r", "\n").split("\n") if line.strip()]
    return " ".join(lines).strip()


def parse_tags(tags_text: str) -> list[str]:
    tags: list[str] = []
    for part in tags_text.replace("\r\n", " ").replace("\n", " ").split():
        cleaned = part.strip()
        if not cleaned:
            continue
        if cleaned.startswith("#"):
            cleaned = cleaned[1:]
        cleaned = cleaned.strip()
        if cleaned:
            tags.append(cleaned)
    return tags


def load_request_defaults() -> tuple[list[str], str]:
    if not REQUEST_PATH.exists():
        return [], ""
    try:
        request_data = json.loads(read_text(REQUEST_PATH))
    except Exception:
        return [], ""

    topic = str(request_data.get("topic", "")).strip()
    candidates: list[str] = []
    if topic:
        candidates.append(topic)
    return candidates, topic


def main() -> int:
    if len(sys.argv) < 2:
        raise SystemExit("사용할 패키지 폴더 경로가 필요합니다.")

    package_dir = Path(sys.argv[1]).resolve()
    if not package_dir.exists():
        raise SystemExit(f"패키지 폴더를 찾지 못했습니다: {package_dir}")

    title_path = package_dir / "title.txt"
    post_path = package_dir / "post.md"
    tags_path = package_dir / "tags.txt"
    prompts_path = package_dir / "image_prompts.json"

    for required_path in (title_path, post_path, tags_path, prompts_path):
        if not required_path.exists():
            raise SystemExit(f"필수 파일이 없습니다: {required_path}")

    title = read_text(title_path).strip()
    tags = parse_tags(read_text(tags_path))
    post_text = read_text(post_path)
    prompt_data = json.loads(read_text(prompts_path))
    image_items = [item for item in prompt_data.get("items", []) if isinstance(item, dict) and str(item.get("file_name", "")).strip()]

    blocks = split_blocks(post_text)
    if blocks and blocks[0].startswith("# "):
        blocks = blocks[1:]
    if len(blocks) > 1:
        blocks = blocks[1:]

    paragraphs_text = [normalize_paragraph_text(block) for block in blocks if normalize_paragraph_text(block)]
    if not paragraphs_text:
        raise SystemExit("post.md에서 복원할 본문 문단을 찾지 못했습니다.")

    thumbnail_exists = any(str(item.get("file_name", "")).strip() == "01_thumb" for item in image_items)
    body_image_names = [
        str(item.get("file_name", "")).strip()
        for item in image_items
        if str(item.get("file_name", "")).strip() and str(item.get("file_name", "")).strip() != "01_thumb"
    ]

    paragraphs: list[dict[str, Any]] = []
    for index, text in enumerate(paragraphs_text, start=1):
        paragraph_item: dict[str, Any] = {"text": text}
        if index == 1 and thumbnail_exists:
            paragraph_item["image_after"] = "01_thumb"
        elif index >= 2:
            body_index = index - 2
            if body_index < len(body_image_names):
                paragraph_item["image_after"] = body_image_names[body_index]
        paragraphs.append(paragraph_item)

    topic_candidates, selected_topic = load_request_defaults()
    result = {
        "topic_candidates": topic_candidates,
        "selected_topic": selected_topic,
        "title": title,
        "paragraphs": paragraphs,
        "images": image_items,
        "tags": tags,
    }

    RESULT_PATH.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"이어서 작업용 latest_result.json 복원 완료: {RESULT_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
