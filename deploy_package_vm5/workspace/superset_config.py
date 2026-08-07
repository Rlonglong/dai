import os
import sys

# custom_sso_security_manager.py is mounted at /app/ alongside this file
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from flask_appbuilder.security.manager import AUTH_OAUTH

# =============================================================================
# 資料庫連線（指向 VM4 infra-db）
# DB_HOST 由 docker-compose environment 注入（值為 VM4_IP）
# =============================================================================
DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("INFRA_DB_PORT", "5433")
DB_USER = os.environ.get("SUPERSET_DB_USER", "superset_user")
DB_PASS = os.environ.get("SUPERSET_DB_PASSWORD", "Superset_2026!")
DB_NAME = os.environ.get("SUPERSET_DB_NAME", "superset_db")

SQLALCHEMY_DATABASE_URI = (
    f"postgresql+psycopg2://{DB_USER}:{DB_PASS}@{DB_HOST}:{DB_PORT}/{DB_NAME}"
)

# =============================================================================
# 安全金鑰
# =============================================================================
SECRET_KEY = os.environ.get("SUPERSET_SECRET_KEY", "changeme")

# =============================================================================
# SSO：Keycloak OIDC (OAuth2)
# auth.daitest.post.gov.tw 透過 extra_hosts 在容器內解析到 VM5 本機 Nginx
# =============================================================================
AUTH_TYPE = AUTH_OAUTH
AUTH_USER_REGISTRATION = True
AUTH_USER_REGISTRATION_ROLE = "Gamma"

KEYCLOAK_BASE = "https://auth.dai.post.gov.tw/realms/postoffice/protocol/openid-connect"

OAUTH_PROVIDERS = [
    {
        "name": "keycloak",
        "icon": "fa-key",
        "token_key": "access_token",
        "remote_app": {
            "client_id": os.environ.get("SUPERSET_OIDC_CLIENT_NAME", "superset"),
            "client_secret": os.environ.get("SUPERSET_OIDC_CLIENT_SECRET", ""),
            "server_metadata_url": (
                "https://auth.dai.post.gov.tw/realms/postoffice"
                "/.well-known/openid-configuration"
            ),
            "client_kwargs": {
                "scope": "openid email profile",
                # 容器內 Keycloak 走自簽憑證，關閉 TLS 驗證
                "verify": False,
            },
            "request_token_url": None,
        },
    }
]

# =============================================================================
# 自訂 Security Manager（處理 Keycloak userinfo 欄位對應）
# =============================================================================
from custom_sso_security_manager import CustomSsoSecurityManager
CUSTOM_SECURITY_MANAGER = CustomSsoSecurityManager
# ── Role Mapping ──────────────────────────────────────────
# Key   = Keycloak 的 role 名稱（realm role 或 client role）
# Value = Superset 內建 role 清單
AUTH_ROLES_MAPPING = {
    "superset-admin": ["Admin"],
    "superset-alpha": ["Alpha"],
    "superset-gamma": ["Gamma"],
}

# 每次登入都重新同步 Keycloak role（避免 Keycloak 改了但 Superset 沒更新）
AUTH_ROLES_SYNC_AT_LOGIN = True

# SSO 首次登入自動建立使用者，無 role mapping 命中時給 Gamma（最小權限）
AUTH_USER_REGISTRATION = True
AUTH_USER_REGISTRATION_ROLE = "Gamma"

# =============================================================================
# 反向代理設定（讓 redirect_uri 產生 https:// 而非 http://）
# =============================================================================
ENABLE_PROXY_FIX = True
PROXY_FIX_CONFIG = {"x_for": 1, "x_proto": 1, "x_host": 1, "x_port": 1, "x_prefix": 1}

# =============================================================================
# 其他
# =============================================================================
WTF_CSRF_ENABLED = True
SESSION_COOKIE_SAMESITE = "Lax"
SESSION_COOKIE_SECURE = True
TALISMAN_ENABLED = False
