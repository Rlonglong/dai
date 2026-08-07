import base64
import json
import logging

from superset.security import SupersetSecurityManager

logger = logging.getLogger(__name__)


class CustomSsoSecurityManager(SupersetSecurityManager):
    """
    Keycloak OIDC 對應：
    - userinfo endpoint  → username / email / name
    - JWT access_token   → realm_access.roles + resource_access.superset.roles
                           → Superset role_keys（搭配 AUTH_ROLES_MAPPING 使用）
    """

    @staticmethod
    def _decode_jwt_payload(token: str) -> dict:
        """不驗簽，僅解析 JWT payload 取 claims。"""
        try:
            payload_b64 = token.split(".")[1]
            # base64url 補 padding
            payload_b64 += "=" * (4 - len(payload_b64) % 4)
            return json.loads(base64.urlsafe_b64decode(payload_b64))
        except Exception as exc:
            logger.warning("JWT payload decode 失敗: %s", exc)
            return {}

    def oauth_user_info(self, provider: str, response=None):
        if provider != "keycloak":
            return super().oauth_user_info(provider, response)

        # 1. 取 userinfo（username / name / email）
        me = self.appbuilder.sm.oauth_remotes[provider].userinfo()
        logger.debug("Keycloak userinfo: %s", me)

        # 2. 解析 JWT access_token 取 roles
        #    response 即 token endpoint 回傳值，含 access_token
        access_token = (response or {}).get("access_token", "")
        role_keys: list = []

        if access_token:
            claims = self._decode_jwt_payload(access_token)
            logger.debug("JWT claims: %s", claims)

            # Realm-level roles（所有 client 共用）
            realm_roles: list = (
                claims.get("realm_access", {}).get("roles", [])
            )
            # Client-level roles（只屬於 "superset" 這個 client）
            client_roles: list = (
                claims.get("resource_access", {})
                      .get("superset", {})
                      .get("roles", [])
            )
            role_keys = realm_roles + client_roles
            logger.info("使用者 %s 的 role_keys: %s",
                        me.get("preferred_username"), role_keys)
        else:
            # fallback：access_token 取不到時，從 userinfo groups 欄位取
            role_keys = me.get("groups", [])
            logger.warning("access_token 為空，fallback 到 userinfo.groups: %s",
                           role_keys)

        return {
            "username":   me.get("preferred_username", ""),
            "first_name": me.get("given_name", ""),
            "last_name":  me.get("family_name", ""),
            "email":      me.get("email", ""),
            "role_keys":  role_keys,
        }
