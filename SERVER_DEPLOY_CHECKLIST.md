# blog_automation 서버 배포 체크리스트

이 폴더는 v9 클라이언트가 호출할 서버 API 배포용입니다. Render에 올린 뒤 아래 순서대로 확인하면 됩니다.

## 1. Render 환경변수

Render 서비스의 Environment에 아래 값을 넣습니다.

- APP_ENV=production
- APP_BASE_URL=https://blog-automation-server-yytc.onrender.com
- DATA_DIR=/var/data/blog_automation
- OPENAI_API_KEY=서버에서 사용할 OpenAI API 키
- API_AUTH_TOKEN=관리자 API 보호용 긴 임의 문자열
- DEMO_USERNAME=초기 로그인 아이디
- DEMO_PASSWORD=초기 로그인 비밀번호
- DEFAULT_PLAN=starter
- PLAN_LIMITS_JSON={"starter":{"monthly_drafts":30,"monthly_images":300},"pro":{"monthly_drafts":200,"monthly_images":2000},"internal":{}}

주의: DEMO_USERNAME/DEMO_PASSWORD는 accounts.json이 없을 때만 최초 계정 생성에 사용됩니다. 이미 Render Persistent Disk에 accounts.json이 있으면 환경변수를 바꿔도 기존 계정 비밀번호는 자동 변경되지 않습니다.

## 2. 배포 전 로컬 점검

```powershell
python check_server_readiness.py
```

오류가 0건이면 배포 가능한 상태입니다. 주의 항목은 운영 정책에 따라 확인하면 됩니다.

## 3. Render 환경변수 원격 점검

배포가 끝난 뒤 관리자 토큰으로 서버 환경변수가 제대로 들어갔는지 확인합니다. 이 명령은 비밀키 값을 출력하지 않고 설정 여부만 표시합니다.

```powershell
python scripts/server_config_status.py --server-base-url https://blog-automation-server-yytc.onrender.com --token "Render에 넣은 API_AUTH_TOKEN"
```

OPENAI_API_KEY, API_AUTH_TOKEN, DATA_DIR 쓰기 가능 여부가 모두 확인되어야 실제 생성 API가 안정적으로 동작합니다.

## 4. Render 배포 후 기본 API 점검

```powershell
python scripts/server_smoke_test.py --server-base-url https://blog-automation-server-yytc.onrender.com
```

로그인까지 확인하려면:

```powershell
python scripts/server_smoke_test.py --server-base-url https://blog-automation-server-yytc.onrender.com --username 계정아이디 --password 계정비밀번호
```

## 5. 클라이언트 연결 확인

클라이언트 PC에서는 아래 순서로 확인합니다.

```powershell
python scripts/client_login.py --server-base-url https://blog-automation-server-yytc.onrender.com --username 계정아이디 --password 계정비밀번호
python scripts/client_status.py
```

## 6. 자주 나는 문제

- Render 배포 실패: Logs에서 `ModuleNotFoundError`가 보이면 누락된 scripts 파일이 서버 repo에 포함됐는지 확인합니다.
- OpenAI 생성 실패: OPENAI_API_KEY가 비었거나 크레딧이 부족한 경우입니다.
- 로그인 실패: DEMO 계정은 최초 생성 시점의 값이 저장됩니다. 이미 계정 파일이 있으면 관리자 스크립트로 비밀번호를 재설정해야 합니다.
- 사용량 제한 실패: PLAN_LIMITS_JSON 형식이 JSON 객체인지 확인합니다.

