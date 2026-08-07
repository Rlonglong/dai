-- =============================================================================
-- VM4 infra-db 初始化：建立四個服務各自的資料庫與帳號
-- =============================================================================
-- 掛載位置：/docker-entrypoint-initdb.d/init.sql（見 docker-compose.yml）
--
-- ★ 這支 SQL 只在 PostgreSQL 的資料目錄是空的時候會被執行一次。★
--   第一次啟動失敗、或改了這支 SQL 要重跑，都必須先把資料清掉：
--       docker compose down
--       docker volume rm <專案名>_infra-db-data
--       docker compose up -d infra-db
--
-- ★ 下面的密碼必須跟各 VM 的 .env 一致 ★
--   dtrack   → VM3 .env 的 DTRACK_DB_USER / DTRACK_DB_PASSWORD
--   keycloak → VM5 .env 的 KEYCLOAK_DB_USER / KEYCLOAK_DB_PASSWORD
--   superset → VM5 .env 的 SUPERSET_DB_USER / SUPERSET_DB_PASSWORD
--   改密碼時兩邊都要改，否則服務會連不上資料庫。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Keycloak（VM5）
-- ---------------------------------------------------------------------------
CREATE ROLE keycloak_user WITH LOGIN PASSWORD 'ChangeMe_Keycloak_2026';
CREATE DATABASE keycloak OWNER keycloak_user;

-- ---------------------------------------------------------------------------
-- 2. kc_access（VM5，Keycloak 的存取控制附屬服務）
-- ---------------------------------------------------------------------------
CREATE DATABASE keycloak_access_db OWNER keycloak_user;

-- ---------------------------------------------------------------------------
-- 3. Dependency-Track（VM3）
-- ---------------------------------------------------------------------------
CREATE ROLE dtrack_user WITH LOGIN PASSWORD 'ChangeMe_Dtrack_2026';
CREATE DATABASE dtrack OWNER dtrack_user;

-- ---------------------------------------------------------------------------
-- 4. Superset（VM5）
-- ---------------------------------------------------------------------------
CREATE ROLE superset_user WITH LOGIN PASSWORD 'ChangeMe_Superset_2026';
CREATE DATABASE superset_db OWNER superset_user;

-- ---------------------------------------------------------------------------
-- 5. Dagster（VM4 本機，目前 dagster.yaml 用預設 SQLite，先建起來備用）
-- ---------------------------------------------------------------------------
CREATE ROLE dagster_user WITH LOGIN PASSWORD 'ChangeMe_Dagster_2026';
CREATE DATABASE dagster OWNER dagster_user;

-- ---------------------------------------------------------------------------
-- 6. 收掉 public schema 的預設權限（PostgreSQL 15+ 已預設收緊，這裡明確重申）
-- ---------------------------------------------------------------------------
REVOKE ALL ON SCHEMA public FROM PUBLIC;

\connect keycloak
GRANT ALL ON SCHEMA public TO keycloak_user;

\connect keycloak_access_db
GRANT ALL ON SCHEMA public TO keycloak_user;

\connect dtrack
GRANT ALL ON SCHEMA public TO dtrack_user;

\connect superset_db
GRANT ALL ON SCHEMA public TO superset_user;

\connect dagster
GRANT ALL ON SCHEMA public TO dagster_user;
