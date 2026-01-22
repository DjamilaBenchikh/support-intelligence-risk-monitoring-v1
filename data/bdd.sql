-- ============================================================
-- Support Intelligence & Risk Monitoring System (PostgreSQL)
-- Full relational schema (prod-like MVP)
-- ============================================================


-- 1) Customers (client)
CREATE TABLE customers (
  customer_id   TEXT PRIMARY KEY,           -- e.g., "cust_1029"
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  email         TEXT,
  full_name     TEXT,
  plan          TEXT,                       -- free/pro/enterprise
  country       TEXT,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE INDEX idx_customers_email ON customers(email);


-- 2) Tickets (source of truth)

CREATE TABLE tickets (
  ticket_id       BIGSERIAL PRIMARY KEY,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

  customer_id     TEXT REFERENCES customers(customer_id) ON DELETE SET NULL,

  channel         TEXT,                     -- email/chat/web
  subject         TEXT,
  body            TEXT NOT NULL,

  -- computed/normalized fields used by models + analytics
  message         TEXT NOT NULL,            -- subject+body fallback (store it)
  queue           TEXT,                     -- e.g., "Billing and Payments"
  type            TEXT,                     -- e.g., "Incident/Request/Problem/Change"
  tags_str        TEXT,                     -- e.g., "refund | double_charge"

  status          TEXT NOT NULL DEFAULT 'open'  -- open/ack/closed (simple)
);

CREATE INDEX idx_tickets_created_at ON tickets(created_at);
CREATE INDEX idx_tickets_customer_id ON tickets(customer_id);
CREATE INDEX idx_tickets_queue ON tickets(queue);
CREATE INDEX idx_tickets_type ON tickets(type);



-- 3) Predictions (model outputs per ticket)

CREATE TABLE predictions (
  prediction_id   BIGSERIAL PRIMARY KEY,
  ticket_id       BIGINT NOT NULL REFERENCES tickets(ticket_id) ON DELETE CASCADE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

  model_name      TEXT NOT NULL,            -- e.g., 't4_lr', 't5_distilbert'
  model_version   TEXT,
  policy          TEXT NOT NULL DEFAULT 'balanced',  -- balanced/safety
  threshold_high  DOUBLE PRECISION,         -- nullable for balanced

  pred_category   TEXT,                     -- Billing/Bug/Account/Other
  pred_priority   TEXT NOT NULL,            -- low/medium/high
  proba_high      DOUBLE PRECISION,         -- nullable if model doesn't output proba

  meta            JSONB                     -- debug/features (optional)
);

CREATE INDEX idx_predictions_ticket_id ON predictions(ticket_id);
CREATE INDEX idx_predictions_created_at ON predictions(created_at);
CREATE INDEX idx_predictions_pred_priority ON predictions(pred_priority);
CREATE INDEX idx_predictions_pred_category ON predictions(pred_category);


-- 4) Feedback (human corrections)

CREATE TABLE feedback (
  feedback_id     BIGSERIAL PRIMARY KEY,
  ticket_id       BIGINT NOT NULL REFERENCES tickets(ticket_id) ON DELETE CASCADE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

  user_category   TEXT,                     -- corrected category
  user_priority   TEXT,                     -- corrected priority
  comment         TEXT
);

CREATE INDEX idx_feedback_ticket_id ON feedback(ticket_id);



-- 5) Alerts (output of monitoring/anomaly detection)

CREATE TABLE alerts (
  alert_id        BIGSERIAL PRIMARY KEY,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

  alert_time      TIMESTAMPTZ NOT NULL,     -- time bucket where anomaly occurred
  alert_type      TEXT NOT NULL,            -- tickets_spike/high_rate_spike/queue_spike/tag_spike/...
  level           TEXT NOT NULL,            -- global | queue:<name> | tag:<name> | customer:<id>
  metric          TEXT NOT NULL,            -- tickets_total | high_rate | count | ...
  value           DOUBLE PRECISION NOT NULL,
  zscore          DOUBLE PRECISION,
  window          INTEGER NOT NULL DEFAULT 14,

  status          TEXT NOT NULL DEFAULT 'open',  -- open/ack/closed
  details         JSONB
);

CREATE INDEX idx_alerts_alert_time ON alerts(alert_time);
CREATE INDEX idx_alerts_status ON alerts(status);
CREATE INDEX idx_alerts_type_level ON alerts(alert_type, level);



-- 6) Auth events (login failures / resets)  [Risk signals]

CREATE TABLE auth_events (
  event_id        BIGSERIAL PRIMARY KEY,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

  customer_id     TEXT REFERENCES customers(customer_id) ON DELETE SET NULL,

  event_type      TEXT NOT NULL,            -- login_success/login_fail/password_reset/2fa_fail
  ip              TEXT,
  user_agent      TEXT,

  meta            JSONB
);

CREATE INDEX idx_auth_events_time ON auth_events(created_at);
CREATE INDEX idx_auth_events_customer ON auth_events(customer_id);
CREATE INDEX idx_auth_events_type ON auth_events(event_type);


-- 7) Billing events (refunds / chargebacks) [Risk signals]

CREATE TABLE billing_events (
  event_id        BIGSERIAL PRIMARY KEY,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

  customer_id     TEXT REFERENCES customers(customer_id) ON DELETE SET NULL,

  event_type      TEXT NOT NULL,            -- refund_requested/refund_issued/chargeback
  amount          DOUBLE PRECISION,
  currency        TEXT DEFAULT 'USD',

  meta            JSONB
);

CREATE INDEX idx_billing_events_time ON billing_events(created_at);
CREATE INDEX idx_billing_events_customer ON billing_events(customer_id);
CREATE INDEX idx_billing_events_type ON billing_events(event_type);



-- 8) Product / Server events (errors, incidents) [Risk signals]

CREATE TABLE product_events (
  event_id        BIGSERIAL PRIMARY KEY,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

  service         TEXT,                     -- e.g., "api", "checkout", "auth"
  event_type      TEXT NOT NULL,            -- server_error/spike_latency/outage
  severity        TEXT,                     -- info/warn/critical
  value           DOUBLE PRECISION,         -- e.g., error_count, latency_ms, etc.

  meta            JSONB
);

CREATE INDEX idx_product_events_time ON product_events(created_at);
CREATE INDEX idx_product_events_service ON product_events(service);
CREATE INDEX idx_product_events_type ON product_events(event_type);


-- 9) (Optional) Normalized tags (if you want clean many-to-many)
--    If you prefer simplicity, keep only tickets.tags_str and skip this.

CREATE TABLE tags (
  tag_id      BIGSERIAL PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE
);

CREATE TABLE ticket_tags (
  ticket_id   BIGINT NOT NULL REFERENCES tickets(ticket_id) ON DELETE CASCADE,
  tag_id      BIGINT NOT NULL REFERENCES tags(tag_id) ON DELETE CASCADE,
  PRIMARY KEY (ticket_id, tag_id)
);

CREATE INDEX idx_ticket_tags_tag_id ON ticket_tags(tag_id);


-- 10) Views (optional) for monitoring / dashboards

-- Latest prediction per ticket (very useful for dashboards)
CREATE OR REPLACE VIEW v_ticket_latest_prediction AS
SELECT
  t.*,
  p.prediction_id,
  p.created_at AS prediction_time,
  p.model_name,
  p.policy,
  p.threshold_high,
  p.pred_category,
  p.pred_priority,
  p.proba_high
FROM tickets t
LEFT JOIN LATERAL (
  SELECT *
  FROM predictions p
  WHERE p.ticket_id = t.ticket_id
  ORDER BY p.created_at DESC
  LIMIT 1
) p ON TRUE;

-- Daily ticket volume + high rate (global)
CREATE OR REPLACE VIEW v_daily_ticket_metrics AS
SELECT
  date_trunc('day', created_at) AS day,
  COUNT(*) AS tickets_total,
  SUM(CASE WHEN EXISTS (
      SELECT 1 FROM predictions p
      WHERE p.ticket_id = tickets.ticket_id
      AND p.created_at = (
        SELECT MAX(p2.created_at) FROM predictions p2 WHERE p2.ticket_id = tickets.ticket_id
      )
      AND p.pred_priority = 'high'
    ) THEN 1 ELSE 0 END) AS tickets_high_pred
FROM tickets
GROUP BY 1
ORDER BY 1;
