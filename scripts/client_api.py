from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

ROOT_DIR = Path(__file__).resolve().parents[1]
CONFIG_DIR = ROOT_DIR / "config"
CLIENT_SETTINGS_PATH = CONFIG_DIR / "client_settings.json"
DIRECT_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class ClientApiError(RuntimeError):
    pass


def load_client_settings() -> dict[str, Any]:
    if CLIENT_SETTINGS_PATH.exists():
        with CLIENT_SETTINGS_PATH.open("r", encoding="utf-8-sig") as file:
            return json.load(file)
    return {}


def save_client_settings(settings: dict[str, Any]) -> None:
    CLIENT_SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    with CLIENT_SETTINGS_PATH.open("w", encoding="utf-8") as file:
        json.dump(settings, file, ensure_ascii=False, indent=2)


def clear_saved_auth(settings: dict[str, Any] | None = None) -> dict[str, Any]:
    settings = dict(settings or load_client_settings())
    settings["api_auth_token"] = ""
    settings["username"] = ""
    settings["plan_name"] = ""
    settings["account_status"] = ""
    settings["account_expires_at"] = ""
    save_client_settings(settings)
    return settings


def is_server_mode(settings: dict[str, Any] | None = None) -> bool:
    settings = settings or load_client_settings()
    return settings.get("client_mode") == "server"


def _request_json(
    url: str,
    token: str | None = None,
    payload: dict[str, Any] | None = None,
    method: str = "POST",
) -> dict[str, Any]:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Content-Type", "application/json; charset=utf-8")
    if token:
        request.add_header("Authorization", f"Bearer {token}")

    try:
        with DIRECT_OPENER.open(request, timeout=300) as response:
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        raise ClientApiError(f"서버 호출 실패({exc.code}): {raw}") from exc
    except urllib.error.URLError as exc:
        raise ClientApiError(f"서버 연결 실패: {exc.reason}") from exc

    try:
        return json.loads(body)
    except json.JSONDecodeError as exc:
        raise ClientApiError(f"서버 응답을 JSON으로 해석하지 못했습니다: {body}") from exc


def call_server_json(
    endpoint: str,
    payload: dict[str, Any] | None = None,
    settings: dict[str, Any] | None = None,
    method: str = "POST",
) -> dict[str, Any]:
    settings = settings or load_client_settings()
    base_url = (settings.get("server_base_url") or "").strip().rstrip("/")
    if not base_url:
        raise ClientApiError("server mode인데 server_base_url이 설정되지 않았습니다.")

    token = (settings.get("api_auth_token") or "").strip()
    if not token:
        raise ClientApiError("server mode인데 api_auth_token이 설정되지 않았습니다.")

    return _request_json(f"{base_url}{endpoint}", token=token, payload=payload, method=method)


def call_public_server_json(base_url: str, endpoint: str, method: str = "GET") -> dict[str, Any]:
    base_url = (base_url or "").strip().rstrip("/")
    if not base_url:
        raise ClientApiError("서버 주소가 비어 있습니다.")
    return _request_json(f"{base_url}{endpoint}", token=None, payload=None, method=method)


def call_server_json_with_token(
    base_url: str,
    token: str,
    endpoint: str,
    payload: dict[str, Any] | None = None,
    method: str = "POST",
) -> dict[str, Any]:
    base_url = (base_url or "").strip().rstrip("/")
    token = (token or "").strip()
    if not base_url:
        raise ClientApiError("서버 주소가 비어 있습니다.")
    if not token:
        raise ClientApiError("관리자 토큰이 비어 있습니다.")

    return _request_json(f"{base_url}{endpoint}", token=token, payload=payload, method=method)


def call_admin_server_json(
    base_url: str,
    admin_token: str,
    endpoint: str,
    *,
    payload: dict[str, Any] | None = None,
    method: str = "GET",
) -> dict[str, Any]:
    return call_server_json_with_token(
        base_url=base_url,
        token=admin_token,
        endpoint=endpoint,
        payload=payload,
        method=method,
    )


def get_admin_account_overview(base_url: str, admin_token: str) -> dict[str, Any]:
    return call_admin_server_json(
        base_url=base_url,
        admin_token=admin_token,
        endpoint="/admin/accounts/overview",
        method="GET",
    )


def call_server(endpoint: str, payload: dict[str, Any], settings: dict[str, Any] | None = None) -> dict[str, Any]:
    return call_server_json(endpoint, payload=payload, settings=settings, method="POST")


def post_usage_event(
    event_type: str,
    *,
    stage: str = "",
    status: str = "",
    details: dict[str, Any] | None = None,
    settings: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return call_server_json(
        "/usage/events",
        payload={
            "event_type": event_type,
            "stage": stage,
            "status": status,
            "details": details or {},
        },
        settings=settings,
        method="POST",
    )


def call_server_image(
    prompt: str,
    model: str,
    quality: str,
    reference_image_path: str | None = None,
    settings: dict[str, Any] | None = None,
) -> str:
    response = call_server(
        "/images/generate",
        payload={
            "prompt": prompt,
            "model": model,
            "quality": quality,
            "reference_image_path": reference_image_path,
        },
        settings=settings,
    )
    image_base64 = response.get("image_base64")
    if not image_base64:
        raise ClientApiError("서버 이미지 생성 응답에 image_base64가 없습니다.")
    return str(image_base64)


def check_license(username: str, settings: dict[str, Any] | None = None) -> dict[str, Any]:
    settings = settings or load_client_settings()
    payload = {
        "username": username,
        "device_id": os.environ.get("COMPUTERNAME", "unknown"),
    }
    return call_server_json("/license/status", payload=payload, settings=settings, method="POST")


def get_auth_me(settings: dict[str, Any] | None = None) -> dict[str, Any]:
    return call_server_json("/auth/me", payload=None, settings=settings, method="GET")


def logout(settings: dict[str, Any] | None = None) -> dict[str, Any]:
    return call_server_json("/auth/logout", payload={}, settings=settings, method="POST")


def get_available_plans(settings: dict[str, Any] | None = None) -> dict[str, Any]:
    settings = settings or load_client_settings()
    base_url = (settings.get("server_base_url") or "").strip().rstrip("/")
    if not base_url:
        raise ClientApiError("server mode인데 server_base_url이 설정되지 않았습니다.")
    return call_public_server_json(base_url, "/plans", method="GET")


def get_subscription_status(settings: dict[str, Any] | None = None) -> dict[str, Any]:
    return call_server_json("/subscription/me", payload=None, settings=settings, method="GET")


def pick_response_payload(response: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        if key in response:
            return response[key]

    if "result" in response:
        return response["result"]

    raise ClientApiError(f"서버 응답에 기대한 키가 없습니다: {', '.join(keys)}")


def write_json_file(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as file:
        json.dump(data, file, ensure_ascii=False, indent=2)
