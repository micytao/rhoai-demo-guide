#!/usr/bin/env bash
# setup-mlflow-tracing.sh — Wire OpenTelemetry tracing from OGX Playground
# and NemoGuardrails into MLflow on RHOAI.
#
# Idempotent: safe to run multiple times. Checks at each step whether the
# resource already exists and skips if so.
#
# Usage:
#   ./scripts/setup-mlflow-tracing.sh [OPTIONS]
#
#   --namespace <ns>     Target namespace (default: demo)
#   --skip-mlflow        Skip Phase 1 (MLflow setup)
#   --skip-playground    Skip Phase 2 (Playground tracing)
#   --skip-guardrails    Skip Phase 3 (NemoGuardrails tracing)
#   --dry-run            Show what would be done without making changes
#   -h, --help           Show this help
#
# See docs/mlflow-tracing-guide.md for a detailed walkthrough.

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────
# Defaults
# ──────────────────────────────────────────────────────────────────────
NS="demo"
SKIP_MLFLOW=false
SKIP_PLAYGROUND=false
SKIP_GUARDRAILS=false
DRY_RUN=false

MLFLOW_NS="redhat-ods-applications"
MLFLOW_ENDPOINT="https://mlflow.${MLFLOW_NS}.svc:8443"
EXPERIMENT_NAME="guardrails-playground"

# OGX specifics
OGX_DISABLED_INSTRUMENTORS="asgi,asyncio,asyncpg,boto3sqs,botocore,click,dbapi,grpc,httpx,jinja2,logging,pymongo,redis,requests,sqlalchemy,sqlite3,starlette,system-metrics,threading,tortoiseorm,urllib,urllib3,wsgi"
OGX_CERT_PATH="/etc/pki/tls/custom/service-ca.crt"

# NemoGuardrails specifics
NGR_DISABLED_INSTRUMENTORS="asgi,fastapi,httpx"
NGR_CERT_PATH="/etc/ssl/certs/ca-certificates.crt"

# ──────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
dry()   { printf "${YELLOW}[DRY]${NC}   %s\n" "$*"; }

run() {
  if $DRY_RUN; then
    dry "$*"
  else
    eval "$@"
  fi
}

usage() {
  sed -n '/^# Usage:/,/^# See /p' "$0" | sed 's/^# \?//'
  exit 0
}

# ──────────────────────────────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)     NS="$2"; shift 2 ;;
    --skip-mlflow)   SKIP_MLFLOW=true; shift ;;
    --skip-playground) SKIP_PLAYGROUND=true; shift ;;
    --skip-guardrails) SKIP_GUARDRAILS=true; shift ;;
    --dry-run)       DRY_RUN=true; shift ;;
    -h|--help)       usage ;;
    *) err "Unknown option: $1"; usage ;;
  esac
done

# Verify oc is available and logged in
if ! command -v oc &>/dev/null; then
  err "oc CLI not found. Install it from https://mirror.openshift.com/pub/openshift-v4/clients/ocp/"
  exit 1
fi
if ! oc whoami &>/dev/null; then
  err "Not logged in to OpenShift. Run 'oc login' first."
  exit 1
fi

info "Namespace:         ${NS}"
info "MLflow namespace:  ${MLFLOW_NS}"
info "MLflow endpoint:   ${MLFLOW_ENDPOINT}"
$DRY_RUN && info "Mode: DRY RUN (no changes will be made)"
echo ""

# ======================================================================
#  PHASE 1: MLflow Setup
# ======================================================================
phase1_mlflow() {
  echo ""
  info "═══════════════════════════════════════════════════════════════"
  info "  PHASE 1: MLflow Setup"
  info "═══════════════════════════════════════════════════════════════"
  echo ""

  # Step 1.1 — Verify mlflowoperator is Managed
  info "Step 1.1 — Checking MLflow operator status..."
  local mgmt_state
  mgmt_state=$(oc get datasciencecluster default-dsc \
    -o jsonpath='{.spec.components.mlflowoperator.managementState}' 2>/dev/null || echo "")

  if [[ "$mgmt_state" != "Managed" ]]; then
    err "MLflow operator is not enabled (managementState=${mgmt_state:-unknown})."
    err "Enable it in RHOAI Dashboard → Settings → Cluster Settings, or run:"
    err "  oc patch datasciencecluster default-dsc --type merge \\"
    err "    -p '{\"spec\":{\"components\":{\"mlflowoperator\":{\"managementState\":\"Managed\"}}}}'"
    exit 1
  fi
  ok "MLflow operator is Managed"

  # Step 1.2 — Wait for the MLflow CRD
  info "Step 1.2 — Waiting for MLflow CRD..."
  local crd_ready=false
  for i in $(seq 1 12); do
    if oc get crd mlflows.mlflow.opendatahub.io &>/dev/null; then
      crd_ready=true
      break
    fi
    info "  Waiting for CRD... (${i}/12)"
    sleep 5
  done
  if ! $crd_ready; then
    err "MLflow CRD not found after 60s. The operator may not be fully installed."
    exit 1
  fi
  ok "MLflow CRD is available"

  # Step 1.3 — Create the MLflow CR (singleton name: mlflow)
  info "Step 1.3 — Checking MLflow CR..."
  if oc get mlflow mlflow &>/dev/null 2>&1; then
    ok "MLflow CR already exists — skipping creation"
  else
    info "Creating MLflow CR..."
    run "cat <<'MLFLOW_CR' | oc apply -f -
apiVersion: mlflow.opendatahub.io/v1
kind: MLflow
metadata:
  name: mlflow
spec:
  backendStoreUri: \"sqlite:////mlflow/mlflow.db\"
  serveArtifacts: true
  artifactsDestination: \"file:///mlflow/artifacts\"
  storage:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 5Gi
  workspaceLabelSelector:
    matchLabels:
      kubernetes.io/metadata.name: ${NS}
MLFLOW_CR"
    ok "MLflow CR created"
  fi

  # Step 1.4 — Wait for MLflow pod
  info "Step 1.4 — Waiting for MLflow deployment to be ready..."
  if ! $DRY_RUN; then
    if ! oc rollout status deployment/mlflow -n "${MLFLOW_NS}" --timeout=120s 2>/dev/null; then
      err "MLflow deployment did not become ready within 120s."
      err "Check: oc get pods -n ${MLFLOW_NS} -l app=mlflow"
      exit 1
    fi
  else
    dry "oc rollout status deployment/mlflow -n ${MLFLOW_NS} --timeout=120s"
  fi
  ok "MLflow is running"

  # Step 1.5 — Create MLflow experiment
  info "Step 1.5 — Creating MLflow experiment '${EXPERIMENT_NAME}'..."
  if $DRY_RUN; then
    dry "Create experiment '${EXPERIMENT_NAME}' in workspace '${NS}' via MLflow API"
  else
    # Get a temporary token for the default SA in the namespace
    local tmp_token
    tmp_token=$(oc create token default -n "${NS}" --duration=5m 2>/dev/null || true)
    if [[ -z "$tmp_token" ]]; then
      # Fallback: use the currently-logged-in user's token
      tmp_token=$(oc whoami -t 2>/dev/null || true)
    fi

    if [[ -z "$tmp_token" ]]; then
      warn "Could not obtain a token to create MLflow experiment. Create it manually."
    else
      # Check if experiment already exists by searching
      local search_result
      search_result=$(oc exec deployment/mlflow -n "${MLFLOW_NS}" -c mlflow -- \
        curl -sk "${MLFLOW_ENDPOINT}/mlflow/api/2.0/mlflow/experiments/get-by-name?experiment_name=${EXPERIMENT_NAME}" \
        -H "Authorization: Bearer ${tmp_token}" \
        -H "X-MLflow-Workspace: ${NS}" 2>/dev/null || echo "{}")

      if echo "$search_result" | grep -q '"experiment_id"'; then
        local exp_id
        exp_id=$(echo "$search_result" | python3 -c "import sys,json; print(json.load(sys.stdin)['experiment']['experiment_id'])" 2>/dev/null || echo "unknown")
        ok "Experiment '${EXPERIMENT_NAME}' already exists (ID=${exp_id}) — skipping"
      else
        local create_result
        create_result=$(oc exec deployment/mlflow -n "${MLFLOW_NS}" -c mlflow -- \
          curl -sk -X POST "${MLFLOW_ENDPOINT}/mlflow/api/2.0/mlflow/experiments/create" \
          -H "Authorization: Bearer ${tmp_token}" \
          -H "Content-Type: application/json" \
          -H "X-MLflow-Workspace: ${NS}" \
          -d "{\"name\": \"${EXPERIMENT_NAME}\"}" 2>/dev/null || echo "{}")

        if echo "$create_result" | grep -q '"experiment_id"'; then
          local exp_id
          exp_id=$(echo "$create_result" | python3 -c "import sys,json; print(json.load(sys.stdin)['experiment_id'])" 2>/dev/null || echo "unknown")
          ok "Experiment '${EXPERIMENT_NAME}' created (ID=${exp_id})"
        else
          warn "Could not create experiment via API. Response: ${create_result}"
          warn "Create it manually in the MLflow UI: workspace=${NS}, name=${EXPERIMENT_NAME}"
        fi
      fi
    fi
  fi

  echo ""
  ok "Phase 1 complete: MLflow is ready"
}

# ======================================================================
#  PHASE 2: Playground (OGX) Tracing
# ======================================================================
phase2_playground() {
  echo ""
  info "═══════════════════════════════════════════════════════════════"
  info "  PHASE 2: Playground (OGX) Tracing"
  info "═══════════════════════════════════════════════════════════════"
  echo ""

  # Step 2.0 — Find the OGXServer
  info "Step 2.0 — Finding OGXServer in namespace '${NS}'..."
  local ogx_name
  ogx_name=$(oc get ogxserver -n "${NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -z "$ogx_name" ]]; then
    warn "No OGXServer found in namespace '${NS}'. Skipping Playground tracing."
    return 0
  fi
  ok "Found OGXServer: ${ogx_name}"

  # Detect the Playground deployment and SA
  local deploy_name="lsd-genai-playground"
  local sa_name
  sa_name=$(oc get deployment "${deploy_name}" -n "${NS}" \
    -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || echo "")
  if [[ -z "$sa_name" ]]; then
    # Fall back to deployment name-based SA
    sa_name="${deploy_name}-sa"
    warn "Could not detect SA from deployment; assuming '${sa_name}'"
  fi
  info "Playground SA: ${sa_name}"

  # Check if OTEL is already configured
  local otel_svc
  otel_svc=$(oc get deployment "${deploy_name}" -n "${NS}" \
    -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' 2>/dev/null \
    | grep '^OTEL_SERVICE_NAME$' || true)
  if [[ -n "$otel_svc" ]]; then
    ok "OTEL env vars already present on ${deploy_name} — skipping Phase 2"
    return 0
  fi

  # Step 2.1 — Grant SA edit role for MLflow auth
  info "Step 2.1 — Granting '${sa_name}' edit role in '${NS}'..."
  run "oc adm policy add-role-to-user edit system:serviceaccount:${NS}:${sa_name} -n ${NS} 2>/dev/null || true"
  ok "RBAC granted"

  # Step 2.2 — Create auth secret for OTEL headers
  local secret_name="otel-mlflow-auth"
  info "Step 2.2 — Creating auth secret '${secret_name}'..."
  if oc get secret "${secret_name}" -n "${NS}" &>/dev/null; then
    ok "Secret '${secret_name}' already exists — skipping"
  else
    if $DRY_RUN; then
      dry "oc create secret generic ${secret_name} with SA token + workspace headers"
    else
      # Get the MLflow experiment ID
      local exp_id="1"
      local tmp_token
      tmp_token=$(oc create token default -n "${NS}" --duration=5m 2>/dev/null || oc whoami -t 2>/dev/null || true)
      if [[ -n "$tmp_token" ]]; then
        local search_result
        search_result=$(oc exec deployment/mlflow -n "${MLFLOW_NS}" -c mlflow -- \
          curl -sk "${MLFLOW_ENDPOINT}/mlflow/api/2.0/mlflow/experiments/get-by-name?experiment_name=${EXPERIMENT_NAME}" \
          -H "Authorization: Bearer ${tmp_token}" \
          -H "X-MLflow-Workspace: ${NS}" 2>/dev/null || echo "{}")
        local found_id
        found_id=$(echo "$search_result" | python3 -c "import sys,json; print(json.load(sys.stdin)['experiment']['experiment_id'])" 2>/dev/null || echo "")
        if [[ -n "$found_id" ]]; then
          exp_id="$found_id"
        fi
      fi
      info "  Using experiment ID: ${exp_id}"

      local sa_token
      sa_token=$(oc create token "${sa_name}" -n "${NS}" --duration=8760h)
      oc create secret generic "${secret_name}" -n "${NS}" \
        --from-literal=header="Authorization=Bearer ${sa_token},X-MLflow-Workspace=${NS},X-MLflow-Experiment-Id=${exp_id}"
      ok "Secret '${secret_name}' created with SA token (valid ~1 year)"
    fi
  fi

  # Step 2.3 — Mount service-CA certificate volume
  info "Step 2.3 — Checking service-CA volume mount..."
  local has_volume
  has_volume=$(oc get deployment "${deploy_name}" -n "${NS}" \
    -o jsonpath='{.spec.template.spec.volumes[*].name}' 2>/dev/null | grep -o 'odh-ca-bundle' || true)
  if [[ -n "$has_volume" ]]; then
    ok "Service-CA volume already mounted — skipping"
  else
    info "Mounting config-service-cabundle ConfigMap..."
    run "oc patch deployment ${deploy_name} -n ${NS} --type json -p '[
  {\"op\": \"add\", \"path\": \"/spec/template/spec/volumes/-\",
   \"value\": {\"name\": \"odh-ca-bundle\", \"configMap\":
     {\"name\": \"config-service-cabundle\",
      \"items\": [{\"key\": \"service-ca.crt\", \"path\": \"service-ca.crt\"}]}}},
  {\"op\": \"add\", \"path\": \"/spec/template/spec/containers/0/volumeMounts/-\",
   \"value\": {\"name\": \"odh-ca-bundle\", \"mountPath\": \"/etc/pki/tls/custom\", \"readOnly\": true}}
]'"
    ok "Service-CA volume mounted at /etc/pki/tls/custom"
  fi

  # Step 2.4 — Wrap startup command with opentelemetry-instrument
  info "Step 2.4 — Patching OGXServer command..."
  local current_cmd
  current_cmd=$(oc get ogxserver "${ogx_name}" -n "${NS}" \
    -o jsonpath='{.spec.workload.overrides.command}' 2>/dev/null || echo "")
  if echo "$current_cmd" | grep -q 'opentelemetry-instrument'; then
    ok "Command already wrapped with opentelemetry-instrument — skipping"
  else
    run "oc patch ogxserver ${ogx_name} -n ${NS} --type merge -p '{
  \"spec\": {
    \"workload\": {
      \"overrides\": {
        \"command\": [\"/bin/sh\", \"-c\", \"opentelemetry-instrument ogx run /etc/ogx/config.yaml --insecure\"]
      }
    }
  }
}'"
    ok "OGXServer command wrapped with opentelemetry-instrument"
  fi

  # Step 2.5 — Patch deployment with OTEL env vars
  info "Step 2.5 — Adding OTEL env vars to Playground deployment..."

  # Read current env vars (as JSON array), filter out any OTEL/opentelemetry ones
  if $DRY_RUN; then
    dry "Read current env from deployment, merge OTEL vars, apply JSON patch"
  else
    local current_env
    current_env=$(oc get deployment "${deploy_name}" -n "${NS}" \
      -o json | python3 -c "
import sys, json
dep = json.load(sys.stdin)
envs = dep['spec']['template']['spec']['containers'][0].get('env', [])
# Filter out existing OTEL vars to avoid duplicates
filtered = [e for e in envs if not e['name'].startswith('OTEL_')]
print(json.dumps(filtered))
" 2>/dev/null || echo "[]")

    # Build the complete env array: existing + OTEL
    local full_env
    full_env=$(python3 -c "
import json
existing = json.loads('''${current_env}''')
otel_vars = [
    {'name': 'OTEL_SERVICE_NAME', 'value': 'playground'},
    {'name': 'OTEL_EXPORTER_OTLP_ENDPOINT', 'value': '${MLFLOW_ENDPOINT}'},
    {'name': 'OTEL_EXPORTER_OTLP_PROTOCOL', 'value': 'http/protobuf'},
    {'name': 'OTEL_EXPORTER_OTLP_HEADERS', 'valueFrom': {'secretKeyRef': {'name': '${secret_name}', 'key': 'header'}}},
    {'name': 'OTEL_EXPORTER_OTLP_CERTIFICATE', 'value': '${OGX_CERT_PATH}'},
    {'name': 'OTEL_SEMCONV_STABILITY_OPT_IN', 'value': 'gen_ai_latest_experimental'},
    {'name': 'OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT', 'value': 'span_only'},
    {'name': 'OTEL_PYTHON_DISABLED_INSTRUMENTATIONS', 'value': '${OGX_DISABLED_INSTRUMENTORS}'},
    {'name': 'OTEL_TRACES_EXPORTER', 'value': 'otlp'},
    {'name': 'OTEL_METRICS_EXPORTER', 'value': 'none'},
    {'name': 'OTEL_LOGS_EXPORTER', 'value': 'none'},
]
combined = existing + otel_vars
print(json.dumps(combined))
")

    # Apply via strategic merge patch on the deployment
    oc patch deployment "${deploy_name}" -n "${NS}" --type strategic \
      -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"lsd-genai-playground\",\"env\":${full_env}}]}}}}"
    ok "OTEL env vars applied to Playground deployment"
  fi

  # Step 2.6 — Wait for rollout
  info "Step 2.6 — Waiting for Playground rollout..."
  if ! $DRY_RUN; then
    oc rollout status deployment/"${deploy_name}" -n "${NS}" --timeout=120s 2>/dev/null || true
  else
    dry "oc rollout status deployment/${deploy_name} -n ${NS} --timeout=120s"
  fi
  ok "Playground deployment rolled out"

  echo ""
  ok "Phase 2 complete: Playground tracing configured"
}

# ======================================================================
#  PHASE 3: NemoGuardrails Tracing
# ======================================================================
phase3_guardrails() {
  echo ""
  info "═══════════════════════════════════════════════════════════════"
  info "  PHASE 3: NemoGuardrails Tracing"
  info "═══════════════════════════════════════════════════════════════"
  echo ""

  # Step 3.0 — Find NemoGuardrails
  info "Step 3.0 — Finding NemoGuardrails in namespace '${NS}'..."
  local ngr_name
  ngr_name=$(oc get nemoguardrails -n "${NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -z "$ngr_name" ]]; then
    warn "No NemoGuardrails found in namespace '${NS}'. Skipping guardrails tracing."
    return 0
  fi
  ok "Found NemoGuardrails: ${ngr_name}"

  # Detect the SA
  local deploy_name="nemoguardrails"
  local sa_name
  sa_name=$(oc get deployment "${deploy_name}" -n "${NS}" \
    -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || echo "")
  if [[ -z "$sa_name" ]]; then
    sa_name="nemoguardrails-serviceaccount"
    warn "Could not detect SA from deployment; assuming '${sa_name}'"
  fi
  info "NemoGuardrails SA: ${sa_name}"

  # Check if OTEL is already configured
  local otel_svc
  otel_svc=$(oc get deployment "${deploy_name}" -n "${NS}" \
    -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' 2>/dev/null \
    | grep '^OTEL_SERVICE_NAME$' || true)
  if [[ -n "$otel_svc" ]]; then
    ok "OTEL env vars already present on ${deploy_name} — skipping Phase 3 env setup"
  else
    # Step 3.1 — Grant SA edit role
    info "Step 3.1 — Granting '${sa_name}' edit role..."
    run "oc adm policy add-role-to-user edit system:serviceaccount:${NS}:${sa_name} -n ${NS} 2>/dev/null || true"
    ok "RBAC granted"

    # Also grant the ClusterRole for MLflow access
    run "oc adm policy add-cluster-role-to-user mlflow-operator-mlflow-edit system:serviceaccount:${NS}:${sa_name} 2>/dev/null || true"
    ok "MLflow ClusterRole granted"

    # Step 3.2 — Create auth secret
    local secret_name="nemoguardrails-otel-auth"
    info "Step 3.2 — Creating auth secret '${secret_name}'..."
    if oc get secret "${secret_name}" -n "${NS}" &>/dev/null; then
      ok "Secret '${secret_name}' already exists — skipping"
    else
      if $DRY_RUN; then
        dry "oc create secret generic ${secret_name} with SA token + workspace headers"
      else
        # Get the MLflow experiment ID
        local exp_id="1"
        local tmp_token
        tmp_token=$(oc create token default -n "${NS}" --duration=5m 2>/dev/null || oc whoami -t 2>/dev/null || true)
        if [[ -n "$tmp_token" ]]; then
          local search_result
          search_result=$(oc exec deployment/mlflow -n "${MLFLOW_NS}" -c mlflow -- \
            curl -sk "${MLFLOW_ENDPOINT}/mlflow/api/2.0/mlflow/experiments/get-by-name?experiment_name=${EXPERIMENT_NAME}" \
            -H "Authorization: Bearer ${tmp_token}" \
            -H "X-MLflow-Workspace: ${NS}" 2>/dev/null || echo "{}")
          local found_id
          found_id=$(echo "$search_result" | python3 -c "import sys,json; print(json.load(sys.stdin)['experiment']['experiment_id'])" 2>/dev/null || echo "")
          if [[ -n "$found_id" ]]; then
            exp_id="$found_id"
          fi
        fi
        info "  Using experiment ID: ${exp_id}"

        local sa_token
        sa_token=$(oc create token "${sa_name}" -n "${NS}" --duration=8760h)
        oc create secret generic "${secret_name}" -n "${NS}" \
          --from-literal=header="Authorization=Bearer ${sa_token},X-MLflow-Workspace=${NS},X-MLflow-Experiment-Id=${exp_id}"
        ok "Secret '${secret_name}' created"
      fi
    fi

    # Step 3.3 — Ensure OPENAI_API_KEY secret exists
    local api_key_secret="nemoguardrails-api-key"
    info "Step 3.3 — Checking OPENAI_API_KEY secret..."
    if oc get secret "${api_key_secret}" -n "${NS}" &>/dev/null; then
      ok "Secret '${api_key_secret}' already exists"
    else
      # Try to read the current OPENAI_API_KEY from the CR or deployment
      local current_key
      current_key=$(oc get nemoguardrails "${ngr_name}" -n "${NS}" \
        -o jsonpath='{.spec.env[?(@.name=="OPENAI_API_KEY")].value}' 2>/dev/null || echo "")
      if [[ -z "$current_key" ]]; then
        current_key=$(oc get deployment "${deploy_name}" -n "${NS}" \
          -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OPENAI_API_KEY")].value}' 2>/dev/null || echo "")
      fi
      if [[ -n "$current_key" ]]; then
        info "  Migrating OPENAI_API_KEY to secret..."
        run "oc create secret generic ${api_key_secret} -n ${NS} --from-literal=key='${current_key}'"
        ok "OPENAI_API_KEY migrated to secret '${api_key_secret}'"
      else
        warn "No OPENAI_API_KEY found. Set it manually:"
        warn "  oc create secret generic ${api_key_secret} -n ${NS} --from-literal=key=<YOUR_MAAS_API_KEY>"
      fi
    fi

    # Step 3.4 — Patch NemoGuardrails CR env vars (including PYTHONPATH for SDK init)
    info "Step 3.4 — Patching NemoGuardrails CR env vars..."
    #
    # KEY INSIGHT: Instead of wrapping the command with opentelemetry-instrument
    # (which the operator reverts), we set PYTHONPATH to the auto-instrumentation
    # sitecustomize directory. Python loads sitecustomize.py at startup, which
    # initializes the OTEL SDK — same effect, but operator-proof since it's an
    # env var in the CR, not a command override.
    #
    local otel_sitecustomize="/app/.venv/lib64/python3.12/site-packages/opentelemetry/instrumentation/auto_instrumentation"
    run "oc patch nemoguardrails ${ngr_name} -n ${NS} --type json -p '[
  {\"op\": \"replace\", \"path\": \"/spec/env\", \"value\": [
    {\"name\": \"OPENAI_API_KEY\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"${api_key_secret}\", \"key\": \"key\"}}},
    {\"name\": \"PYTHONPATH\", \"value\": \"${otel_sitecustomize}\"},
    {\"name\": \"OTEL_SERVICE_NAME\", \"value\": \"nemoguardrails\"},
    {\"name\": \"OTEL_EXPORTER_OTLP_ENDPOINT\", \"value\": \"${MLFLOW_ENDPOINT}\"},
    {\"name\": \"OTEL_EXPORTER_OTLP_PROTOCOL\", \"value\": \"http/protobuf\"},
    {\"name\": \"OTEL_EXPORTER_OTLP_HEADERS\", \"valueFrom\": {\"secretKeyRef\": {\"name\": \"nemoguardrails-otel-auth\", \"key\": \"header\"}}},
    {\"name\": \"OTEL_EXPORTER_OTLP_CERTIFICATE\", \"value\": \"${NGR_CERT_PATH}\"},
    {\"name\": \"OTEL_TRACES_EXPORTER\", \"value\": \"otlp\"},
    {\"name\": \"OTEL_METRICS_EXPORTER\", \"value\": \"none\"},
    {\"name\": \"OTEL_LOGS_EXPORTER\", \"value\": \"none\"},
    {\"name\": \"OTEL_PYTHON_DISABLED_INSTRUMENTATIONS\", \"value\": \"${NGR_DISABLED_INSTRUMENTORS}\"}
  ]}
]'"
    ok "NemoGuardrails CR env patched (with PYTHONPATH for auto-instrumentation)"
  fi

  # Step 3.5 — (No longer needed: PYTHONPATH replaces the command wrapper)
  # The PYTHONPATH env var in step 3.4 initializes the OTEL SDK at Python
  # startup via sitecustomize.py — no command override required.
  # This is operator-proof: the env var is set in the CR, so the operator
  # cannot revert it.

  # Step 3.6 — Update guardrail config to enable tracing
  info "Step 3.6 — Enabling tracing in guardrail config..."
  local config_yaml
  config_yaml=$(oc get configmap guardrail-placeholder -n "${NS}" \
    -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")
  if echo "$config_yaml" | grep -q 'tracing:'; then
    ok "Tracing already enabled in guardrail config — skipping"
  else
    if [[ -n "$config_yaml" ]]; then
      if $DRY_RUN; then
        dry "Append tracing section to guardrail-placeholder ConfigMap config.yaml"
      else
        # Build the patched config in a temp file to avoid shell quoting issues
        local tmpfile
        tmpfile=$(mktemp)
        trap "rm -f '$tmpfile'" EXIT
        oc get configmap guardrail-placeholder -n "${NS}" -o json \
          | python3 -c "
import sys, json
cm = json.load(sys.stdin)
cfg = cm['data'].get('config.yaml', '')
cfg += '''
tracing:
  enabled: true
  enable_content_capture: true
  adapters:
    - name: OpenTelemetry
'''
cm['data']['config.yaml'] = cfg
json.dump(cm, sys.stdout)
" > "$tmpfile"
        oc apply -f "$tmpfile" -n "${NS}"
        rm -f "$tmpfile"
        ok "Tracing enabled in guardrail config"
      fi
    else
      warn "ConfigMap guardrail-placeholder not found or empty. Add tracing config manually."
    fi
  fi

  # Step 3.7 — Wait for rollout
  info "Step 3.7 — Waiting for NemoGuardrails rollout..."
  if ! $DRY_RUN; then
    oc rollout status deployment/"${deploy_name}" -n "${NS}" --timeout=120s 2>/dev/null || true
  else
    dry "oc rollout status deployment/${deploy_name} -n ${NS} --timeout=120s"
  fi
  ok "NemoGuardrails deployment rolled out"

  echo ""
  ok "Phase 3 complete: NemoGuardrails tracing configured"
}

# ======================================================================
#  Main
# ======================================================================
main() {
  echo ""
  info "╔═══════════════════════════════════════════════════════════════╗"
  info "║  MLflow Tracing Setup for RHOAI GenAI Studio                 ║"
  info "╚═══════════════════════════════════════════════════════════════╝"
  echo ""

  if ! $SKIP_MLFLOW; then
    phase1_mlflow
  else
    info "Skipping Phase 1 (MLflow setup) — --skip-mlflow"
  fi

  if ! $SKIP_PLAYGROUND; then
    phase2_playground
  else
    info "Skipping Phase 2 (Playground tracing) — --skip-playground"
  fi

  if ! $SKIP_GUARDRAILS; then
    phase3_guardrails
  else
    info "Skipping Phase 3 (NemoGuardrails tracing) — --skip-guardrails"
  fi

  echo ""
  info "═══════════════════════════════════════════════════════════════"
  ok "Setup complete!"
  echo ""
  info "View traces in MLflow:"
  info "  RHOAI Dashboard → MLflow → '${EXPERIMENT_NAME}' experiment → Traces"
  echo ""
  info "Send a prompt in the Playground, then check MLflow for the trace."
  info "It may take a few seconds for traces to appear after a prompt."
}

main
