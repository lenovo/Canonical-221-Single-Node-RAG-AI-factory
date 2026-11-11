#!/usr/bin/env bash
# ============================================================================
# DEPLOY APPS - NVIDIA RAG Blueprint + NIM Inference Stack
# ============================================================================
# Lenovo ThinkSystem SR650a V4 - GPU Inference Server
# 2x NVIDIA RTX PRO 6000 Blackwell (96GB each)
#
# This script deploys the NVAIE application layer on top of the infrastructure
# provisioned by setup_infra.sh:
#   1. Validate prerequisites (K8s, GPU Operator, OpenSearch bridge)
#   2. Prompt for NGC credentials (or read from env/file)
#   3. Build custom RAG server images with buildah (OpenSearch VDB support)
#   4. Build Helm chart dependencies
#   5. Deploy NIM Operator
#   6. Deploy the full RAG Blueprint stack via Helm
#   7. Deploy Triton Inference Server (general ML)
#   8. Wait for services to become ready
#
# Usage:
#   sudo bash deploy_apps.sh
#   sudo bash deploy_apps.sh --upgrade    # Upgrade existing deployment
#   sudo bash deploy_apps.sh --dry-run    # Template only, don't deploy
#   sudo bash deploy_apps.sh --uninstall  # Remove the deployment
#
# Prerequisites:
#   - setup_infra.sh has completed successfully
#   - NGC API key with access to nvcr.io NIM containers
#
# The script is idempotent. Re-running it will detect existing deployments
# and offer to upgrade.
# ============================================================================

set -euo pipefail

# Ensure /snap/bin is in PATH for Canonical K8s
export PATH="/snap/bin:${PATH}"

# ============================================================================
# Error Trap
# ============================================================================
on_error() {
    local exit_code=$?
    local line_no=$1
    local command="$2"
    echo "" >&2
    echo "========================================" >&2
    echo "  FATAL: Script failed at line ${line_no} (exit code ${exit_code})" >&2
    echo "  Command: ${command}" >&2
    echo "  Check the full log: ${LOGFILE}" >&2
    echo "========================================" >&2
    if [[ -n "${LOGFILE:-}" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] FATAL at line ${line_no}: ${command}" >> "$LOGFILE" 2>/dev/null || true
    fi
}
trap 'on_error ${LINENO} "${BASH_COMMAND}"' ERR

# ============================================================================
# Configuration
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared infrastructure config
CONFIG_FILE="${SCRIPT_DIR}/config_infra.env"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=config_infra.env
    source "$CONFIG_FILE"
else
    echo "ERROR: config_infra.env not found at ${CONFIG_FILE}" >&2
    exit 1
fi

CHART_DIR="${SCRIPT_DIR}/rag_blueprint_lenovo/deploy/helm/nvidia-blueprint-rag"
LOGFILE="/var/log/lenovo-apps-deploy.log"

# Helm release/namespace settings
HELM_RELEASE="rag"
HELM_NAMESPACE="${K8S_NAMESPACE_RAG:-rag}"

# Credential store (shared with setup_infra.sh)
CREDENTIAL_STORE="${CREDENTIAL_STORE:-/root/.credentials/lenovo-rag}"

# ============================================================================
# Argument Parsing
# ============================================================================
ACTION="install"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --upgrade)
            ACTION="upgrade"
            shift
            ;;
        --dry-run)
            ACTION="dry-run"
            shift
            ;;
        --uninstall)
            ACTION="uninstall"
            shift
            ;;
        --help|-h)
            echo "Usage: sudo bash deploy_apps.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --upgrade    Upgrade an existing deployment instead of installing"
            echo "  --dry-run    Render templates only (helm template), don't deploy"
            echo "  --uninstall  Remove the RAG Blueprint deployment"
            echo "  --help       Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
done

# ============================================================================
# Logging
# ============================================================================
mkdir -p "$(dirname "$LOGFILE")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"; }
log_step() {
    echo -e "\n========================================" >> "$LOGFILE"
    log "STEP: $1"
    echo "========================================" >> "$LOGFILE"
    echo ""
    echo "  Step $1"
}
log_ok() { log "[OK] $1"; }
log_warn() { log "[WARN] $1"; }
log_err() { log "[ERROR] $1"; }

echo ""
echo "========================================================================"
echo "  Lenovo RAG Blueprint Deployment"
echo "========================================================================"
echo "  Chart:     ${CHART_DIR}"
echo "  Release:   ${HELM_RELEASE}"
echo "  Namespace: ${HELM_NAMESPACE}"
echo "  Action:    ${ACTION}"
echo "  Log:       ${LOGFILE}"
echo "========================================================================"
echo ""

# ============================================================================
# Pre-flight Checks
# ============================================================================
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    echo "Usage: sudo bash deploy_apps.sh"
    exit 1
fi

# ============================================================================
# Phase 1: Validate Prerequisites
# ============================================================================
log_step "1 - Validate Prerequisites"

# Check Kubernetes
if ! command -v k8s &>/dev/null || ! k8s status &>/dev/null 2>&1; then
    echo "ERROR: Canonical Kubernetes is not running."
    echo "Run setup_infra.sh first to provision the infrastructure."
    exit 1
fi
log_ok "Kubernetes is running."

# Set up KUBECONFIG
export KUBECONFIG=/tmp/kubeconfig
if [[ ! -f "$KUBECONFIG" ]]; then
    k8s config > "$KUBECONFIG"
fi

# Check Helm
if ! command -v helm &>/dev/null; then
    echo "ERROR: Helm is not installed."
    echo "Run setup_infra.sh first to provision the infrastructure."
    exit 1
fi
log_ok "Helm is available."

# Check chart directory exists
if [[ ! -f "${CHART_DIR}/Chart.yaml" ]]; then
    echo "ERROR: Helm chart not found at ${CHART_DIR}"
    echo "Expected Chart.yaml at: ${CHART_DIR}/Chart.yaml"
    exit 1
fi
log_ok "Helm chart found at ${CHART_DIR}."

# Check GPU resources are visible (warning only — pods will pend if not ready)
GPU_RESOURCES=$(k8s kubectl get nodes -o json 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); [print(f'  {k}: {v}') for n in d['items'] for k,v in n.get('status',{}).get('allocatable',{}).items() if k.startswith('nvidia')]" 2>/dev/null || true)
if [[ -n "$GPU_RESOURCES" ]]; then
    log_ok "GPU resources visible in Kubernetes:"
    echo "$GPU_RESOURCES" >> "$LOGFILE"
    echo "  GPU resources detected:"
    echo "$GPU_RESOURCES"
else
    log_warn "No NVIDIA GPU resources detected in Kubernetes."
    echo "  WARNING: No GPU resources detected. GPU pods will remain Pending."
    echo "  Ensure GPU Operator is running (check: k8s kubectl get pods -n gpu-operator)"
fi

# Verify GPU Operator ClusterPolicy is correctly configured:
#   - CDI disabled (Canonical K8s 1.32 ships containerd v1.6 which lacks CDI support)
#   - CONTAINERD_SET_DEFAULT_RUNTIME=true (nvidia is the default containerd handler)
if k8s kubectl get clusterpolicy cluster-policy &>/dev/null 2>&1; then
    # Check CDI is disabled
    CP_CDI=$(k8s kubectl get clusterpolicy cluster-policy \
        -o jsonpath='{.spec.cdi.enabled}' 2>/dev/null || true)
    if [[ "$CP_CDI" == "true" ]]; then
        log_warn "ClusterPolicy has CDI ENABLED — incompatible with containerd v1.6."
        echo "  WARNING: CDI is enabled but Canonical K8s uses containerd v1.6 (no CDI support)."
        echo "  GPU pods will fail. Fix: re-run setup_infra.sh, or manually patch:"
        echo "    k8s kubectl patch clusterpolicy cluster-policy --type='json' \\"
        echo "      -p='[{\"op\":\"replace\",\"path\":\"/spec/cdi/enabled\",\"value\":false}]'"
    else
        log_ok "ClusterPolicy CDI is disabled (correct for containerd v1.6)."
    fi

    # Check default runtime
    CP_TOOLKIT_ENV=$(k8s kubectl get clusterpolicy cluster-policy \
        -o jsonpath='{.spec.toolkit.env}' 2>/dev/null || true)
    if echo "$CP_TOOLKIT_ENV" | grep -q "CONTAINERD_SET_DEFAULT_RUNTIME"; then
        log_ok "ClusterPolicy has CONTAINERD_SET_DEFAULT_RUNTIME=true."
    else
        log_warn "ClusterPolicy is MISSING CONTAINERD_SET_DEFAULT_RUNTIME=true."
        echo "  WARNING: CONTAINERD_SET_DEFAULT_RUNTIME is not set on ClusterPolicy."
        echo "  NIM pods will crash with 'NVIDIA Driver not detected'."
        echo "  Fix: re-run setup_infra.sh, or manually patch:"
        echo "    k8s kubectl patch clusterpolicy cluster-policy --type='json' \\"
        echo "      -p='[{\"op\":\"add\",\"path\":\"/spec/toolkit/env/-\",\"value\":{\"name\":\"CONTAINERD_SET_DEFAULT_RUNTIME\",\"value\":\"true\"}}]'"
    fi
fi

# Check OpenSearch bridge service exists in the target namespace
if k8s kubectl get svc opensearch -n "${HELM_NAMESPACE}" &>/dev/null 2>&1; then
    log_ok "OpenSearch bridge service exists in '${HELM_NAMESPACE}' namespace."
else
    log_warn "OpenSearch bridge service not found in '${HELM_NAMESPACE}' namespace."
    echo "  WARNING: OpenSearch bridge service not found in '${HELM_NAMESPACE}' namespace."
    echo "  The RAG server will not be able to connect to OpenSearch."
    echo "  Ensure setup_infra.sh was run and K8S_NAMESPACE_RAG=${HELM_NAMESPACE}."
fi

log_ok "Phase 1 complete."

# ============================================================================
# Phase 2: NGC Credentials
# ============================================================================
log_step "2 - NGC Credentials"

# Handle uninstall early — no credentials needed
if [[ "$ACTION" == "uninstall" ]]; then
    log "Uninstall requested — skipping credential setup."
    echo "  Uninstalling ${HELM_RELEASE}..."
    if helm list -n "${HELM_NAMESPACE}" 2>/dev/null | grep -q "${HELM_RELEASE}"; then
        helm uninstall "${HELM_RELEASE}" -n "${HELM_NAMESPACE}" >> "$LOGFILE" 2>&1
        echo "  Release '${HELM_RELEASE}' uninstalled."
        log_ok "Release uninstalled."
    else
        echo "  Release '${HELM_RELEASE}' not found. Nothing to uninstall."
    fi
    exit 0
fi

# Try to get NGC API key from (in priority order):
# 1. NGC_API_KEY environment variable
# 2. Credential store file
# 3. Interactive prompt
NGC_API_KEY="${NGC_API_KEY:-}"

if [[ -z "$NGC_API_KEY" ]] && [[ -f "${CREDENTIAL_STORE}/ngc_api_key" ]]; then
    NGC_API_KEY="$(cat "${CREDENTIAL_STORE}/ngc_api_key")"
    log "NGC API key loaded from credential store."
fi

if [[ -z "$NGC_API_KEY" ]]; then
    echo "  NGC API key is required to pull NIM container images."
    echo "  Get one at: https://org.ngc.nvidia.com/setup"
    echo ""
    read -rsp "  Enter NGC API key: " NGC_API_KEY
    echo ""

    if [[ -z "$NGC_API_KEY" ]]; then
        echo "ERROR: NGC API key cannot be empty."
        exit 1
    fi

    # Save for future runs
    mkdir -p "$CREDENTIAL_STORE"
    chmod 700 "$CREDENTIAL_STORE"
    echo -n "$NGC_API_KEY" > "${CREDENTIAL_STORE}/ngc_api_key"
    chmod 600 "${CREDENTIAL_STORE}/ngc_api_key"
    log_ok "NGC API key saved to credential store."
fi

# Validate the key format (basic check — NGC keys are typically nvapi-*)
if [[ "$NGC_API_KEY" != nvapi-* ]] && [[ "$NGC_API_KEY" != "dGhpcyBpcyBhIHRlc3Q"* ]]; then
    log_warn "NGC API key does not start with 'nvapi-'. Proceeding anyway."
    echo "  WARNING: NGC API key format looks unusual (expected 'nvapi-...'). Proceeding."
fi

log_ok "NGC API key configured."

# ============================================================================
# Phase 3: Build Custom RAG Server Images (OpenSearch support)
# ============================================================================
log_step "3 - Build Custom RAG Server Images (OpenSearch support)"

# The stock NVIDIA images don't include the OpenSearch VDB module.
# We build custom images on the target machine using buildah (daemonless),
# export them as docker-archive tarballs, and import into the Canonical K8s
# containerd image store (k8s.io namespace).
#
# Build context = the blueprint repo root (contains uv.lock, pyproject.toml, src/, etc.)
# Dockerfiles use multi-stage builds pulling from:
#   - nvcr.io/nvidia/base/ubuntu:jammy-20251013 (requires NGC auth)
#   - ghcr.io/astral-sh/uv:0.7.4 / 0.8.12 (public, no auth)
#
# Canonical K8s ctr binary is at /snap/k8s/current/bin/ctr (not `k8s ctr`).
CTR="/snap/k8s/current/bin/ctr"
CTR_ARGS="--address /run/containerd/containerd.sock --namespace k8s.io"

RAG_IMAGE="lenovo/rag-server:2.5.0-opensearch"
INGESTOR_IMAGE="lenovo/ingestor-server:2.5.0-opensearch"

# Build context is the blueprint repo root
BUILD_CONTEXT="${SCRIPT_DIR}/rag_blueprint_lenovo"
RAG_DOCKERFILE="${BUILD_CONTEXT}/src/nvidia_rag/rag_server/Dockerfile"
INGESTOR_DOCKERFILE="${BUILD_CONTEXT}/src/nvidia_rag/ingestor_server/Dockerfile"

# Temporary directory for intermediate tarballs
BUILD_TMPDIR="${SCRIPT_DIR}/.build-tmp"

# Build args for the NVIDIA base image (requires NGC auth)
BUILD_ARGS=(
    --build-arg "BASE_IMAGE_URL=nvcr.io/nvidia/base/ubuntu"
    --build-arg "BASE_IMAGE_TAG=jammy-20251013"
)

# --- Check if images already exist in containerd ---
RAG_IMG_EXISTS=$($CTR $CTR_ARGS images list -q 2>/dev/null | grep -c "docker.io/${RAG_IMAGE}" || true)
INGESTOR_IMG_EXISTS=$($CTR $CTR_ARGS images list -q 2>/dev/null | grep -c "docker.io/${INGESTOR_IMAGE}" || true)

if [[ "$RAG_IMG_EXISTS" -gt 0 ]] && [[ "$INGESTOR_IMG_EXISTS" -gt 0 ]]; then
    log_ok "Custom images already present in containerd image store."
    echo "  Custom images found in containerd — skipping build."
    echo "    ${RAG_IMAGE}"
    echo "    ${INGESTOR_IMAGE}"
    echo "  To force a rebuild, first remove the images:"
    echo "    $CTR $CTR_ARGS images rm docker.io/${RAG_IMAGE}"
    echo "    $CTR $CTR_ARGS images rm docker.io/${INGESTOR_IMAGE}"
else
    # --- Verify buildah is available ---
    if ! command -v buildah &>/dev/null; then
        echo "  buildah not found. Installing..."
        apt-get update -qq >> "$LOGFILE" 2>&1
        apt-get install -y -qq buildah >> "$LOGFILE" 2>&1
        if ! command -v buildah &>/dev/null; then
            echo "ERROR: Failed to install buildah. Install it manually and re-run."
            exit 1
        fi
        log_ok "buildah installed."
    fi
    echo "  Using buildah $(buildah --version | head -1)"

    # --- Verify Dockerfiles and build context exist ---
    if [[ ! -f "$RAG_DOCKERFILE" ]]; then
        echo "ERROR: rag-server Dockerfile not found at ${RAG_DOCKERFILE}"
        exit 1
    fi
    if [[ ! -f "$INGESTOR_DOCKERFILE" ]]; then
        echo "ERROR: ingestor-server Dockerfile not found at ${INGESTOR_DOCKERFILE}"
        exit 1
    fi
    if [[ ! -f "${BUILD_CONTEXT}/pyproject.toml" ]]; then
        echo "ERROR: Build context missing pyproject.toml at ${BUILD_CONTEXT}/"
        exit 1
    fi

    # --- Login to NGC registry for base image pulls ---
    echo "  Logging into nvcr.io for base image access..."
    if ! echo "$NGC_API_KEY" | buildah login --username '$oauthtoken' --password-stdin nvcr.io >> "$LOGFILE" 2>&1; then
        echo "ERROR: Failed to authenticate with nvcr.io. Check your NGC API key."
        log_err "buildah login to nvcr.io failed."
        exit 1
    fi
    log_ok "Authenticated with nvcr.io."

    mkdir -p "$BUILD_TMPDIR"

    # --- Build rag-server ---
    if [[ "$RAG_IMG_EXISTS" -gt 0 ]]; then
        echo "  rag-server image already in containerd — skipping."
    else
        echo ""
        echo "  Building rag-server image (this may take 10-20 minutes on first build)..."
        echo "    Dockerfile: ${RAG_DOCKERFILE}"
        echo "    Context:    ${BUILD_CONTEXT}"
        log "Building ${RAG_IMAGE} from ${RAG_DOCKERFILE}"

        if ! buildah bud --format docker \
            "${BUILD_ARGS[@]}" \
            -f "$RAG_DOCKERFILE" \
            -t "$RAG_IMAGE" \
            "$BUILD_CONTEXT" >> "$LOGFILE" 2>&1; then
            echo "  ERROR: Failed to build rag-server image. Check ${LOGFILE}" >&2
            log_err "buildah bud failed for ${RAG_IMAGE}"
            exit 1
        fi
        log_ok "rag-server image built successfully."

        echo "  Exporting and importing rag-server into containerd..."
        RAG_TAR="${BUILD_TMPDIR}/rag-server.tar"
        if ! buildah push "$RAG_IMAGE" "docker-archive:${RAG_TAR}:${RAG_IMAGE}" >> "$LOGFILE" 2>&1; then
            echo "  ERROR: Failed to export rag-server image. Check ${LOGFILE}" >&2
            log_err "buildah push (docker-archive) failed for ${RAG_IMAGE}"
            exit 1
        fi
        if ! $CTR $CTR_ARGS images import "$RAG_TAR" >> "$LOGFILE" 2>&1; then
            echo "  ERROR: Failed to import rag-server image into containerd. Check ${LOGFILE}" >&2
            log_err "ctr images import failed for ${RAG_IMAGE}"
            exit 1
        fi
        rm -f "$RAG_TAR"
        log_ok "rag-server image imported into containerd."
        echo "    ${RAG_IMAGE} — done."
    fi

    # --- Build ingestor-server ---
    if [[ "$INGESTOR_IMG_EXISTS" -gt 0 ]]; then
        echo "  ingestor-server image already in containerd — skipping."
    else
        echo ""
        echo "  Building ingestor-server image (this may take 10-20 minutes on first build)..."
        echo "    Dockerfile: ${INGESTOR_DOCKERFILE}"
        echo "    Context:    ${BUILD_CONTEXT}"
        log "Building ${INGESTOR_IMAGE} from ${INGESTOR_DOCKERFILE}"

        if ! buildah bud --format docker \
            "${BUILD_ARGS[@]}" \
            -f "$INGESTOR_DOCKERFILE" \
            -t "$INGESTOR_IMAGE" \
            "$BUILD_CONTEXT" >> "$LOGFILE" 2>&1; then
            echo "  ERROR: Failed to build ingestor-server image. Check ${LOGFILE}" >&2
            log_err "buildah bud failed for ${INGESTOR_IMAGE}"
            exit 1
        fi
        log_ok "ingestor-server image built successfully."

        echo "  Exporting and importing ingestor-server into containerd..."
        INGESTOR_TAR="${BUILD_TMPDIR}/ingestor-server.tar"
        if ! buildah push "$INGESTOR_IMAGE" "docker-archive:${INGESTOR_TAR}:${INGESTOR_IMAGE}" >> "$LOGFILE" 2>&1; then
            echo "  ERROR: Failed to export ingestor-server image. Check ${LOGFILE}" >&2
            log_err "buildah push (docker-archive) failed for ${INGESTOR_IMAGE}"
            exit 1
        fi
        if ! $CTR $CTR_ARGS images import "$INGESTOR_TAR" >> "$LOGFILE" 2>&1; then
            echo "  ERROR: Failed to import ingestor-server image into containerd. Check ${LOGFILE}" >&2
            log_err "ctr images import failed for ${INGESTOR_IMAGE}"
            exit 1
        fi
        rm -f "$INGESTOR_TAR"
        log_ok "ingestor-server image imported into containerd."
        echo "    ${INGESTOR_IMAGE} — done."
    fi

    # Cleanup buildah local storage (the images are in containerd now)
    buildah rm --all >> "$LOGFILE" 2>&1 || true
    rmdir "$BUILD_TMPDIR" 2>/dev/null || true

    echo ""
    echo "  Custom images built and imported:"
    echo "    ${RAG_IMAGE}"
    echo "    ${INGESTOR_IMAGE}"
fi

log_ok "Phase 3 complete."

# ============================================================================
# Phase 4: Build Helm Dependencies
# ============================================================================
log_step "4 - Build Helm Dependencies"

echo "  Adding Helm repositories..."
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia \
    --username '$oauthtoken' --password "$NGC_API_KEY" >> "$LOGFILE" 2>&1 || true
helm repo add nvidia-nemo https://helm.ngc.nvidia.com/nvidia/nemo-microservices \
    --username '$oauthtoken' --password "$NGC_API_KEY" >> "$LOGFILE" 2>&1 || true
helm repo add elastic https://helm.elastic.co >> "$LOGFILE" 2>&1 || true
helm repo add zipkin https://zipkin.io/zipkin-helm >> "$LOGFILE" 2>&1 || true
helm repo add otel https://open-telemetry.github.io/opentelemetry-helm-charts >> "$LOGFILE" 2>&1 || true
helm repo add prometheus https://prometheus-community.github.io/helm-charts >> "$LOGFILE" 2>&1 || true
helm repo update >> "$LOGFILE" 2>&1
log_ok "Helm repositories configured."

echo "  Building chart dependencies (this may take a few minutes)..."
helm dependency build "${CHART_DIR}" >> "$LOGFILE" 2>&1
log_ok "Helm dependencies built."
log_ok "Phase 4 complete."

# ============================================================================
# Phase 5: NIM Operator
# ============================================================================
log_step "5 - NIM Operator"

# The RAG Blueprint NIM templates require the NIM Operator CRDs
# (apps.nvidia.com/v1alpha1: NIMCache, NIMService). Without them,
# Helm silently skips all NIM resources and no inference pods are created.
NIM_OP_RELEASE="nim-operator"
NIM_OP_NAMESPACE="nim-operator"

if k8s kubectl get crd nimcaches.apps.nvidia.com &>/dev/null 2>&1; then
    log_ok "NIM Operator CRDs already registered."
    echo "  NIM Operator CRDs found — skipping install."

    # Ensure the operator pods are actually running
    NIM_OP_RUNNING=$(k8s kubectl get pods -n "${NIM_OP_NAMESPACE}" --no-headers 2>/dev/null | grep -c "Running" || true)
    if [[ "$NIM_OP_RUNNING" -gt 0 ]]; then
        log_ok "NIM Operator is running (${NIM_OP_RUNNING} pod(s))."
    else
        log_warn "NIM Operator CRDs exist but no running pods found in '${NIM_OP_NAMESPACE}'."
        echo "  WARNING: NIM Operator pods not running. NIM resources may not reconcile."
    fi
else
    echo "  Installing NIM Operator..."
    log "Installing NIM Operator (${NIM_OP_RELEASE}) into namespace ${NIM_OP_NAMESPACE}."

    # Create the imagePullSecret in the NIM Operator namespace so it can pull NIM images
    k8s kubectl create namespace "${NIM_OP_NAMESPACE}" --dry-run=client -o yaml | \
        k8s kubectl apply -f - >> "$LOGFILE" 2>&1

    helm upgrade --install "${NIM_OP_RELEASE}" nvidia/k8s-nim-operator \
        -n "${NIM_OP_NAMESPACE}" --create-namespace \
        --set operator.image.pullSecrets[0].name=ngc-secret \
        >> "$LOGFILE" 2>&1

    log_ok "NIM Operator Helm release installed."

    # Wait for CRDs to become available
    echo "  Waiting for NIM Operator CRDs to register..."
    RETRIES=0
    MAX_RETRIES=30
    while ! k8s kubectl get crd nimcaches.apps.nvidia.com &>/dev/null 2>&1; do
        RETRIES=$((RETRIES + 1))
        if [[ $RETRIES -ge $MAX_RETRIES ]]; then
            echo "  ERROR: NIM Operator CRDs did not register within ${MAX_RETRIES}0 seconds."
            echo "  Check: k8s kubectl get pods -n ${NIM_OP_NAMESPACE}"
            echo "  Logs:  k8s kubectl logs -n ${NIM_OP_NAMESPACE} -l app.kubernetes.io/name=k8s-nim-operator"
            log_err "NIM Operator CRD registration timed out."
            exit 1
        fi
        sleep 10
    done
    log_ok "NIM Operator CRDs registered."

    # Wait for operator pod to be ready
    echo "  Waiting for NIM Operator pod to be ready..."
    k8s kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=k8s-nim-operator \
        -n "${NIM_OP_NAMESPACE}" \
        --timeout=120s >> "$LOGFILE" 2>&1 || {
        log_warn "NIM Operator pod not ready after 120s. Continuing — it may still be starting."
        echo "  WARNING: NIM Operator pod not fully ready yet. Continuing deployment."
    }

    log_ok "NIM Operator installed and ready."
fi

# ============================================================================
# Phase 6: Deploy RAG Blueprint
# ============================================================================
log_step "6 - Deploy RAG Blueprint"

# Common Helm --set flags for secrets
# Load OpenSearch admin password from credential store (generated by setup_infra.sh)
OPENSEARCH_ADMIN_PASSWORD=""
if [[ -f "${CREDENTIAL_STORE}/opensearch_admin_password" ]]; then
    OPENSEARCH_ADMIN_PASSWORD="$(cat "${CREDENTIAL_STORE}/opensearch_admin_password")"
    log_ok "OpenSearch admin password loaded from credential store."
else
    log_warn "OpenSearch admin password not found in credential store."
    echo "  WARNING: OpenSearch credentials not found at ${CREDENTIAL_STORE}/opensearch_admin_password"
    echo "  RAG server may fail to connect to OpenSearch. Ensure setup_infra.sh was run first."
fi

HELM_SET_FLAGS=(
    --set "imagePullSecret.password=${NGC_API_KEY}"
    --set "ngcApiSecret.password=${NGC_API_KEY}"
)

# Inject OpenSearch credentials into both rag-server and ingestor-server env vars
if [[ -n "$OPENSEARCH_ADMIN_PASSWORD" ]]; then
    HELM_SET_FLAGS+=(
        --set "envVars.APP_VECTORSTORE_PASSWORD=${OPENSEARCH_ADMIN_PASSWORD}"
        --set "ingestor-server.envVars.APP_VECTORSTORE_PASSWORD=${OPENSEARCH_ADMIN_PASSWORD}"
    )
    log_ok "OpenSearch credentials injected into Helm values."
fi

# Check if release already exists
EXISTING_RELEASE=$(helm list -n "${HELM_NAMESPACE}" -q 2>/dev/null | grep "^${HELM_RELEASE}$" || true)

case "$ACTION" in
    dry-run)
        echo "  Rendering templates (dry-run)..."
        helm template "${HELM_RELEASE}" "${CHART_DIR}" \
            -n "${HELM_NAMESPACE}" \
            "${HELM_SET_FLAGS[@]}" \
            >> "$LOGFILE" 2>&1
        echo "  Templates rendered successfully. Check ${LOGFILE} for output."
        log_ok "Dry-run complete."
        exit 0
        ;;

    upgrade)
        if [[ -z "$EXISTING_RELEASE" ]]; then
            echo "  No existing release found. Performing install instead."
            log_warn "No existing release '${HELM_RELEASE}' found. Installing."
        fi
        echo "  Upgrading (or installing) ${HELM_RELEASE}..."
        helm upgrade --install "${HELM_RELEASE}" "${CHART_DIR}" \
            -n "${HELM_NAMESPACE}" --create-namespace \
            "${HELM_SET_FLAGS[@]}" \
            --timeout 30m \
            --wait=false \
            >> "$LOGFILE" 2>&1
        log_ok "Helm upgrade --install complete."
        ;;

    install)
        if [[ -n "$EXISTING_RELEASE" ]]; then
            echo "  Release '${HELM_RELEASE}' already exists."
            echo "  Use --upgrade to update, or --uninstall to remove first."
            echo ""
            read -rp "  Proceed with upgrade? [y/N]: " CONFIRM
            if [[ "${CONFIRM,,}" != "y" ]]; then
                echo "  Skipping RAG Blueprint upgrade."
                log "User declined RAG Blueprint upgrade — skipping Phase 6."
            else
                echo "  Upgrading ${HELM_RELEASE}..."
                helm upgrade "${HELM_RELEASE}" "${CHART_DIR}" \
                    -n "${HELM_NAMESPACE}" --create-namespace \
                    "${HELM_SET_FLAGS[@]}" \
                    --timeout 30m \
                    --wait=false \
                    >> "$LOGFILE" 2>&1
                log_ok "Helm upgrade complete."
            fi
        else
            echo "  Installing ${HELM_RELEASE}..."
            helm install "${HELM_RELEASE}" "${CHART_DIR}" \
                -n "${HELM_NAMESPACE}" --create-namespace \
                "${HELM_SET_FLAGS[@]}" \
                --timeout 30m \
                --wait=false \
                >> "$LOGFILE" 2>&1
            log_ok "Helm install complete."
        fi
        ;;
esac

# ============================================================================
# Phase 7: Deploy Triton Inference Server
# ============================================================================
log_step "7 - Deploy Triton Inference Server"

TRITON_NAMESPACE="triton"
TRITON_MANIFEST="${SCRIPT_DIR}/triton/triton-server.yaml"

if [[ ! -f "$TRITON_MANIFEST" ]]; then
    echo "  WARNING: Triton manifest not found at ${TRITON_MANIFEST}. Skipping."
    log_warn "Triton manifest not found — skipping Triton deployment."
else
    # Create namespace and NGC imagePullSecret for Triton
    k8s kubectl create namespace "${TRITON_NAMESPACE}" --dry-run=client -o yaml | \
        k8s kubectl apply -f - >> "$LOGFILE" 2>&1

    # Ensure NGC imagePullSecret exists in the Triton namespace
    if ! k8s kubectl get secret ngc-secret -n "${TRITON_NAMESPACE}" &>/dev/null; then
        echo "  Creating NGC imagePullSecret in '${TRITON_NAMESPACE}' namespace..."
        k8s kubectl create secret docker-registry ngc-secret \
            -n "${TRITON_NAMESPACE}" \
            --docker-server=nvcr.io \
            --docker-username='$oauthtoken' \
            --docker-password="${NGC_API_KEY}" \
            >> "$LOGFILE" 2>&1
        log_ok "NGC imagePullSecret created in '${TRITON_NAMESPACE}' namespace."
    fi

    # Check if Triton is already deployed
    TRITON_EXISTS=$(k8s kubectl get deployment triton-inference-server -n "${TRITON_NAMESPACE}" --no-headers 2>/dev/null || true)
    TRITON_EXISTS=$(echo "$TRITON_EXISTS" | grep -c "triton" || true)

    if [[ "$TRITON_EXISTS" -gt 0 ]] && [[ "$ACTION" == "install" ]]; then
        echo "  Triton Inference Server already deployed — skipping."
        echo "  Use --upgrade to re-apply the manifest."
        log_ok "Triton already deployed."
    else
        echo "  Deploying Triton Inference Server (26.03)..."
        echo "    Namespace: ${TRITON_NAMESPACE}"
        echo "    Image:     nvcr.io/nvidia/tritonserver:26.03-py3"
        echo "    GPU:       nvidia.com/mig-2g.48gb: 1 (time-sliced 3x with OCR + Page Elements)"
        echo "    Models:    triton-model-repo PVC (50Gi) mounted at /models"

        k8s kubectl apply -n "${TRITON_NAMESPACE}" -f "$TRITON_MANIFEST" >> "$LOGFILE" 2>&1
        log_ok "Triton Inference Server manifest applied."

        echo "  Triton deployed. It will start once the container image is pulled."
        echo "  To add models, copy them into the triton-model-repo PVC:"
        echo "    k8s kubectl cp ./my-model ${TRITON_NAMESPACE}/triton-inference-server-<pod>:/models/my-model"
    fi
fi

log_ok "Phase 7 complete."

# ============================================================================
# Phase 8: Post-Deploy Status
# ============================================================================
log_step "8 - Post-Deploy Status"

echo ""
echo "  Waiting for pods to start (this may take 10-30 minutes for NIM model downloads)..."
echo ""

# Give K8s a moment to create the pods
sleep 10

# Show pod status
echo "  Current pod status (${HELM_NAMESPACE}):"
echo "  -------------------"
k8s kubectl get pods -n "${HELM_NAMESPACE}" -o wide 2>/dev/null | while IFS= read -r line; do
    echo "    $line"
done
echo ""

echo "  Current pod status (triton):"
echo "  -------------------"
k8s kubectl get pods -n triton -o wide 2>/dev/null | while IFS= read -r line; do
    echo "    $line"
done
echo ""

# Check for common issues
PENDING_PODS=$(k8s kubectl get pods -n "${HELM_NAMESPACE}" -n triton --field-selector=status.phase=Pending -o name 2>/dev/null | wc -l)
if [[ "$PENDING_PODS" -gt 0 ]]; then
    echo "  NOTE: ${PENDING_PODS} pod(s) are still Pending."
    echo "  This is normal during initial deployment — NIM images are large (10-40GB each)."
    echo "  Monitor progress:"
    echo "    k8s kubectl get pods -n ${HELM_NAMESPACE} -w"
    echo "    k8s kubectl get pods -n triton -w"
    echo "    k8s kubectl describe pod <pod-name> -n <namespace>"
fi

# Log all pod details
k8s kubectl get pods -n "${HELM_NAMESPACE}" -o wide >> "$LOGFILE" 2>&1
k8s kubectl get svc -n "${HELM_NAMESPACE}" >> "$LOGFILE" 2>&1
k8s kubectl get pods -n triton -o wide >> "$LOGFILE" 2>&1
k8s kubectl get svc -n triton >> "$LOGFILE" 2>&1

log_ok "Phase 8 complete."

# ============================================================================
# Summary
# ============================================================================

# Detect host IP
HOST_IP=$(ip -4 route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
HOST_IP="${HOST_IP:-localhost}"

cat <<SUMMARY

========================================================================
  RAG BLUEPRINT + TRITON DEPLOYED
========================================================================

  Release:    ${HELM_RELEASE}
  Namespace:  ${HELM_NAMESPACE}
  Chart:      ${CHART_DIR}

  Access:
    The frontend is exposed via LoadBalancer. Get the external IP:
      k8s kubectl get svc rag-frontend -n ${HELM_NAMESPACE}
    Then open: http://<EXTERNAL-IP>:3000

  Internal services (cluster-only):
    RAG Server:       rag-server:8081
    Ingestor Server:  ingestor-server:8082
    NIM LLM:          nim-llm:8000
    OpenSearch:       opensearch:9200  (bridge to bare-metal snap)
    Triton HTTP:      triton-inference-server:8000  (namespace: triton, KServe V2 / REST)
    Triton gRPC:      triton-inference-server:8001  (namespace: triton)
    Triton Metrics:   triton-inference-server:8002  (namespace: triton)

  GPU Layout:
    GPU 0: NIM LLM (Llama-3.3-Nemotron-Super-49B-v1.5, NVFP4, TP1) — nvidia.com/gpu: 1
    GPU 1: MIG 2x 1g.24gb + 1x 2g.48gb
      1g.24gb (2x TS): Embed, Rerank, Graphic Elements, Table Structure
      2g.48gb (3x TS): OCR, Page Elements, Triton Inference Server

  Vector Database: OpenSearch (bare-metal snap, via K8s Service+Endpoints bridge)

  Custom images (built with buildah, imported to containerd k8s.io):
    ${RAG_IMAGE}
    ${INGESTOR_IMAGE}

  Triton model repository:
    PVC: triton-model-repo (50Gi) mounted at /models in namespace 'triton'
    Copy models: k8s kubectl cp ./my-model triton/<triton-pod>:/models/my-model

  Monitor pods:
    k8s kubectl get pods -n ${HELM_NAMESPACE} -w

  Check NIM startup logs:
    k8s kubectl logs -f <nim-pod-name> -n ${HELM_NAMESPACE}

  Troubleshoot:
    k8s kubectl describe pod <pod-name> -n ${HELM_NAMESPACE}
    k8s kubectl get events -n ${HELM_NAMESPACE} --sort-by='.lastTimestamp'

  Full deploy log: ${LOGFILE}

========================================================================
SUMMARY
