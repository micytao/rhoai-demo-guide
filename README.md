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
# Configure everything in the 'demo' namespace
./scripts/setup-mlflow-tracing.sh --namespace demo

# Preview without making changes
./scripts/setup-mlflow-tracing.sh --namespace demo --dry-run

# Only set up MLflow (skip app patching)
./scripts/setup-mlflow-tracing.sh --namespace demo --skip-playground --skip-guardrails
```

### What the Script Does (3 Phases)

| Phase | Steps | Key Actions |
|---|---|---|
| **1. MLflow Setup** | Verify operator → Create CR → Create experiment | Ensures MLflow is running with a `guardrails-playground` experiment |
| **2. Playground Tracing** | RBAC → Auth secret → CA cert → Command wrap → Env vars | Activates `opentelemetry-instrument` on OGX with 11 OTEL env vars |
| **3. NemoGuardrails Tracing** | RBAC → Auth secret → CR env patch → Config update | Uses `PYTHONPATH` trick for operator-proof OTEL SDK initialization |

### Key Design Decisions

| Decision | Rationale |
|---|---|
| `opentelemetry-instrument` for OGX | OGXServer CRD supports command overrides — operator-safe |
| `PYTHONPATH` for NemoGuardrails | NemoGuardrails CRD has no command overrides; TrustyAI operator reverts deployment patches. `PYTHONPATH` triggers `sitecustomize.py` at Python startup — same effect, operator-proof |
| 23 instrumentors disabled (OGX) | Keeps only `openai-v2` + `fastapi`, suppresses noisy HTTP/DB/template spans |
| `span_only` content capture | MLflow reads span attributes, not OTEL events — `event_only` leaves Chat view empty |
| Separate cert paths | OGX (RHEL): `/etc/pki/tls/custom/service-ca.crt` · NemoGuardrails (Debian): `/etc/ssl/certs/ca-certificates.crt` |

---

## Prerequisites

- **RHOAI 3.5+** with GenAI Studio / MaaS deployed
- **`oc` CLI** logged in with cluster-admin or project-admin privileges
- A **namespace** (e.g. `demo`) with:
  - An OGXServer (Playground) already running
  - Optionally, NemoGuardrails deployed
- The **MLflow operator** enabled (`mlflowoperator: Managed` in the DataScienceCluster)

---

## Troubleshooting

See the full [troubleshooting section](docs/mlflow-tracing-guide.md#troubleshooting) in the tracing guide. Common issues:

| Symptom | Likely Cause | Fix |
|---|---|---|
| No traces at all | OTEL SDK not initialized | Verify `opentelemetry-instrument` wrapper (OGX) or `PYTHONPATH` (NGR) |
| `401 Unauthorized` | SA token expired or missing role | Recreate auth secret, verify `edit` role |
| `SSL CERTIFICATE_VERIFY_FAILED` | Wrong CA cert path | RHEL: mount `config-service-cabundle`; Debian: already has `ca-bundle-transfer` |
| `400 Bad Request` | Missing workspace headers | Ensure `X-MLflow-Workspace` + `X-MLflow-Experiment-Id` in OTEL headers secret |
| Empty Chat tab in MLflow | Content capture misconfigured | Set `OTEL_SEMCONV_STABILITY_OPT_IN=gen_ai_latest_experimental` + `span_only` |
| Dozens of noisy spans per prompt | Instrumentors not filtered | Set `OTEL_PYTHON_DISABLED_INSTRUMENTATIONS` (23 for OGX, 3 for NGR) |

---

## License

Internal demo guide — Red Hat OpenShift AI.
