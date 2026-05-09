import json
import sys
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent
ACTION_FILE = BASE_DIR / "inputs" / "draft_review_action.json"
RESULT_FILE = BASE_DIR / "jobs" / "latest_result.json"


def split_paragraphs(body_text: str) -> list[str]:
    chunks = []
    current: list[str] = []
    for line in body_text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if line.strip():
            current.append(line.strip())
        elif current:
            chunks.append(" ".join(current).strip())
            current = []
    if current:
        chunks.append(" ".join(current).strip())
    return [chunk for chunk in chunks if chunk]


def build_tags(tags_text: str) -> list[str]:
    result: list[str] = []
    for piece in tags_text.replace("\r\n", " ").replace("\n", " ").split():
        cleaned = piece.strip()
        if not cleaned:
            continue
        if not cleaned.startswith("#"):
            cleaned = f"#{cleaned.replace(' ', '')}"
        result.append(cleaned)
    return result


def main() -> int:
    action = json.loads(ACTION_FILE.read_text(encoding="utf-8-sig"))
    result = json.loads(RESULT_FILE.read_text(encoding="utf-8-sig"))
    result["title"] = str(action.get("title", result.get("title", ""))).strip()
    paragraphs = split_paragraphs(str(action.get("body", "")))
    body_images = [item for item in result.get("images", []) if isinstance(item, dict) and str(item.get("file_name", "")) not in ("", "01_thumb")]
    paragraph_payload = []
    for index, paragraph_text in enumerate(paragraphs, start=1):
        paragraph_item = {"text": paragraph_text}
        if index <= len(body_images):
            paragraph_item["image_after"] = str(body_images[index - 1].get("file_name", ""))
        paragraph_payload.append(paragraph_item)
    result["paragraphs"] = paragraph_payload
    result["tags"] = build_tags(str(action.get("tags", "")))
    RESULT_FILE.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"원고 직접 수정 저장 완료: {RESULT_FILE}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
