# blog_automation v9 서버 배포 가이드

이 폴더는 클라이언트용 `blog_automation_v9` 프로그램이 호출하는 서버 API입니다.  
최종 권장 구조는 `GitHub + Render + Persistent Disk` 이고, 이후 확장 시 `Postgres` 로 옮기는 흐름을 기준으로 정리했습니다.

## 현재 포함 기능
- 계정 로그인 / 로그아웃 / 상태 확인
- 공개 플랜 조회
- 내 구독 상태 조회
- 관리자 계정 생성 / 조회 / 상태 변경
- 관리자 비밀번호 재설정
- 관리자 구독 변경 / 만료 연장 / 플랜 업그레이드
- 결제 연동 정보 저장
- 사용 이벤트 기록 / 사용량 요약 / 변경 이력 조회
- 리서치 / 제목 후보 / 초안 / 수정 / 이미지 생성 API
- 플랜별 월간 초안 / 이미지 제한 적용

## 권장 배포 구조
- `GitHub`: 서버 코드 저장소
- `Render Web Service`: FastAPI 서버 실행
- `Render Persistent Disk`: JSON 데이터 저장
- 이후 확장:
  - `Postgres`: 계정/구독/사용량 데이터 이관
  - 결제 연동: Stripe 등

## 빠른 로컬 실행
```powershell
cd server
.\bootstrap_server.ps1
.\start_server.ps1
```

## 수동 로컬 실행
```powershell
cd server
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

## 배포 전 점검
```powershell
cd server
python .\check_server_readiness.py
```

이 스크립트는 아래 항목을 점검합니다.
- 필수 배포 파일 존재 여부
- `.env` 준비 여부
- `APP_ENV`, `OPENAI_API_KEY`, `API_AUTH_TOKEN`, `DEMO_PASSWORD` 상태
- `PLAN_LIMITS_JSON` 형식
- `render.yaml` 의 Persistent Disk 경로 설정
- `.python-version` 준비 여부

## 서버 전용 배포 폴더 만들기
```powershell
cd server
.\prepare_server_repo.ps1
```

기본값으로 `server\publish_ready_server` 폴더가 생성됩니다.  
이 폴더에는 서버 배포에 필요한 파일만 포함되며, 실제 `.env` 와 실사용 데이터는 포함하지 않습니다.

GitHub 업로드용 안내 문구와 예시 데이터를 함께 준비하려면:

```powershell
cd server
.\prepare_github_repo.ps1
```

Git 저장소까지 바로 초기화하려면:

```powershell
cd server
.\prepare_github_repo.ps1 -InitGit
```

## Render 배포 순서
1. `server` 폴더 기준으로 GitHub 서버 전용 저장소를 준비합니다.
2. Render에서 `Blueprint` 또는 `Web Service` 를 생성합니다.
3. 루트 디렉터리를 `server` 또는 `publish_ready_server` 로 지정합니다.
4. `.env.example` 를 참고해서 Render 환경변수를 등록합니다.
5. `Persistent Disk` 를 연결하고 `DATA_DIR=/var/data/blog_automation` 로 맞춥니다.
6. 배포 후 `/health` 응답을 먼저 확인합니다.

## render.yaml 사용 안내
이 폴더에는 `render.yaml` 예시가 포함되어 있습니다.  
Render에서 Blueprint 배포를 열면 Web Service와 Disk 설정을 함께 가져갈 수 있습니다.

## Python 버전 고정
`.python-version` 파일로 배포 Python 버전을 고정합니다.  
현재 기본값은 `3.11.9` 입니다.

## 필수 환경 변수
- `APP_ENV`
  - `development` 또는 `production`
- `APP_BASE_URL`
  - 서버 실제 접속 주소
  - 예: `https://your-app.onrender.com`
- `SERVER_HOST`
  - 기본값 `0.0.0.0`
- `SERVER_PORT`
  - 로컬 실행용 포트
- `PORT`
  - Render가 자동 주입하는 포트
- `DATA_DIR`
  - JSON 데이터 저장 폴더
- `API_AUTH_TOKEN`
  - 관리자 API 보호 토큰
- `OPENAI_API_KEY`
  - 서버가 사용하는 OpenAI API 키
- `BILLING_WEBHOOK_TOKEN`
  - 결제 웹훅 검증용
- `ALLOW_ORIGINS`
  - CORS 허용 값
- `DEFAULT_PLAN`
  - 신규 계정 기본 플랜
- `DEMO_USERNAME`
  - 초기 데모 계정 아이디
- `DEMO_PASSWORD`
  - 초기 데모 계정 비밀번호
- `PLAN_LIMITS_JSON`
  - 플랜별 월간 초안/이미지 제한

예시:
```json
{
  "starter": {"monthly_drafts": 30, "monthly_images": 300},
  "pro": {"monthly_drafts": 200, "monthly_images": 2000},
  "internal": {}
}
```

## 주요 엔드포인트
- `GET /health`
- `GET /plans`
- `POST /auth/login`
- `GET /auth/me`
- `GET /subscription/me`
- `POST /auth/logout`
- `GET /admin/accounts`
- `GET /admin/accounts/overview`
- `GET /admin/accounts/billing-linked`
- `GET /admin/accounts/billing-issues/summary`
- `POST /admin/accounts`
- `POST /admin/accounts/{username}/status`
- `POST /admin/accounts/{username}/subscription`
- `POST /admin/accounts/{username}/billing`
- `POST /admin/accounts/{username}/reset-password`
- `GET /admin/accounts/{username}/history`
- `POST /license/status`
- `POST /usage/events`
- `GET /admin/usage/events`
- `GET /admin/usage/summary`
- `POST /research/generate`
- `POST /titles/generate`
- `POST /draft/generate`
- `POST /draft/generate-from-manual`
- `POST /draft/generate-from-images`
- `POST /draft/revise`
- `POST /images/generate`
- `POST /images/regenerate`

## 관리자 스크립트
프로젝트 루트 `scripts` 폴더에서 아래 도구를 사용할 수 있습니다.
- `create_server_account.py`
- `list_server_plans.py`
- `client_subscription_status.py`
- `list_server_accounts.py`
- `set_server_account_status.py`
- `update_server_account_subscription.py`
- `reset_server_account_password.py`
- `report_usage_event.py`
- `list_usage_events.py`
- `get_usage_summary.py`
- `server_admin_console.py`

관리자용 환경 변수:
- `BLOG_AUTOMATION_SERVER_URL`
- `BLOG_AUTOMATION_ADMIN_TOKEN`

## 현재 단계에서 주의할 점
- 아직은 `JSON 파일 저장 방식` 입니다.
- 초기 배포/내부 테스트용으로는 괜찮지만, 사용자가 늘어나면 `Postgres` 이관이 필요합니다.
- Render 무료 환경만 쓰면 데이터가 사라질 수 있으므로 `Persistent Disk` 사용을 권장합니다.
- 실제 운영 전에는 `API_AUTH_TOKEN`, `DEMO_PASSWORD`, `OPENAI_API_KEY` 를 반드시 교체해야 합니다.

## 다음 추천 단계
1. GitHub 서버 전용 저장소 분리
2. Render 배포
3. Persistent Disk 연결
4. 클라이언트에서 서버 URL 연결
5. 이후 Postgres 이관
