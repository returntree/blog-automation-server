from __future__ import annotations

from fastapi import HTTPException, Request, status

from .account_store import AccountStore


def get_bearer_token(request: Request) -> str:
    authorization = request.headers.get("Authorization", "")
    scheme, _, token = authorization.partition(" ")
    token = token.strip()
    if scheme.lower() != "bearer" or not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="접속 토큰이 필요합니다.")
    return token


def verify_token(request: Request, store: AccountStore, fallback_token: str | None) -> dict:
    token = get_bearer_token(request)

    if fallback_token and token == fallback_token:
        return {
            "username": "server-admin",
            "plan_name": "internal",
            "status": "active",
            "seats": 999,
        }

    username = store.find_username_by_token(token)
    if username is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="유효하지 않은 토큰입니다.")

    account = store.find_user(username)
    if account is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="계정을 찾을 수 없습니다.")

    allowed, message = store.evaluate_account_access(account)
    if not allowed:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=message)

    return account


def authenticate_user(store: AccountStore, username: str, password: str) -> dict | None:
    account = store.find_user(username)
    if account is None:
        return None
    if not store.verify_password(account, password):
        return None
    return account


def require_admin_token(request: Request, fallback_token: str | None) -> str:
    token = get_bearer_token(request)
    if not fallback_token or token != fallback_token:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="관리자 토큰이 필요합니다.")
    return token
