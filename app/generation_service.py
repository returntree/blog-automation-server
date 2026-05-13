from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

ROOT_DIR = Path(__file__).resolve().parents[1]
SCRIPTS_DIR = ROOT_DIR / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import collect_blog_research
import generate_blog_draft
import generate_draft_from_images as generate_draft_from_images_module
import generate_draft_from_manual as generate_draft_from_manual_module
import generate_package_images
import generate_title_options
import revise_blog_draft


def _ensure_dict(value: Any, fallback_message: str) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    raise ValueError(fallback_message)


def generate_research(request: dict[str, Any], prompt: str) -> dict[str, Any]:
    result = collect_blog_research.request_research(prompt)
    return _ensure_dict(result, "리서치 결과를 JSON 객체로 받지 못했습니다.")


def generate_titles(request: dict[str, Any], research: dict[str, Any], prompt: str) -> dict[str, Any]:
    result = generate_title_options.request_title_options(prompt)
    return _ensure_dict(result, "제목 후보 결과를 JSON 객체로 받지 못했습니다.")


def generate_draft(
    request: dict[str, Any],
    research: dict[str, Any],
    prompt: str,
    minimum_body_length: int,
    target_body_length: int,
    max_attempts: int,
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    current_prompt = prompt
    attempts = max(1, int(max_attempts or generate_blog_draft.MAX_DRAFT_ATTEMPTS))
    for attempt_number in range(1, attempts + 1):
        result = generate_blog_draft.request_draft(current_prompt, attempt_number)
        try:
            generate_blog_draft.validate_body_length(result)
            break
        except generate_blog_draft.BodyTooShortError:
            if attempt_number >= attempts:
                raise
            current_prompt = generate_blog_draft.build_retry_prompt(prompt, attempt_number + 1)
    return _ensure_dict(result, "초안 결과를 JSON 객체로 받지 못했습니다.")


def generate_draft_from_manual(request: dict[str, Any], prompt: str) -> dict[str, Any]:
    result = generate_draft_from_manual_module.request_result(prompt)
    return _ensure_dict(result, "수동 원고 기반 초안 결과를 JSON 객체로 받지 못했습니다.")


def generate_draft_from_images(
    request: dict[str, Any],
    research: dict[str, Any],
    image_paths: list[str],
    prompt: str,
) -> dict[str, Any]:
    content = generate_draft_from_images_module.build_request_content(
        {**request, "selected_image_paths": image_paths},
        research,
    )
    result = generate_draft_from_images_module.request_result(content)
    normalized = _ensure_dict(result, "이미지 기반 초안 결과를 JSON 객체로 받지 못했습니다.")

    normalized = generate_draft_from_images_module.assign_images_to_paragraphs(
        normalized,
        image_paths,
        request,
    )

    return normalized


def revise_draft(action: str | dict[str, Any], current_result: dict[str, Any], instruction: str) -> dict[str, Any]:
    if isinstance(action, dict):
        action_value = str(action.get("action") or "ai").strip().lower()
    else:
        action_value = str(action).strip().lower()
    if action_value == "manual":
        return current_result

    if action_value != "ai":
        raise ValueError("지원하지 않는 수정 방식입니다. 'manual' 또는 'ai'만 사용할 수 있습니다.")

    payload = {
        "current_result": current_result,
        "instruction": instruction,
    }
    prompt = (
        "당신은 블로그 원고 편집자입니다. 반드시 JSON만 출력하세요. "
        "입력된 현재 결과 JSON 구조를 유지하면서 사용자의 수정 요청을 반영해 새 결과 JSON을 반환하세요."
    )
    response_text = revise_blog_draft.request_revision(prompt, payload)
    revised = revise_blog_draft.extract_output_json(response_text)
    return revise_blog_draft.validate_and_merge(current_result, _ensure_dict(revised, "AI 수정 결과를 JSON 객체로 받지 못했습니다."))


def generate_image(prompt: str, model: str, quality: str, reference_image_path: str | None = None) -> str:
    if reference_image_path:
        return generate_package_images.request_edited_image_base64(
            prompt,
            Path(reference_image_path),
            model,
            quality,
        )
    return generate_package_images.request_image_base64(prompt, model, quality)



