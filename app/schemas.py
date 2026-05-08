from __future__ import annotations

from typing import Any

from pydantic import BaseModel, Field


class LicenseRequest(BaseModel):
    username: str
    device_id: str | None = None


class LoginRequest(BaseModel):
    username: str
    password: str


class AccountSummary(BaseModel):
    username: str
    plan_name: str
    seats: int
    expires_at: str | None = None
    status: str
    notes: str | None = None
    billing_provider: str | None = None
    billing_customer_id: str | None = None
    billing_subscription_id: str | None = None
    plan_limits: dict[str, int] = Field(default_factory=dict)
    current_month_usage: dict[str, int] = Field(default_factory=dict)


class LoginResponse(BaseModel):
    ok: bool = True
    access_token: str
    token_type: str = "bearer"
    account: AccountSummary


class LicenseResponse(BaseModel):
    ok: bool
    message: str
    account: AccountSummary | None = None


class LogoutResponse(BaseModel):
    ok: bool = True
    message: str = "로그아웃이 완료되었습니다."


class AccountStatusUpdateRequest(BaseModel):
    status: str


class AccountSubscriptionUpdateRequest(BaseModel):
    plan_name: str | None = None
    seats: int | None = None
    expires_at: str | None = None
    status: str | None = None
    notes: str | None = None


class AccountBillingUpdateRequest(BaseModel):
    billing_provider: str | None = None
    billing_customer_id: str | None = None
    billing_subscription_id: str | None = None


class BillingSyncRequest(BaseModel):
    username: str
    billing_provider: str | None = None
    billing_customer_id: str | None = None
    billing_subscription_id: str | None = None
    plan_name: str | None = None
    seats: int | None = None
    expires_at: str | None = None
    status: str | None = None
    notes: str | None = None
    event_type: str = "billing_sync"
    source: str = "billing_provider"


class AccountPasswordResetRequest(BaseModel):
    password: str


class AccountListResponse(BaseModel):
    ok: bool = True
    accounts: list[AccountSummary]


class BillingIssueAccountItem(AccountSummary):
    days_until_expiry: int | None = None
    billing_issues: list[str] = Field(default_factory=list)


class BillingIssueAccountListResponse(BaseModel):
    ok: bool = True
    accounts: list[BillingIssueAccountItem] = Field(default_factory=list)


class BillingIssueSummaryResponse(BaseModel):
    ok: bool = True
    total_accounts_checked: int = 0
    accounts_with_issues: int = 0
    linked_only: bool = True
    within_days: int = 7
    provider_filter: str | None = None
    by_issue_type: dict[str, int] = Field(default_factory=dict)
    by_provider: dict[str, int] = Field(default_factory=dict)


class AccountCreateRequest(BaseModel):
    username: str
    password: str
    plan_name: str = "starter"
    seats: int = 1
    expires_at: str | None = None
    status: str = "active"
    notes: str = ""


class AccountCreateResponse(BaseModel):
    ok: bool = True
    message: str
    account: AccountSummary


class UsageEventRequest(BaseModel):
    event_type: str
    stage: str = ""
    status: str = ""
    details: dict[str, Any] = Field(default_factory=dict)


class UsageEventResponse(BaseModel):
    ok: bool = True
    message: str = "사용 이벤트가 기록되었습니다."


class UsageEventItem(BaseModel):
    timestamp: str
    username: str
    event_type: str
    stage: str = ""
    status: str = ""
    details: dict[str, Any] = Field(default_factory=dict)


class UsageEventListResponse(BaseModel):
    ok: bool = True
    events: list[UsageEventItem]


class UsageSummaryResponse(BaseModel):
    ok: bool = True
    total_events: int = 0
    by_event_type: dict[str, int] = Field(default_factory=dict)
    by_status: dict[str, int] = Field(default_factory=dict)
    by_stage: dict[str, int] = Field(default_factory=dict)
    by_username: dict[str, int] = Field(default_factory=dict)


class AccountOverviewItem(AccountSummary):
    total_events: int = 0
    last_event_type: str = ""
    last_stage: str = ""
    last_status: str = ""
    last_event_at: str = ""
    by_event_type: dict[str, int] = Field(default_factory=dict)
    by_status: dict[str, int] = Field(default_factory=dict)


class AccountOverviewResponse(BaseModel):
    ok: bool = True
    accounts: list[AccountOverviewItem]


class AccountHistoryItem(BaseModel):
    timestamp: str
    username: str
    change_type: str
    actor: str = ""
    before: dict[str, Any] | None = None
    after: dict[str, Any] | None = None
    details: dict[str, Any] = Field(default_factory=dict)


class AccountHistoryListResponse(BaseModel):
    ok: bool = True
    items: list[AccountHistoryItem] = Field(default_factory=list)


class ExpiringAccountItem(AccountSummary):
    days_until_expiry: int | None = None


class ExpiringAccountListResponse(BaseModel):
    ok: bool = True
    accounts: list[ExpiringAccountItem] = Field(default_factory=list)


class AccountExpiryEnforceResponse(BaseModel):
    ok: bool = True
    updated_count: int = 0
    message: str = "만료 계정을 정리했습니다."
    accounts: list[AccountSummary] = Field(default_factory=list)


class ResearchGenerateRequest(BaseModel):
    request: dict[str, Any]
    prompt: str


class TitleGenerateRequest(BaseModel):
    request: dict[str, Any]
    research: dict[str, Any]
    prompt: str


class DraftGenerateRequest(BaseModel):
    request: dict[str, Any]
    research: dict[str, Any]
    prompt: str
    minimum_body_length: int = 2500
    target_body_length: int = 3200
    max_attempts: int = 2


class ManualDraftGenerateRequest(BaseModel):
    request: dict[str, Any]
    prompt: str


class ImageDraftGenerateRequest(BaseModel):
    request: dict[str, Any]
    research: dict[str, Any]
    image_paths: list[str] = Field(default_factory=list)
    prompt: str


class DraftReviseRequest(BaseModel):
    action: str
    current_result: dict[str, Any]
    instruction: str


class ImageGenerateRequest(BaseModel):
    prompt: str
    model: str
    quality: str
    reference_image_path: str | None = None


class ImageGenerateResponse(BaseModel):
    ok: bool = True
    message: str = "이미지가 생성되었습니다."
    image_base64: str


class PlanInfoItem(BaseModel):
    plan_name: str
    limits: dict[str, int] = Field(default_factory=dict)


class PlanListResponse(BaseModel):
    ok: bool = True
    plans: list[PlanInfoItem] = Field(default_factory=list)


class SubscriptionStatusResponse(BaseModel):
    ok: bool = True
    message: str = "구독 상태를 확인했습니다."
    account: AccountSummary
    remaining_usage: dict[str, int | None] = Field(default_factory=dict)
    is_expired: bool = False
    days_until_expiry: int | None = None
