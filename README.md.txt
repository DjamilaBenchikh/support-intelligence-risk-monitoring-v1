# Support Intelligence & Risk Monitoring System (End-to-End)

An end-to-end, production-like MVP that combines **Support Ticket Automation** (triage + priority prediction)
with **Operational Monitoring** (anomaly detection + alerts), exposed via a **FastAPI** service and backed by a
**PostgreSQL** database fully runnable with **Docker Compose**.

---

## Why this project?

Support teams often face:
- high ticket volume (manual triage is slow and costly)
- missed urgent tickets (bad prioritization increases risk)
- lack of visibility into incidents (spikes in tickets, high-priority rate, etc.)

This system shows how to build something **operational**:
**triage + prediction + monitoring + alerting**, with a single source of truth (DB) and an API layer.

---

## What it does

### 1) Support Automation
- **Ticket category triage**: `Billing / Bug / Account / Other`
- **Priority prediction**: `low / medium / high`
- **Two inference policies**
  - **Balanced policy**: best overall macro performance
  - **Safety policy**: increases recall for `high` priority using a probability threshold on `P(high)`

### 2) Risk Monitoring (Anomaly Detection)
Detects abnormal patterns using rolling statistics (e.g., z-score):
- sudden spikes in **ticket volume**
- spikes in **high-priority rate**
- (easy to extend: per queue, per tag, per customer)

Alerts are stored in the database and exposed through the API.

### 3) API + Database (prod-like)
- **FastAPI** service (Swagger UI)
- **PostgreSQL** as the “single source of truth”
- Dockerized environment for reproducible runs

---

## Architecture (high level)

`Ticket (API)` → **Postgres** (`tickets`) → **Model inference** → **Postgres** (`predictions`)  
→ **Batch monitoring (T6)** → **Postgres** (`alerts`) → `API / Dashboard`

> You can run the full pipeline locally with Docker Compose.



