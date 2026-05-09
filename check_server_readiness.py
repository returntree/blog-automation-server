from __future__ import annotations

import json
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent
ENV_PATH = ROOT_DIR / ".env"
ENV_EXAMPLE_PATH = ROOT_DIR / ".env.example"
RENDER_YAML_PATH = ROOT_DIR / "render.yaml"
REQUIREMENTS_PATH = ROOT_DIR / "requirements.txt"
SETTINGS_PATH = ROOT_DIR / "app" / "settings.py"
README_PATH = ROOT_DIR / "README.md"


def load_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def print_section(title: str) -> None:
    print(f"\n== {title} ==")


def main() -> int:
    errors: list[str] = []
    warnings: list[str] = []
    infos: list[str] = []

    print_section("서버 배포 준비 점검")
    print(f"점검 기준 폴더: {ROOT_DIR}")

    required_files = [
        ENV_EXAMPLE_PATH,
        RENDER_YAML_PATH,
        REQUIREMENTS_PATH,
        SETTINGS_PATH,
        README_PATH,
    ]
    missing_files = [str(path.relative_to(ROOT_DIR)) for path in required_files if not path.exists()]
    if missing_files:
        errors.append("필수 파일이 누락되었습니다: " + ", ".join(missing_files))
    else:
        infos.append("필수 배포 파일이 모두 존재합니다.")

    env_values = load_env_file(ENV_PATH)
    if not ENV_PATH.exists():
        warnings.append(".env 파일이 없습니다. Render 배포만 할 경우엔 괜찮지만, 로컬 테스트 전에는 .env를 준비하세요.")
    else:
        infos.append(".env 파일을 찾았습니다.")

    app_env = env_values.get("APP_ENV", "").strip()
    if app_env and app_env not in {"development", "production"}:
        errors.append("APP_ENV 값은 development 또는 production 이어야 합니다.")
    elif not app_env:
        warnings.append("APP_ENV 값이 비어 있습니다. production 배포 전에는 APP_ENV=production 을 권장합니다.")

    openai_key = env_values.get("OPENAI_API_KEY", "").strip()
    if not openai_key:
        warnings.append("OPENAI_API_KEY 값이 비어 있습니다. 서버에서 실제 생성 기능을 쓰려면 반드시 필요합니다.")
    elif not openai_key.startswith("sk-"):
        warnings.append("OPENAI_API_KEY 형식이 일반적인 OpenAI 키와 달라 보입니다. 값이 맞는지 확인하세요.")

    api_auth_token = env_values.get("API_AUTH_TOKEN", "").strip()
    if not api_auth_token:
        warnings.append("API_AUTH_TOKEN 값이 비어 있습니다. 관리자 API 보호를 위해 설정하세요.")
    elif api_auth_token == "change-this-admin-token":
        errors.append("API_AUTH_TOKEN 이 예시 기본값입니다. 실제 배포 전에는 반드시 교체하세요.")

    demo_password = env_values.get("DEMO_PASSWORD", "").strip()
    if demo_password == "change-this-password":
        errors.append("DEMO_PASSWORD 가 예시 기본값입니다. 실제 배포 전에는 반드시 교체하세요.")

    plan_limits_json = env_values.get("PLAN_LIMITS_JSON", "").strip()
    if plan_limits_json:
        try:
            parsed = json.loads(plan_limits_json)
            if not isinstance(parsed, dict):
                errors.append("PLAN_LIMITS_JSON 은 JSON 객체 형태여야 합니다.")
            else:
                infos.append(f"PLAN_LIMITS_JSON 에 {len(parsed)}개 플랜이 설정되어 있습니다.")
        except json.JSONDecodeError as exc:
            errors.append(f"PLAN_LIMITS_JSON 파싱 실패: {exc}")
    else:
        warnings.append("PLAN_LIMITS_JSON 이 비어 있습니다. 플랜별 제한을 쓸 예정이면 미리 설정하세요.")

    render_yaml = RENDER_YAML_PATH.read_text(encoding="utf-8") if RENDER_YAML_PATH.exists() else ""
    if "DATA_DIR" not in render_yaml or "/var/data/blog_automation" not in render_yaml:
        warnings.append("render.yaml 의 Persistent Disk 경로 설정이 기대값과 다를 수 있습니다.")
    else:
        infos.append("render.yaml 의 DATA_DIR 설정이 확인되었습니다.")

    if not (ROOT_DIR / ".python-version").exists():
        warnings.append(".python-version 파일이 없습니다. Render 런타임 버전 고정을 권장합니다.")
    else:
        infos.append(".python-version 파일이 준비되어 있습니다.")

    print_section("점검 결과")
    for item in infos:
        print(f"[확인] {item}")
    for item in warnings:
        print(f"[주의] {item}")
    for item in errors:
        print(f"[오류] {item}")

    print_section("요약")
    print(f"확인: {len(infos)}건")
    print(f"주의: {len(warnings)}건")
    print(f"오류: {len(errors)}건")

    if errors:
        print("배포 전 수정이 필요한 항목이 있습니다.")
        return 1

    print("치명적인 배포 차단 항목은 없습니다.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
