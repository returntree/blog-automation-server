from __future__ import annotations

from datetime import datetime, timezone

from fastapi import Depends, FastAPI, HTTPException, Query, Request, status
from fastapi.middleware.cors import CORSMiddleware

from . import generation_service
from .account_store import AccountStore
from .auth import authenticate_user, get_bearer_token, require_admin_token, verify_token
from .schemas import (
    AccountBillingUpdateRequest,
    AccountCreateRequest,
    AccountExpiryEnforceResponse,
    AccountHistoryListResponse,
    AccountListResponse,
    AccountOverviewResponse,
    AccountPasswordResetRequest,
    AccountStatusUpdateRequest,
    AccountSubscriptionUpdateRequest,
    BillingIssueAccountListResponse,
    BillingIssueSummaryResponse,
    DraftGenerateRequest,
    DraftReviseRequest,
    ExpiringAccountListResponse,
    BillingSyncRequest,
    ImageDraftGenerateRequest,
    ImageGenerateRequest,
    ImageGenerateResponse,
    LicenseRequest,
    LicenseResponse,
    LoginRequest,
    LoginResponse,
    LogoutResponse,
    ManualDraftGenerateRequest,
    PlanListResponse,
    ResearchGenerateRequest,
    SubscriptionStatusResponse,
    TitleGenerateRequest,
    UsageEventListResponse,
    UsageEventRequest,
    UsageSummaryResponse,
)
from .settings import ServerSettings, get_server_settings
from .subscription_store import SubscriptionStore
from .usage_store import UsageStore

app = FastAPI(title="blog_automation server", version="0.1.0")

_settings = get_server_settings()
app.add_middleware(
    CORSMiddleware,
    allow_origins=_settings.allow_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

_store = AccountStore()
_usage_store = UsageStore()
_history_store = SubscriptionStore()

LIMIT_LABELS = {
    "monthly_drafts": "?대쾲 ???먭퀬 ?앹꽦",
    "monthly_images": "?대쾲 ???대?吏 ?앹꽦",
}

ACTIVE_ACCOUNT_STATUSES = {"active", "trialing", "paid", "ok"}

def _check_data_dir_writable(data_dir) -> bool:
    try:
        data_dir.mkdir(parents=True, exist_ok=True)
        probe_path = data_dir / ".blog_automation_write_probe"
        probe_path.write_text("ok", encoding="utf-8")
        probe_path.unlink(missing_ok=True)
        return True
    except Exception:
        return False


def require_authorized_user(request: Request, settings: ServerSettings = Depends(get_server_settings)) -> dict:
    return verify_token(request, _store, settings.api_auth_token)


def _admin_token(settings: ServerSettings) -> str:
    return settings.admin_api_token or settings.api_auth_token


def require_admin_request(request: Request, settings: ServerSettings = Depends(get_server_settings)) -> str:
    return require_admin_token(request, _admin_token(settings))


def require_billing_webhook(request: Request, settings: ServerSettings = Depends(get_server_settings)) -> str:
    expected = str(settings.billing_webhook_token or "").strip()
    if not expected:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="결제 동기화 토큰이 서버에 설정되지 않았습니다.")

    incoming = str(request.headers.get("X-Billing-Token", "") or "").strip()
    if incoming != expected:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="결제 동기화 토큰이 올바르지 않습니다.")
    return incoming


def _serialize_account(account: dict, settings: ServerSettings) -> dict:
    plan_limits = _store.get_plan_limits(account)
    current_usage = _usage_store.build_current_month_usage(username=account["username"])
    return {
        "username": account["username"],
        "plan_name": account.get("plan_name", settings.default_plan),
        "seats": int(account.get("seats", 1)),
        "expires_at": account.get("expires_at"),
        "status": account.get("status", "active"),
        "notes": account.get("notes"),
        "billing_provider": account.get("billing_provider"),
        "billing_customer_id": account.get("billing_customer_id"),
        "billing_subscription_id": account.get("billing_subscription_id"),
        "plan_limits": plan_limits,
        "current_month_usage": current_usage,
    }


def _serialize_account_snapshot(account: dict | None, settings: ServerSettings) -> dict | None:
    if not account:
        return None
    return _serialize_account(account, settings)


def _serialize_billing_issue_account(account: dict, settings: ServerSettings) -> dict:
    item = _serialize_account(account, settings)
    item["days_until_expiry"] = account.get("days_until_expiry")
    item["billing_issues"] = list(account.get("billing_issues") or [])
    return item


def _days_until_expiry(expires_at: str | None) -> int | None:
    text = str(expires_at or "").strip()
    if not text:
        return None
    try:
        expiry = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    now = datetime.now(timezone.utc)
    delta = expiry - now
    if delta.total_seconds() <= 0:
        return 0
    return max(delta.days, 0)


def _build_remaining_usage(account: dict) -> dict[str, int | None]:
    limits = _store.get_plan_limits(account)
    current_usage = _usage_store.build_current_month_usage(username=account["username"])
    remaining: dict[str, int | None] = {}
    for metric_key, limit_value in limits.items():
        limit = int(limit_value or 0)
        if limit <= 0:
            remaining[metric_key] = None
            continue
        used = int(current_usage.get(metric_key, 0) or 0)
        remaining[metric_key] = max(limit - used, 0)
    return remaining


def _ensure_usage_available(account: dict, metric_key: str) -> None:
    allowed, message = _store.evaluate_account_access(account)
    if not allowed:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=message)

    plan_limits = _store.get_plan_limits(account)
    limit = int(plan_limits.get(metric_key, 0) or 0)
    if limit <= 0:
        return

    current_usage = _usage_store.build_current_month_usage(username=account["username"])
    used = int(current_usage.get(metric_key, 0) or 0)
    if used >= limit:
        label = LIMIT_LABELS.get(metric_key, metric_key)
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=f"{label} ?쒕룄瑜?紐⑤몢 ?ъ슜?덉뒿?덈떎. 愿由ъ옄?먭쾶 ?뚮옖 ?낃렇?덉씠?쒕? ?붿껌??二쇱꽭??",
        )


def _record_server_usage(username: str, event_type: str, stage: str) -> None:
    _usage_store.append_event(
        username=username,
        event_type=event_type,
        stage=stage,
        status="success",
        details={"source": "server"},
    )


@app.get("/health")
def health() -> dict:
    return {"ok": True, "service": "blog_automation_server"}


@app.get("/plans", response_model=PlanListResponse)
def plans(settings: ServerSettings = Depends(get_server_settings)) -> PlanListResponse:
    plans = [
        {"plan_name": plan_name, "limits": limits}
        for plan_name, limits in sorted(settings.plan_limits.items(), key=lambda item: item[0])
    ]
    return PlanListResponse(plans=plans)


@app.get("/admin/config/status")
def admin_config_status(
    _admin: str = Depends(require_admin_request),
    settings: ServerSettings = Depends(get_server_settings),
) -> dict:
    data_dir = settings.data_dir
    return {
        "ok": True,
        "environment": settings.environment,
        "app_base_url_configured": bool(settings.app_base_url),
        "app_base_url": settings.app_base_url,
        "data_dir": str(data_dir),
        "data_dir_exists": data_dir.exists(),
        "data_dir_writable": _check_data_dir_writable(data_dir),
        "openai_api_key_configured": bool(settings.openai_api_key),
        "api_auth_token_configured": bool(settings.api_auth_token),
        "admin_api_token_configured": bool(_admin_token(settings)),
        "admin_api_token_uses_api_auth_fallback": bool(not settings.admin_api_token and settings.api_auth_token),
        "billing_webhook_token_configured": bool(settings.billing_webhook_token),
        "demo_username_configured": bool(settings.demo_username),
        "demo_password_configured": bool(settings.demo_password),
        "demo_password_uses_default": settings.demo_password == "change-this-password",
        "default_plan": settings.default_plan,
        "plan_count": len(settings.plan_limits),
        "plan_limits": settings.plan_limits,
        "allow_origins": settings.allow_origins,
    }


@app.post("/auth/login", response_model=LoginResponse)
def login(payload: LoginRequest, settings: ServerSettings = Depends(get_server_settings)) -> LoginResponse:
    account = authenticate_user(_store, payload.username, payload.password)
    if account is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="?꾩씠???먮뒗 鍮꾨?踰덊샇媛 ?щ컮瑜댁? ?딆뒿?덈떎.")

    allowed, message = _store.evaluate_account_access(account)
    if not allowed:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=message)

    token = _store.generate_access_token(account["username"])
    return LoginResponse(access_token=token, account=_serialize_account(account, settings))


@app.get("/auth/me")
def auth_me(
    user: dict = Depends(require_authorized_user),
    settings: ServerSettings = Depends(get_server_settings),
) -> dict:
    return {
        "ok": True,
        "message": "로그인 상태를 확인했습니다.",
        "account": _serialize_account(user, settings),
    }


@app.get("/subscription/me", response_model=SubscriptionStatusResponse)
def subscription_me(
    user: dict = Depends(require_authorized_user),
    settings: ServerSettings = Depends(get_server_settings),
) -> SubscriptionStatusResponse:
    allowed, message = _store.evaluate_account_access(user)
    serialized = _serialize_account(user, settings)
    expires_at = user.get("expires_at")
    remaining_usage = _build_remaining_usage(user)
    days_until_expiry = _days_until_expiry(expires_at)
    return SubscriptionStatusResponse(
        ok=allowed,
        message=message,
        account=serialized,
        remaining_usage=remaining_usage,
        is_expired=(not allowed and "만료" in str(message)),
        days_until_expiry=days_until_expiry,
    )


@app.post("/auth/logout", response_model=LogoutResponse)
def auth_logout(request: Request, settings: ServerSettings = Depends(get_server_settings)) -> LogoutResponse:
    token = get_bearer_token(request)
    admin_tokens = {value for value in (settings.admin_api_token, settings.api_auth_token) if value}
    if token in admin_tokens:
        return LogoutResponse(message="관리자 토큰은 서버에서 별도로 관리됩니다.")

    _store.revoke_access_token(token)
    return LogoutResponse(message="로그아웃이 완료되었습니다.")


@app.get("/admin/accounts", response_model=AccountListResponse)
def admin_accounts(
    _admin: str = Depends(require_admin_request),
    settings: ServerSettings = Depends(get_server_settings),
) -> AccountListResponse:
    accounts = [_serialize_account(account, settings) for account in _store.list_accounts()]
    return AccountListResponse(accounts=accounts)


@app.get("/admin/accounts/billing", response_model=AccountListResponse)
def admin_accounts_billing(
    provider: str | None = Query(default=None),
    linked_only: bool = Query(default=True),
    _admin: str = Depends(require_admin_request),
    settings: ServerSettings = Depends(get_server_settings),
) -> AccountListResponse:
    accounts = [
        _serialize_account(account, settings)
        for account in _store.list_billing_accounts(provider=provider, linked_only=linked_only)
    ]
    return AccountListResponse(accounts=accounts)


@app.get("/admin/accounts/billing-issues", response_model=BillingIssueAccountListResponse)
def admin_accounts_billing_issues(
    provider: str | None = Query(default=None),
    linked_only: bool = Query(default=True),
    within_days: int = Query(default=7, ge=0, le=365),
    _admin: str = Depends(require_admin_request),
    settings: ServerSettings = Depends(get_server_settings),
) -> BillingIssueAccountListResponse:
    accounts = [
        _serialize_billing_issue_account(account, settings)
        for account in _store.list_billing_issue_accounts(
            provider=provider,
            linked_only=linked_only,
            soon_days=within_days,
        )
    ]
    return BillingIssueAccountListResponse(accounts=accounts)


@app.get("/admin/accounts/billing-issues/summary", response_model=BillingIssueSummaryResponse)
def admin_accounts_billing_issue_summary(
    provider: str | None = Query(default=None),
    linked_only: bool = Query(default=True),
    within_days: int = Query(default=7, ge=0, le=365),
    _admin: str = Depends(require_admin_request),
    settings: ServerSettings = Depends(get_server_settings),
) -> BillingIssueSummaryResponse:
    summary = _store.build_billing_issue_summary(
        provider=provider,
        linked_only=linked_only,
        soon_days=within_days,
    )
    return BillingIssueSummaryResponse(**summary)


@app.get("/admin/accounts/overview", response_model=AccountOverviewResponse)
def admin_accounts_overview(
    _admin: str = Depends(require_admin_request),
    settings: ServerSettings = Depends(get_server_settings),
) -> AccountOverviewResponse:
    overview_map = _usage_store.build_account_overview()
    accounts = []
    for account in _store.list_accounts():
        usage = overview_map.get(account["username"], {})
        item = _serialize_account(account, settings)
        item.update(
            {
                "total_events": int(usage.get("total_events", 0)),
                "last_event_at": usage.get("last_event_at", ""),
                "last_event_type": usage.get("last_event_type", ""),
                "last_stage": usage.get("last_stage", ""),
                "last_status": usage.get("last_status", ""),
                "by_event_type": usage.get("by_event_type", {}),
                "by_status": usage.get("by_status", {}),
            }
        )
        accounts.append(item)
    return AccountOverviewResponse(accounts=accounts)


@app.get("/admin/accounts/expiring-soon", response_model=ExpiringAccountListResponse)
def admin_accounts_expiring_soon(
    days: int = Query(default=7, ge=1, le=365),
    _admin: str = Depends(require_admin_request),
    settings: ServerSettings = Depends(get_server_settings),
) -> ExpiringAccountListResponse:
    accounts = []
    for account in _store.list_expiring_accounts(days):
        item = _serialize_account(account, settings)
        item["days_until_expiry"] = _days_until_expiry(account.get("expires_at"))
        accounts.append(item)
    return ExpiringAccountListResponse(accounts=accounts)


@app.post("/admin/accounts/enforce-expiry", response_model=AccountExpiryEnforceResponse)
def admin_accounts_enforce_expiry(
    expired_status: str = Query(default="expired"),
    _admin: str = Depends(require_admin_request),
    settings: ServerSettings = Depends(get_server_settings),
) -> AccountExpiryEnforceResponse:
    updated_accounts = _store.enforce_expired_accounts(expired_status=expired_status)
    for account in updated_accounts:
        username = str(account.get("username") or "").strip()
        if username:
            _store.revoke_tokens_for_username(username)
    serialized = [_serialize_account(account, settings) for account in updated_accounts]
    return AccountExpiryEnforceResponse(
        updated_count=len(serialized),
        message=f"만료 계정 {len(serialized)}개를 정리했습니다.",
        accounts=serialized,
    )


@app.post("/admin/accounts")
def admin_account_create(
    payload: AccountCreateRequest,
    admin: str = Depends(require_admin_request),
    settings: ServerSettings = Depends(get_server_settings),
) -> dict:
    before = _serialize_account_snapshot(_store.find_user(payload.username), settings)
    account = _store.upsert_account(
        username=payload.username,
        password=payload.password,
        plan_name=payload.plan_name,
        seats=payload.seats,
        expires_at=payload.expires_at,
        status=payload.status,
        notes=payload.notes,
    )
    _store.revoke_tokens_for_username(payload.username)
    after = _serialize_account_snapshot(account, settings)
    _history_store.append_event(
        username=payload.username,
        change_type="account_create",
        actor=admin,
        before=before,
        after=after,
        details={"message": "account created or updated"},
    )
    return {
        "ok": True,
        "message": "怨꾩젙????ν뻽?듬땲??",
        "account": _serialize_account(account, settings),
    }


@app.post("/admin/accounts/{username}/status")
def admin_account_status(
    username: str,
    payload: AccountStatusUpdateRequest,
    admin: str = Depends(require_admin_request),
    settings: ServerSettings = Depends(get_server_settings),
) -> dict:
    before = _serialize_account_snapshot(_store.find_user(username), settings)
    account = _store.set_account_status(username, payload.status)
    if account is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="怨꾩젙??李얠쓣 ???놁뒿?덈떎.")

    if payload.status not in {"active", "trialing", "paid", "ok"}:
        _store.revoke_tokens_for_username(username)
    after = _serialize_account_snapshot(account, settings)
    _history_store.append_event(
        username=username,
        change_type="status_update",
        actor=admin,
        before=before,
        after=after,
        details={"requested_status": payload.status},
    )

    return {
        "ok": True,
        "message": "怨꾩젙 ?곹깭瑜?蹂寃쏀뻽?듬땲??",
        "account": _serialize_account(account, settings),
    }


@app.post("/admin/accounts/{username}/subscription")
def admin_account_subscription(
    username: str,
    payload: AccountSubscriptionUpdateRequest,
    admin: str = Depends(require_admin_request),
    settings: ServerSettings = Depends(get_server_settings),
) -> dict:
    before = _serialize_account_snapshot(_store.find_user(username), settings)
    account = _store.update_account_subscription(
        username,
        plan_name=payload.plan_name,
        seats=payload.seats,
        expires_at=payload.expires_at,
        status=payload.status,
        notes=payload.notes,
    )
    if account is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="怨꾩젙??李얠쓣 ???놁뒿?덈떎.")

    if payload.status is not None and payload.status not in {"active", "trialing", "paid", "ok"}:
        _store.revoke_tokens_for_username(username)
    after = _serialize_account_snapshot(account, settings)
    _history_store.append_event(
        username=username,
        change_type="subscription_update",
        actor=admin,
        before=before,
        after=after,
        details={
            "plan_name": payload.plan_name,
            "seats": payload.seats,
            "expires_at": payload.expires_at,
            "status": payload.status,
            "notes": payload.notes,
        },
    )

    return {
        "ok": True,
        "message": "援щ룆 ?뺣낫瑜?蹂寃쏀뻽?듬땲??",
        "account": _serialize_account(account, settings),
    }


@app.post("/admin/accounts/{username}/billing")
def admin_account_billing(
    username: str,
    payload: AccountBillingUpdateRequest,
    admin: str = Depends(require_admin_request),
    settings: ServerSettings = Depends(get_server_settings),
) -> dict:
    field_set = getattr(payload, "model_fields_set", getattr(payload, "__fields_set__", set()))
    before = _serialize_account_snapshot(_store.find_user(username), settings)
    kwargs: dict[str, str | None] = {}
    if "billing_provider" in field_set:
        kwargs["billing_provider"] = payload.billing_provider
    if "billing_customer_id" in field_set:
        kwargs["billing_customer_id"] = payload.billing_customer_id
    if "billing_subscription_id" in field_set:
        kwargs["billing_subscription_id"] = payload.billing_subscription_id

    account = _store.update_account_billing(username, **kwargs)
    if account is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="怨꾩젙??李얠쓣 ???놁뒿?덈떎.")
    after = _serialize_account_snapshot(account, settings)
    _history_store.append_event(
        username=username,
        change_type="billing_update",
        actor=admin,
        before=before,
        after=after,
        details={
            "billing_provider": payload.billing_provider,
            "billing_customer_id": payload.billing_customer_id,
            "billing_subscription_id": payload.billing_subscription_id,
        },
    )

    return {
        "ok": True,
        "message": "寃곗젣 ?곕룞 ?뺣낫瑜?蹂寃쏀뻽?듬땲??",
        "account": _serialize_account(account, settings),
    }


@app.post("/billing/sync")
def billing_sync(
    payload: BillingSyncRequest,
    _token: str = Depends(require_billing_webhook),
    settings: ServerSettings = Depends(get_server_settings),
) -> dict:
    before_account = _store.find_user(payload.username)
    if before_account is None:
        raise HTTPException(status_code=404, detail="계정을 찾을 수 없습니다.")
    before = _serialize_account_snapshot(before_account, settings)

    account = _store.update_account_subscription(
        payload.username,
        plan_name=payload.plan_name,
        seats=payload.seats,
        expires_at=payload.expires_at,
        status=payload.status,
        notes=payload.notes,
    )
    if account is None:
        raise HTTPException(status_code=404, detail="계정을 찾을 수 없습니다.")

    field_set = getattr(payload, "model_fields_set", getattr(payload, "__fields_set__", set()))
    billing_kwargs = {}
    if "billing_provider" in field_set:
        billing_kwargs["billing_provider"] = payload.billing_provider
    if "billing_customer_id" in field_set:
        billing_kwargs["billing_customer_id"] = payload.billing_customer_id
    if "billing_subscription_id" in field_set:
        billing_kwargs["billing_subscription_id"] = payload.billing_subscription_id
    if billing_kwargs:
        account = _store.update_account_billing(payload.username, **billing_kwargs) or account

    status_value = str(payload.status or "").strip().lower()
    if status_value and status_value not in ACTIVE_ACCOUNT_STATUSES:
        _store.revoke_tokens_for_username(payload.username)

    after = _serialize_account_snapshot(account, settings)
    _history_store.append_event(
        username=payload.username,
        change_type="billing_sync",
        actor=payload.source,
        before=before,
        after=after,
        details={
            "event_type": payload.event_type,
            "source": payload.source,
            "plan_name": payload.plan_name,
            "seats": payload.seats,
            "expires_at": payload.expires_at,
            "status": payload.status,
            "notes": payload.notes,
            "billing_provider": payload.billing_provider,
            "billing_customer_id": payload.billing_customer_id,
            "billing_subscription_id": payload.billing_subscription_id,
        },
    )

    return {
        "ok": True,
        "message": "결제 동기화가 반영되었습니다.",
        "account": _serialize_account(account, settings),
    }


@app.post("/admin/accounts/{username}/reset-password")
def admin_account_reset_password(
    username: str,
    payload: AccountPasswordResetRequest,
    admin: str = Depends(require_admin_request),
    settings: ServerSettings = Depends(get_server_settings),
) -> dict:
    account = _store.find_user(username)
    if account is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="怨꾩젙??李얠쓣 ???놁뒿?덈떎.")
    before = _serialize_account_snapshot(account, settings)

    updated = _store.upsert_account(
        username=account["username"],
        password=payload.password,
        plan_name=account.get("plan_name", "starter"),
        seats=int(account.get("seats", 1)),
        expires_at=account.get("expires_at"),
        status=account.get("status", "active"),
        notes=account.get("notes"),
        billing_provider=account.get("billing_provider"),
        billing_customer_id=account.get("billing_customer_id"),
        billing_subscription_id=account.get("billing_subscription_id"),
    )
    _store.revoke_tokens_for_username(username)
    after = _serialize_account_snapshot(updated, settings)
    _history_store.append_event(
        username=username,
        change_type="password_reset",
        actor=admin,
        before=before,
        after=after,
        details={"password_reset": True},
    )
    return {
        "ok": True,
        "message": "鍮꾨?踰덊샇瑜??ъ꽕?뺥뻽?듬땲??",
        "account": _serialize_account(updated, settings),
    }


@app.get("/admin/accounts/{username}/history", response_model=AccountHistoryListResponse)
def admin_account_history(
    username: str,
    limit: int = Query(default=20, ge=1, le=500),
    change_type: str | None = Query(default=None),
    _admin: str = Depends(require_admin_request),
) -> AccountHistoryListResponse:
    items = _history_store.list_events(username=username, change_type=change_type, limit=limit)
    return AccountHistoryListResponse(items=items)


@app.post("/license/status", response_model=LicenseResponse)
def license_status(payload: LicenseRequest, settings: ServerSettings = Depends(get_server_settings)) -> LicenseResponse:
    account = _store.find_user(payload.username)
    if account is None:
        return LicenseResponse(ok=False, message="?깅줉?섏? ?딆? 怨꾩젙?낅땲??")

    allowed, message = _store.evaluate_account_access(account)
    if not allowed:
        return LicenseResponse(ok=False, message=message)

    return LicenseResponse(ok=True, message=message, account=_serialize_account(account, settings))


@app.post("/usage/events")
def usage_event(payload: UsageEventRequest, user: dict = Depends(require_authorized_user)) -> dict:
    event = _usage_store.append_event(
        username=user["username"],
        event_type=payload.event_type,
        stage=payload.stage,
        status=payload.status,
        details=payload.details,
    )
    return {"ok": True, "message": "usage event recorded", "event": event}


@app.get("/admin/usage/events", response_model=UsageEventListResponse)
def admin_usage_events(
    username: str | None = Query(default=None),
    event_type: str | None = Query(default=None),
    stage: str | None = Query(default=None),
    status_filter: str | None = Query(default=None, alias="status"),
    limit: int = Query(default=100, ge=1, le=1000),
    _admin: str = Depends(require_admin_request),
) -> UsageEventListResponse:
    events = _usage_store.list_events(
        username=username,
        event_type=event_type,
        stage=stage,
        status=status_filter,
        limit=limit,
    )
    return UsageEventListResponse(events=events)


@app.get("/admin/usage/summary", response_model=UsageSummaryResponse)
def admin_usage_summary(
    username: str | None = Query(default=None),
    _admin: str = Depends(require_admin_request),
) -> UsageSummaryResponse:
    summary = _usage_store.build_summary(username=username)
    return UsageSummaryResponse(**summary)


@app.post("/research/generate")
def research_generate(payload: ResearchGenerateRequest, user: dict = Depends(require_authorized_user)) -> dict:
    result = generation_service.generate_research(payload.request, payload.prompt)
    return {"ok": True, "message": "research generated", "research_result": result}


@app.post("/titles/generate")
def titles_generate(payload: TitleGenerateRequest, user: dict = Depends(require_authorized_user)) -> dict:
    result = generation_service.generate_titles(payload.request, payload.research, payload.prompt)
    return {"ok": True, "message": "title options generated", "title_options_result": result}


@app.post("/draft/generate")
def draft_generate(payload: DraftGenerateRequest, user: dict = Depends(require_authorized_user)) -> dict:
    _ensure_usage_available(user, "monthly_drafts")
    result = generation_service.generate_draft(
        payload.request,
        payload.research,
        payload.prompt,
        payload.minimum_body_length,
        payload.target_body_length,
        payload.max_attempts,
    )
    _record_server_usage(user["username"], "draft_generated", "draft_generation")
    return {"ok": True, "message": "draft generated", "draft_result": result}


@app.post("/draft/generate-from-manual")
def draft_generate_from_manual(payload: ManualDraftGenerateRequest, user: dict = Depends(require_authorized_user)) -> dict:
    _ensure_usage_available(user, "monthly_drafts")
    result = generation_service.generate_draft_from_manual(payload.request, payload.prompt)
    _record_server_usage(user["username"], "draft_generated", "draft_generation_manual")
    return {"ok": True, "message": "manual draft generated", "draft_result": result}


@app.post("/draft/generate-from-images")
def draft_generate_from_images(payload: ImageDraftGenerateRequest, user: dict = Depends(require_authorized_user)) -> dict:
    _ensure_usage_available(user, "monthly_drafts")
    result = generation_service.generate_draft_from_images(
        payload.request,
        payload.research,
        payload.image_paths,
        payload.prompt,
    )
    _record_server_usage(user["username"], "draft_generated", "draft_generation_images")
    return {"ok": True, "message": "image draft generated", "draft_result": result}


@app.post("/draft/revise")
def draft_revise(payload: DraftReviseRequest, user: dict = Depends(require_authorized_user)) -> dict:
    result = generation_service.revise_draft(payload.action, payload.current_result, payload.instruction)
    return {"ok": True, "message": "draft revised", "revised_result": result}


@app.post("/images/generate", response_model=ImageGenerateResponse)
def images_generate(payload: ImageGenerateRequest, user: dict = Depends(require_authorized_user)) -> ImageGenerateResponse:
    _ensure_usage_available(user, "monthly_images")
    image_base64 = generation_service.generate_image(
        payload.prompt,
        payload.model,
        payload.quality,
        payload.reference_image_path,
    )
    _record_server_usage(user["username"], "image_generated", "image_generation")
    return ImageGenerateResponse(image_base64=image_base64)



