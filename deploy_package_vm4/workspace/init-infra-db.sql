-- =============================================================================
-- infra-db 初始化腳本
-- 執行身分：POSTGRES_USER（segora_admin），執行時機：首次啟動容器
-- 每個服務擁有獨立的 user + database，互相隔離
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Keycloak  (VM5 keycloak 服務使用)
-- -----------------------------------------------------------------------------
CREATE USER kc_user WITH PASSWORD 'kc_pass';
CREATE DATABASE keycloak OWNER kc_user;
REVOKE CONNECT ON DATABASE keycloak FROM PUBLIC;
GRANT CONNECT ON DATABASE keycloak TO kc_user;
GRANT ALL PRIVILEGES ON DATABASE keycloak TO kc_user;

-- -----------------------------------------------------------------------------
-- 2. Dependency-Track  (VM3 dtrack 服務使用)
-- -----------------------------------------------------------------------------
CREATE USER dt_user WITH PASSWORD 'dt_pass';
CREATE DATABASE dtrack OWNER dt_user;
REVOKE CONNECT ON DATABASE dtrack FROM PUBLIC;
GRANT CONNECT ON DATABASE dtrack TO dt_user;
GRANT ALL PRIVILEGES ON DATABASE dtrack TO dt_user;

-- -----------------------------------------------------------------------------
-- 3. Superset  (VM5 superset 服務使用)
-- -----------------------------------------------------------------------------
CREATE USER superset_user WITH PASSWORD 'Superset_2026!';
CREATE DATABASE superset_db OWNER superset_user;
REVOKE CONNECT ON DATABASE superset_db FROM PUBLIC;
GRANT CONNECT ON DATABASE superset_db TO superset_user;
GRANT ALL PRIVILEGES ON DATABASE superset_db TO superset_user;

-- -----------------------------------------------------------------------------
-- 4. Keycloak Access Controller  (VM5 kc_access 服務使用)
--    資料表由應用程式啟動時自動建立，此處只需建立 DB + user
-- -----------------------------------------------------------------------------
CREATE USER keycloak_access_user WITH PASSWORD 'Keycloak_access_2026!';
CREATE DATABASE keycloak_access_db OWNER keycloak_access_user;
REVOKE CONNECT ON DATABASE keycloak_access_db FROM PUBLIC;
GRANT CONNECT ON DATABASE keycloak_access_db TO keycloak_access_user;
GRANT ALL PRIVILEGES ON DATABASE keycloak_access_db TO keycloak_access_user;
