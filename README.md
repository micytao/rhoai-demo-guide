# RHOAI GenAI Studio — Guardrails & Tracing Demo Guide

A hands-on demo guide for **Red Hat OpenShift AI (RHOAI) GenAI Studio** showing how
platform-level guardrails enforce enterprise policies on top of a model's built-in
safety, and how to wire full observability with MLflow tracing.

---

## Why This Exists

LLMs ship with built-in safety (RLHF alignment), but that has two gaps:

1. **Clever prompts bypass it** — "educational" framing, role-play, and fiction
   bypass the model's training while platform guardrails catch them.
2. **Business policies can't be trained in** — brand protection, competitive
   comparisons, and compliance rules are enterprise-specific. Only configurable
   guardrails can enforce them.

This guide demonstrates both problems and the solution using **NemoGuardrails** on
RHOAI, then wires **MLflow tracing** to provide a full audit trail of every
interaction — blocked or allowed.

---

## What's Inside

```
rhoai-demo-guide/
├── README.md                           ← You are here
├── demo/
│   └── guardrails-demo-flow.md         ← 5-act demo script (run this live)
├── scripts/
│   └── setup-mlflow-tracing.sh         ← Idempotent setup script (3 phases)
└── docs/
    ├── mlflow-tracing-guide.md         ← Detailed technical reference
    └── mlflow-tracing-flow.html        ← Interactive animated diagram
```

| File | Purpose |
|---|---|
| [`demo/guardrails-demo-flow.md`](demo/guardrails-demo-flow.md) | Step-by-step demo script: 5 acts from baseline to guardrails to traces |
| [`scripts/setup-mlflow-tracing.sh`](scripts/setup-mlflow-tracing.sh) | Bash script that wires OTEL tracing from Playground & NemoGuardrails into MLflow |
| [`docs/mlflow-tracing-guide.md`](docs/mlflow-tracing-guide.md) | Deep-dive reference: architecture, env vars, design decisions, troubleshooting |
| [`docs/mlflow-tracing-flow.html`](docs/mlflow-tracing-flow.html) | Animated interactive diagram of the full setup and runtime trace flows |

---

## Interactive Animated Flow Diagram

The animated diagram walks through the full setup and runtime trace flows
interactively — click any node for detailed tooltips with `oc` commands and
config values.

### ▶️ [Launch the Interactive Diagram](https://micytao.github.io/rhoai-demo-guide/mlflow-tracing-flow.html)

> Hosted on GitHub Pages — opens the full animated diagram directly in your browser.

**4 animated flows included:**

| Flow | What it shows |
|---|---|
| **Full Setup (Phases 1–3)** | 23-step install sequence: MLflow → Playground tracing → NemoGuardrails tracing |
| **Trace Flow: Prompt Allowed** | Runtime path when guardrails pass — all three trace types appear |
| **Trace Flow: Prompt Blocked** | Runtime path when input rail blocks — only `self_check_input` trace |
| **Common Pitfalls** | 8 failure modes with fixes (SSL errors, missing headers, noisy spans, etc.) |

---

## The Demo (5 Acts)

The [demo script](demo/guardrails-demo-flow.md) tells a story in five acts:

### ACT 1 — Baseline: Model Safety Only

Run 5 prompts against the model with **no platform guardrails**:

| Prompt | What happens |
|---|---|
| Safe question (containers) | ✅ Normal answer |
| Obvious jailbreak (DAN) | ✅ Model refuses (built-in RLHF) |
| "Educational" phishing request | ⚠️ **Model generates phishing email** |
| Role-play security bypass | ⚠️ **Model generates harmful content** |
| Brand policy violation | ⚠️ **Model happily complies** |

### ACT 2 — Enable Platform Guardrails

Wire NemoGuardrails with custom enterprise policies:
- Patch guardrail config with business rules (brand, phishing, security)
- Point NemoGuardrails at the real model through MaaS
- Inject API key and restart

### ACT 3 — Same Prompts, Now Blocked

Re-run the same 5 prompts — guardrails now catch what the model missed:

| Prompt | Before | After |
|---|---|---|
| Safe question | ✅ Allowed | ✅ Allowed |
| Obvious jailbreak | ✅ Model refuses | 🛑 Guardrail blocks (faster, no tokens wasted) |
| "Educational" phishing | ⚠️ Model fooled | 🛑 **Guardrail blocks it** |
| Role-play bypass | ⚠️ Model fooled | 🛑 **Guardrail blocks it** |
| Brand policy violation | ⚠️ Model complies | 🛑 **Guardrail blocks it** |

### ACT 4 — Save the Agent

Persist the model + guardrails configuration as a reusable agent.

### ACT 5 — MLflow Traces

View the full audit trail in MLflow — every request is traced, blocked or not.

---

## MLflow Tracing Setup

### Architecture

```
User prompt → OGX Playground ──→ MaaS Model (gpt-oss-20b)
                   │
                   │  OTEL traces (openai-v2 instrumentation)
                   ▼
              ┌─────────┐
              │  MLflow  │  ◄── OTLP/HTTPS with SA token auth
              │  Traces  │
              └─────────┘
                   ▲
                   │  OTEL traces (built-in NemoGuardrails tracing)
                   │
              NemoGuardrails ──→ MaaS Model (LLM-as-judge)
```

### Quick Start

```bash
# Configure everything in the 'demo' namespace (auto-detects MaaS gateway and model)
./scripts/setup-mlflow-tracing.sh --namespace demo

# Explicit MaaS gateway and model (if auto-detect doesn't work)
./scripts/setup-mlflow-tracing.sh --namespace demo \
  --maas-gateway https://maas.apps.<cluster>/v1 \
  --model publishers/llm/models/gpt-oss-20b

# Preview without making changes
./scripts/setup-mlflow-tracing.sh --namespace demo --dry-run

# Only set up MLflow (skip app patching)
./scripts/setup-mlflow-tracing.sh --namespace demo --skip-playground --skip-guardrails
```

### What the Script Does (4 Phases)

| Phase | Steps | Key Actions |
|---|---|---|
| **0. Playground Preflight** | Check OGXServer → Create if missing | If no Playground exists: creates NemoGuardrails CR, `guardrail-placeholder` ConfigMap, PgVector (5 resources), `llama-stack-config`, OGXServer CR. Skips if Playground already exists. |
| **1. MLflow Setup** | Verify operator → Create CR → Create experiment | Ensures MLflow is running with a `guardrails-playground` experiment. Auto-patches workspace selector if namespace changed. |
| **2. Playground Tracing** | RBAC → Auth secret → CA cert → Command wrap → Env vars | Activates `opentelemetry-instrument` on OGX with 11 OTEL env vars |
| **3. NemoGuardrails Tracing** | RBAC → Auth secret → **MaaS API key** → CR env patch → **Model backend + tracing config** | Auto-detects MaaS gateway, creates a real API key, replaces `placeholder.invalid` with the real model endpoint, and uses `PYTHONPATH` for operator-proof OTEL SDK init |

### Key Design Decisions

| Decision | Rationale |
|---|---|
| Auto-create Playground (Phase 0) | If no OGXServer exists, creates NemoGuardrails + PgVector + OGXServer automatically; skips if Playground already exists |
| `enable-auth` annotation on NGR CR | `security.opendatahub.io/enable-auth: "true"` triggers `kube-rbac-proxy` sidecar (HTTPS on 8443) — required for BFF communication |
| `opentelemetry-instrument` for OGX | OGXServer CRD supports command overrides — operator-safe |
| `PYTHONPATH` for NemoGuardrails | NemoGuardrails CRD has no command overrides; TrustyAI operator reverts deployment patches. `PYTHONPATH` triggers `sitecustomize.py` at Python startup — same effect, operator-proof |
| 23 instrumentors disabled (OGX) | Keeps only `openai-v2` + `fastapi`, suppresses noisy HTTP/DB/template spans |
| `span_only` content capture | MLflow reads span attributes, not OTEL events — `event_only` leaves Chat view empty |
| Separate cert paths | OGX (RHEL): `/etc/pki/tls/custom/service-ca.crt` · NemoGuardrails (Debian): `/etc/ssl/certs/ca-certificates.crt` |
| Auto-detect MaaS gateway | Scans OpenShift routes for `maas` hostname; override with `--maas-gateway` |
| Auto-create MaaS API key | Creates a 7-day key via MaaS API; detects and replaces stub keys |

---

## Prerequisites

- **RHOAI 3.5+** with GenAI Studio / MaaS deployed
- **`oc` CLI** logged in with cluster-admin or project-admin privileges
- A **project/namespace** (e.g. `demo`) — can be created from the RHOAI Dashboard or
  via `oc create namespace`. The script adds missing RHOAI labels automatically.
- The **MLflow operator** enabled (`mlflowoperator: Managed` in the DataScienceCluster)

> **Playground creation is automatic.** If no OGX Playground exists in the namespace,
> the script creates one (Phase 0) with NemoGuardrails, PgVector, and the OGXServer.
> If a Playground already exists (e.g. created from the Dashboard UI), Phase 0 is
> skipped entirely.

---

## Troubleshooting

See the full [troubleshooting section](docs/mlflow-tracing-guide.md#troubleshooting) in the tracing guide. Common issues:

| Symptom | Likely Cause | Fix |
|---|---|---|
| No traces at all | OTEL SDK not initialized | Verify `opentelemetry-instrument` wrapper (OGX) or `PYTHONPATH` (NGR) |
| NemoGuardrails traces missing (but Playground works) | Guardrail model backend is `placeholder.invalid` or API key is invalid | Re-run the script — it auto-detects MaaS and creates a real API key. Or use `--maas-gateway` and `--model` |
| `401 Unauthorized` | SA token expired or missing role | Recreate auth secret, verify `edit` role |
| `SSL CERTIFICATE_VERIFY_FAILED` | Wrong CA cert path | RHEL: mount `config-service-cabundle`; Debian: already has `ca-bundle-transfer` |
| `400 Bad Request` | Missing workspace headers | Ensure `X-MLflow-Workspace` + `X-MLflow-Experiment-Id` in OTEL headers secret |
| Empty Chat tab in MLflow | Content capture misconfigured | Set `OTEL_SEMCONV_STABILITY_OPT_IN=gen_ai_latest_experimental` + `span_only` |
| Dozens of noisy spans per prompt | Instrumentors not filtered | Set `OTEL_PYTHON_DISABLED_INSTRUMENTATIONS` (23 for OGX, 3 for NGR) |
| "Guardrail check was not applied" in UI | NemoGuardrails service on port 80 instead of 443 | Script auto-fixes; or manually: `oc patch svc nemoguardrails -n <ns> --type json -p '[{"op":"replace","path":"/spec/ports/0/port","value":443},{"op":"replace","path":"/spec/ports/0/targetPort","value":8443}]'` |
| Model missing from Playground dropdown | `registered_resources.models` not in `llama-stack-config` | Re-create with model registration section; script handles this automatically |

---

## License

Internal demo guide — Red Hat OpenShift AI.
