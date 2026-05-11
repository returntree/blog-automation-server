from __future__ import annotations

import os
import json
from dataclasses import dataclass
from pathlib import Path

try:
    from dotenv import load_dotenv
except ModuleNotFoundError:
    def load_dotenv(*args, **kwargs):
        return False


ROOT_DIR = Path(__file__).resolve().parents[1]
ENV_PATH = ROOT_DIR / ".env"

load_dotenv(ENV_PATH)


@dataclass(slots=True)
class ServerSettings:
    environment: str
    server_host: str
    server_port: int
    app_base_url: str
    data_dir: Path
    admin_api_token: str
    api_auth_token: str
    openai_api_key: str
    billing_webhook_token: str
    allow_origins: str
    default_plan: str
    demo_username: str
    demo_password: str
    plan_limits: dict[str, dict[str, int]]


DEFAULT_PLAN_LIMITS = {
    "starter": {
        "monthly_drafts": 30,
        "monthly_images": 300,
    },
    "pro": {
        "monthly_drafts": 200,
        "monthly_images": 2000,
    },
    "internal": {},
}


def _load_plan_limits() -> dict[str, dict[str, int]]:
    raw = os.getenv("PLAN_LIMITS_JSON", "").strip()
    if not raw:
        return DEFAULT_PLAN_LIMITS

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return DEFAULT_PLAN_LIMITS

    normalized: dict[str, dict[str, int]] = {}
    if not isinstance(data, dict):
        return DEFAULT_PLAN_LIMITS

    for plan_name, limits in data.items():
        if not isinstance(plan_name, str) or not isinstance(limits, dict):
            continue
        normalized_limits: dict[str, int] = {}
        for limit_name, value in limits.items():
            if not isinstance(limit_name, str):
                continue
            try:
                normalized_limits[limit_name] = max(0, int(value))
            except (TypeError, ValueError):
                continue
        normalized[plan_name.strip() or "starter"] = normalized_limits

    return normalized or DEFAULT_PLAN_LIMITS


def _resolve_data_dir() -> Path:
    raw = os.getenv("DATA_DIR", "").strip()
    if not raw:
        path = ROOT_DIR / "data"
    else:
        path = Path(raw).expanduser()
        if not path.is_absolute():
            path = (ROOT_DIR / path).resolve()
    path.mkdir(parents=True, exist_ok=True)
    return path


def load_server_settings() -> ServerSettings:
    data_dir = _resolve_data_dir()
    server_port_raw = os.getenv("PORT", "").strip() or os.getenv("SERVER_PORT", "8000").strip() or "8000"
    return ServerSettings(
        environment=os.getenv("APP_ENV", "development").strip() or "development",
        server_host=os.getenv("SERVER_HOST", "0.0.0.0").strip() or "0.0.0.0",
        server_port=int(server_port_raw),
        app_base_url=os.getenv("APP_BASE_URL", "").strip(),
        data_dir=data_dir,
        admin_api_token=os.getenv("ADMIN_API_TOKEN", "").strip(),
        api_auth_token=os.getenv("API_AUTH_TOKEN", "").strip(),
        openai_api_key=os.getenv("OPENAI_API_KEY", "").strip(),
        billing_webhook_token=os.getenv("BILLING_WEBHOOK_TOKEN", "").strip(),
        allow_origins=os.getenv("ALLOW_ORIGINS", "*").strip() or "*",
        default_plan=os.getenv("DEFAULT_PLAN", "starter").strip() or "starter",
        demo_username=os.getenv("DEMO_USERNAME", "admin").strip() or "admin",
        demo_password=os.getenv("DEMO_PASSWORD", "change-this-password").strip() or "change-this-password",
        plan_limits=_load_plan_limits(),
    )


def get_server_settings() -> ServerSettings:
    return load_server_settings()

