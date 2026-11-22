-- Idempotent migration (safe to re-run on every deploy).

CREATE TABLE IF NOT EXISTS deals (
  id           uuid        PRIMARY KEY,
  owner        text        NOT NULL,
  idem_key     text        NOT NULL,
  request_hash text        NOT NULL,
  pair         char(6)     NOT NULL,
  side         text        NOT NULL CHECK (side IN ('BUY','SELL')),
  notional     bigint      NOT NULL CHECK (notional BETWEEN 1000 AND 10000000),
  price        numeric(18,6) NOT NULL CHECK (price > 0),
  quote_id     uuid        NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT deals_owner_idem_key UNIQUE (owner, idem_key),
  CONSTRAINT deals_quote_id_key   UNIQUE (quote_id)
);
CREATE INDEX IF NOT EXISTS deals_owner_created ON deals (owner, created_at DESC);

-- Application role: IAM authentication only, least privilege, append-only ledger.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'soge_app') THEN
    CREATE ROLE soge_app LOGIN;
  END IF;
END $$;
GRANT rds_iam TO soge_app;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM soge_app;
GRANT USAGE ON SCHEMA public TO soge_app;
GRANT SELECT, INSERT ON deals TO soge_app;   -- no UPDATE / DELETE
ALTER ROLE soge_app SET statement_timeout = '3s';
ALTER ROLE soge_app SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE soge_app CONNECTION LIMIT 400;
