#!/usr/bin/env bash
# ============================================================================
# SETUP INFRA - Canonical Infrastructure Layer
# ============================================================================
# Lenovo ThinkSystem SR650a V4 - GPU Inference Server
# 2x NVIDIA RTX PRO 6000 Blackwell (96GB each)
#
# This script deploys the core infrastructure layer:
#   1. System Preparation & NVIDIA Drivers + CUDA
#   2. OpenSearch (Snap — bare-metal vector DB for RAG)
#   3. Canonical Kubernetes (Snap) + Helm
#   4. NVIDIA GPU Operator (Helm) + MIG Configuration
#   5. Load Balancer Configuration (built-in)
#   6. Namespace Setup, OpenSearch Bridge & Secrets
#
# This layer is application-agnostic. NGC/NIM credentials and app-specific
# secrets are handled by deploy_apps.sh.
#
# Usage:
#   sudo bash setup_infra.sh
#   sudo bash setup_infra.sh --skip-gpu    # Skip GPU phases (for non-GPU testing)
#
# The script is idempotent and can be re-run safely. Each step checks
# whether its work is already done and skips if so.
# After driver installation the script exits and prompts you to reboot,
# then re-run the script to continue with the remaining steps.
# ============================================================================

set -euo pipefail

# Ensure /snap/bin is in PATH — required for Canonical K8s (`k8s` lives there).
# Non-login shells (sudo, systemd, cron) may not source /etc/profile.d/*.
export PATH="/snap/bin:${PATH}"

# ============================================================================
# Error Trap — ensures failures are ALWAYS visible on the console
# ============================================================================
# With set -euo pipefail, any failing command causes an immediate exit.
# Combined with ">> $LOGFILE 2>&1" redirects, this can produce silent exits.
# This trap catches those failures and prints a visible diagnostic to stderr
# (the console) AND appends it to the logfile.
on_error() {
    local exit_code=$?
    local line_no=$1
    local command="$2"
    local msg="FATAL: Script failed at line ${line_no} (exit code ${exit_code})"
    local detail="  Command: ${command}"
    local hint="  Check the full log: /var/log/lenovo-infra-setup.log"
    echo "" >&2
    echo "========================================" >&2
    echo "  ${msg}" >&2
    echo "  ${detail}" >&2
    echo "  ${hint}" >&2
    echo "========================================" >&2
    # Also append to logfile if it exists
    if [[ -n "${LOGFILE:-}" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${msg}" >> "$LOGFILE" 2>/dev/null || true
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${detail}" >> "$LOGFILE" 2>/dev/null || true
    fi
}
trap 'on_error ${LINENO} "${BASH_COMMAND}"' ERR

# ============================================================================
# Argument Parsing
# ============================================================================
SKIP_GPU=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-gpu)
            SKIP_GPU=true
            shift
            ;;
        --help|-h)
            echo "Usage: sudo bash setup_infra.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-gpu   Skip GPU-related phases (NVIDIA drivers,"
            echo "               GPU Operator + MIG config)."
            echo "               Use for testing infrastructure on non-GPU instances."
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
# Load Configuration
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config_infra.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    echo "Please ensure config_infra.env exists in the same directory as this script."
    exit 1
fi

# shellcheck source=config_infra.env
source "$CONFIG_FILE"

# ============================================================================
# Logging — all output goes to logfile; console only shows start/end banners
# ============================================================================
LOGFILE="/var/log/lenovo-infra-setup.log"

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
echo "  Lenovo Infra Setup"
echo "========================================================================"
echo "  All output is written to: ${LOGFILE}"
echo "  Monitor progress:         tail -f ${LOGFILE}"
echo ""
echo "  Steps:"
echo "    1. System preparation & NVIDIA drivers (reboot required)"
echo "    2. OpenSearch"
echo "    3. Canonical Kubernetes + Helm"
echo "    4. NVIDIA GPU Operator + MIG configuration"
echo "    5. Load balancer"
echo "    6. Namespaces, OpenSearch bridge & secrets"
echo ""
echo "  This will take 15-30 minutes. Do not interrupt."
echo "========================================================================"
echo ""

# Detect the primary host IP (uses routing table, falls back to first global addr)
detect_host_ip() {
    local ip
    ip=$(ip -4 route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
    if [[ -z "$ip" ]]; then
        ip=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)
    fi
    echo "$ip"
}

# ============================================================================
# Pre-flight Checks
# ============================================================================
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    echo "Usage: sudo bash setup_infra.sh"
    exit 1
fi

# ============================================================================
# Credential Management
# ============================================================================
# Infrastructure credentials (OpenSearch) are auto-generated and stored in
# a secure directory. No interactive prompts — this script is fully automated.
# Application-specific credentials (NGC API key) are handled by deploy_apps.sh.

mkdir -p "$CREDENTIAL_STORE"
chmod 700 "$CREDENTIAL_STORE"

# Generate a random credential if not already stored. Usage:
#   generate_credential "LABEL" "filename" "description"
# Sets variable named LABEL. Generates a 32-char alphanumeric password.
generate_credential() {
    local var_name="$1"
    local cred_file="${CREDENTIAL_STORE}/$2"
    local description="$3"

    if [[ -f "$cred_file" ]]; then
        printf -v "$var_name" '%s' "$(cat "$cred_file")"
        log "Credential loaded: ${description}"
        return 0
    fi

    local value
    value=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
    echo -n "$value" > "$cred_file"
    chmod 600 "$cred_file"
    printf -v "$var_name" '%s' "$value"
    log "Credential generated: ${description}"
}

# Load or generate all infrastructure credentials
load_credentials() {
    log "Loading infrastructure credentials from ${CREDENTIAL_STORE}..."
    generate_credential "OPENSEARCH_ADMIN_PASSWORD" "opensearch_admin_password" \
        "OpenSearch admin password"
    generate_credential "OPENSEARCH_TLS_ROOT_PASS" "opensearch_tls_root_pass" \
        "OpenSearch TLS root CA password"
    generate_credential "OPENSEARCH_TLS_ADMIN_PASS" "opensearch_tls_admin_pass" \
        "OpenSearch TLS admin cert password"
    generate_credential "OPENSEARCH_TLS_NODE_PASS" "opensearch_tls_node_pass" \
        "OpenSearch TLS node cert password"

    log "All infrastructure credentials loaded."
}

load_credentials

# Pre-flight GPU check
if [[ "$SKIP_GPU" == true ]]; then
    log_warn "Running with --skip-gpu: skipping NVIDIA driver and GPU Operator phases."
elif ! lspci | grep -i -E "VGA|3D" | grep -i -q nvidia; then
    log_err "No NVIDIA GPU hardware detected (lspci). Use --skip-gpu for non-GPU testing."
    exit 1
fi

log "Starting infrastructure setup."

# ============================================================================
# Phase 1: System Preparation & NVIDIA Drivers
# ============================================================================
log_step "1 - System Preparation & NVIDIA Drivers"

if [[ "$SKIP_GPU" == true ]]; then
    log "GPU drivers skipped. Installing basic dependencies..."
    apt-get update >> "$LOGFILE" 2>&1
    apt-get install -y build-essential curl git jq wget python3-bcrypt >> "$LOGFILE" 2>&1
    log_ok "Basic dependencies installed (GPU drivers skipped)."
else
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
        log_ok "NVIDIA drivers already installed and working."
    else
        log "Installing NVIDIA drivers and CUDA toolkit..."

        # Blacklist Nouveau
        cat <<EOF > /etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0
EOF
        log_ok "Nouveau driver blacklisted."

        # Update initramfs
        update-initramfs -u >> "$LOGFILE" 2>&1
        log_ok "initramfs updated."

        # Install build dependencies
        apt-get update >> "$LOGFILE" 2>&1
        apt-get install -y build-essential curl git jq wget python3-bcrypt \
            linux-headers-"$(uname -r)" >> "$LOGFILE" 2>&1
        log_ok "Build dependencies installed."

        # CUDA keyring and repos
        wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
        dpkg -i cuda-keyring_1.1-1_all.deb >> "$LOGFILE" 2>&1
        apt-get update >> "$LOGFILE" 2>&1
        rm -f cuda-keyring_1.1-1_all.deb
        log_ok "NVIDIA CUDA repository configured."

        # Install drivers + CUDA
        # 595.58.03 is the NVIDIA-recommended certified driver for RTX PRO 6000 Blackwell
        # as of 26 March 2026. NVIDIA has not yet published a nvidia-open-595 branch
        # meta-package (highest available is nvidia-open-580), so we pin the exact version
        # string. The Ubuntu apt suffix is -1ubuntu1 (verified from the NVIDIA CUDA repo).
        # Compatible with CUDA 13.x; cuda-toolkit-13 is the CUDA 13 branch meta-package.
        # Open kernel module is required for Blackwell (cc 12.0). R560 and below are EOL.
        log "Installing NVIDIA Open Drivers (595.58.03) and CUDA Toolkit 13 (this may take 10-20 minutes)..."
        apt-get install -y \
            "nvidia-open=595.58.03-1ubuntu1" \
            cuda-toolkit-13 \
            nvidia-gds >> "$LOGFILE" 2>&1
        log_ok "NVIDIA drivers (595.58.03) and CUDA toolkit 13 installed."

        # Disable HMM for NVIDIA UVM
        cat <<EOF > /etc/modprobe.d/nvidia-uvm.conf
options nvidia_uvm uvm_disable_hmm=1
EOF
        log_ok "HMM disabled for NVIDIA UVM."

        log_ok "Phase 1 complete: NVIDIA drivers installed."
        echo ""
        echo "========================================================================"
        echo "  Step 1 complete: NVIDIA drivers installed."
        echo ""
        echo "  Please reboot the system to load the kernel modules, then"
        echo "  log back in and re-run this script to continue:"
        echo ""
        echo "    sudo reboot"
        echo "    # (after reboot)"
        echo "    sudo bash ${SCRIPT_DIR}/setup_infra.sh"
        echo ""
        echo "  Full log: ${LOGFILE}"
        echo "========================================================================"
        echo ""
        exit 0
    fi
fi

log_ok "Phase 1 complete."

# ============================================================================
# Phase 2: OpenSearch (Snap — Bare Metal)
# ============================================================================
log_step "2 - OpenSearch Snap Setup"

if snap list opensearch &>/dev/null; then
    log_ok "OpenSearch snap already installed."
else
    log "Installing OpenSearch snap (channel: ${OPENSEARCH_SNAP_CHANNEL})..."
    snap install opensearch --channel="${OPENSEARCH_SNAP_CHANNEL}" >> "$LOGFILE" 2>&1
    snap connect opensearch:process-control >> "$LOGFILE" 2>&1
    log_ok "OpenSearch snap installed."
fi

# Kernel tuning
if ! grep -q "vm.max_map_count=262144" /etc/sysctl.conf; then
    echo "vm.max_map_count=262144" >> /etc/sysctl.conf
    sysctl -p >> "$LOGFILE" 2>&1
    log_ok "Kernel parameter vm.max_map_count set."
fi

# Network binding
snap set opensearch network-host="0.0.0.0" 2>/dev/null || true

# TLS Certificate generation
if [[ ! -f /var/snap/opensearch/current/etc/opensearch/certificates/root-ca.pem ]]; then
    log "Generating TLS certificates for OpenSearch..."
    snap run opensearch.setup \
        --node-name "$OPENSEARCH_NODE_NAME" \
        --node-roles cluster_manager,data \
        --tls-priv-key-root-pass "$OPENSEARCH_TLS_ROOT_PASS" \
        --tls-priv-key-admin-pass "$OPENSEARCH_TLS_ADMIN_PASS" \
        --tls-priv-key-node-pass "$OPENSEARCH_TLS_NODE_PASS" \
        --tls-init-setup yes >> "$LOGFILE" 2>&1
    log_ok "TLS certificates generated."
else
    log_ok "TLS certificates already exist."
fi

# Set admin password BEFORE security-init runs.
# The snap ships with a default admin:admin hash in internal_users.yml.
# We replace it with a bcrypt hash of our generated password so that
# security-init loads the correct credentials on first initialization.
# This is the same approach the Canonical opensearch-operator charm uses.
INTERNAL_USERS="/var/snap/opensearch/current/etc/opensearch/opensearch-security/internal_users.yml"

log "Setting OpenSearch admin password..."
ADMIN_HASH=$(python3 -c "
import bcrypt, sys
print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt()).decode())
" "$OPENSEARCH_ADMIN_PASSWORD")
sed -i "/^admin:/,/^  hash:/ s|^  hash: .*|  hash: \"${ADMIN_HASH}\"|" "$INTERNAL_USERS"
log_ok "Admin password hash set in internal_users.yml."

# The k-NN plugin is bundled with the Canonical OpenSearch snap and enabled
# by default (knn.plugin.enabled=true is set in cluster defaults). No
# additional configuration is required.

# Start OpenSearch and enable auto-start on boot
if ! snap services opensearch.daemon | grep -qw "active"; then
    log "Starting OpenSearch daemon..."
    snap start --enable opensearch.daemon >> "$LOGFILE" 2>&1
    log_ok "OpenSearch daemon started and enabled for auto-start on boot."
else
    # Ensure auto-start is enabled even if daemon is already running
    snap start --enable opensearch.daemon >> "$LOGFILE" 2>&1
    log_ok "OpenSearch daemon already active; auto-start on boot confirmed."
fi

# Wait for OpenSearch to be ready (may take several minutes after reboot)
log "Waiting for OpenSearch to become ready..."
OS_READY=false
for i in $(seq 1 120); do
    if curl -sk https://localhost:${OPENSEARCH_PORT} &>/dev/null; then
        log_ok "OpenSearch is responding."
        OS_READY=true
        break
    fi
    sleep 5
done
if [[ "$OS_READY" != "true" ]]; then
    log_err "OpenSearch failed to become ready after 10 minutes."
    log "Check: snap logs opensearch.daemon -n 50"
    exit 1
fi

# Initialize security (loads internal_users.yml with our admin password hash)
# Only needed on first run — skip if admin password already works
if curl -sk -u "admin:${OPENSEARCH_ADMIN_PASSWORD}" "https://localhost:${OPENSEARCH_PORT}" | grep -q "cluster_name" 2>/dev/null; then
    log_ok "OpenSearch security already initialized."
else
    log "Initializing OpenSearch security..."
    for attempt in 1 2 3; do
        if snap run opensearch.security-init \
            --tls-priv-key-admin-pass="$OPENSEARCH_TLS_ADMIN_PASS" >> "$LOGFILE" 2>&1; then
            log_ok "OpenSearch security initialized."
            break
        fi
        log_warn "security-init attempt ${attempt} failed, retrying in 15s..."
        sleep 15
    done
fi

# Extract root CA for K8s trust
ROOT_CA_PATH="${SCRIPT_DIR}/root-ca.pem"
cp /var/snap/opensearch/current/etc/opensearch/certificates/root-ca.pem "$ROOT_CA_PATH"
chmod 644 "$ROOT_CA_PATH"
log_ok "Root CA extracted to $ROOT_CA_PATH"

log_ok "Phase 2 complete."

# ============================================================================
# Phase 3: Canonical Kubernetes
# ============================================================================
log_step "3 - Canonical Kubernetes Setup"

if command -v k8s &>/dev/null && k8s status &>/dev/null; then
    log_ok "Canonical Kubernetes already installed and running."
else
    log "Installing Canonical Kubernetes (channel: ${K8S_SNAP_CHANNEL})..."
    snap install k8s --classic --channel="${K8S_SNAP_CHANNEL}" >> "$LOGFILE" 2>&1

    log "Bootstrapping single-node cluster..."
    k8s bootstrap >> "$LOGFILE" 2>&1
    k8s status --wait-ready >> "$LOGFILE" 2>&1
    log_ok "Kubernetes cluster bootstrapped."
fi

# Enable required features (idempotent — re-enabling is safe)
log "Enabling K8s features (DNS, local-storage, load-balancer)..."
k8s enable dns >> "$LOGFILE" 2>&1 || true
k8s enable local-storage >> "$LOGFILE" 2>&1 || true
k8s enable load-balancer >> "$LOGFILE" 2>&1 || true
log_ok "K8s features enabled."

# Configure KUBECONFIG
k8s config | tee /tmp/kubeconfig > /dev/null
export KUBECONFIG=/tmp/kubeconfig

# Also set up for the original user if running via sudo
mkdir -p /root/.kube
cp /tmp/kubeconfig /root/.kube/config
if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    mkdir -p "${REAL_HOME}/.kube"
    cp /tmp/kubeconfig "${REAL_HOME}/.kube/config"
    chown -R "$SUDO_USER":"$SUDO_USER" "${REAL_HOME}/.kube"
fi

# Install Helm
if ! command -v helm &>/dev/null; then
    log "Installing Helm..."
    curl -fsSL -o /tmp/get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
    chmod 700 /tmp/get_helm.sh
    DESIRED_VERSION="" /tmp/get_helm.sh >> "$LOGFILE" 2>&1
    rm -f /tmp/get_helm.sh
    log_ok "Helm installed."
else
    log_ok "Helm already installed."
fi

log_ok "Phase 3 complete."

# Ensure KUBECONFIG is set for remaining phases
export KUBECONFIG=/tmp/kubeconfig

# ============================================================================
# Phase 4: NVIDIA GPU Operator + MIG Configuration
# ============================================================================
if [[ "$SKIP_GPU" == true ]]; then
    log_step "4 - NVIDIA GPU Operator [SKIPPED - --skip-gpu]"
else
    log_step "4 - NVIDIA GPU Operator (Helm) + MIG Configuration"

    # ---------------------------------------------------------------
    # Step 1: Enable MIG mode on GPU 1
    # GPU 0 stays non-MIG, dedicated to LLM (no time-slicing)
    # GPU 1 gets MIG mode — the actual slice geometry (GIs/CIs) will be
    # created by the GPU Operator's mig-manager in Step 3.
    # ---------------------------------------------------------------
    log "Ensuring MIG mode is enabled on GPU ${MIG_GPU_INDEX}..."

    MIG_CURRENT=$(nvidia-smi -i "${MIG_GPU_INDEX}" --query-gpu=mig.mode.current --format=csv,noheader,nounits 2>/dev/null | tr -d '[:space:]')
    if [[ "$MIG_CURRENT" == "Enabled" ]]; then
        log_ok "MIG already enabled on GPU ${MIG_GPU_INDEX}."
    else
        log "Enabling MIG on GPU ${MIG_GPU_INDEX}..."
        nvidia-smi -i "${MIG_GPU_INDEX}" -mig 1 >> "$LOGFILE" 2>&1

        # GPU reset is required after enabling MIG.
        log "Resetting GPU ${MIG_GPU_INDEX} to activate MIG mode..."
        if nvidia-smi --gpu-reset -i "${MIG_GPU_INDEX}" >> "$LOGFILE" 2>&1; then
            log_ok "GPU ${MIG_GPU_INDEX} reset successfully."
        else
            log_warn "GPU reset failed. A system reboot may be required to activate MIG."
            log "After reboot, re-run this script to continue."
        fi
    fi

    # Verify MIG is enabled
    MIG_CURRENT=$(nvidia-smi -i "${MIG_GPU_INDEX}" --query-gpu=mig.mode.current --format=csv,noheader,nounits 2>/dev/null | tr -d '[:space:]')
    if [[ "$MIG_CURRENT" != "Enabled" ]]; then
        log_err "MIG is not enabled on GPU ${MIG_GPU_INDEX}. A reboot is likely required."
        log "After reboot, re-run: sudo bash setup_infra.sh"
        exit 1
    fi

    # ---------------------------------------------------------------
    # Step 2: Install NVIDIA GPU Operator with MIG mixed strategy
    # ---------------------------------------------------------------
    # mig-manager is ENABLED (default) — it reads a ConfigMap and a node
    # label to create MIG GPU Instances (GIs) and Compute Instances (CIs).
    # This is the NVIDIA-documented approach for MIG in Kubernetes.
    # mig-manager also handles persistence: on every reboot it re-reads
    # the node label and recreates the MIG geometry automatically.

    # Add NVIDIA Helm repo
    helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >> "$LOGFILE" 2>&1 || true
    helm repo update >> "$LOGFILE" 2>&1

    # Create namespace
    k8s kubectl create namespace gpu-operator --dry-run=client -o yaml | k8s kubectl apply -f - >> "$LOGFILE" 2>&1
    k8s kubectl label ns gpu-operator pod-security.kubernetes.io/enforce=privileged --overwrite >> "$LOGFILE" 2>&1

    # Check if GPU operator is already installed
    if helm list -n gpu-operator 2>/dev/null | grep -q gpu-operator; then
        log_ok "GPU Operator already installed."
    else
        log "Installing NVIDIA GPU Operator (version: ${GPU_OPERATOR_VERSION}, MIG strategy: mixed)..."
        # driver.enabled=false — we install NVIDIA drivers via apt (Phase 1)
        # mig.strategy=mixed — allows MIG and non-MIG GPUs in the same node
        # migManager is enabled by default — it will create MIG slices based
        #   on the ConfigMap and node label applied in Step 3
        #
        # CDI DISABLED — Canonical K8s 1.32 ships containerd v1.6.x which
        # does NOT support CDI (requires containerd v1.7+). With CDI enabled
        # (the GPU Operator v26.3.0 default), GPU injection silently fails
        # and all GPU pods crash with "NVIDIA Driver not detected".
        #
        # With cdi.enabled=false the toolkit uses the legacy nvidia runtime
        # approach: it registers an "nvidia" runtime handler in containerd's
        # config.toml. CONTAINERD_SET_DEFAULT_RUNTIME=true makes nvidia the
        # DEFAULT handler so ALL containers get GPU access — even those with
        # runtimeClassName unset or empty (as the NIM Operator v3.1.0 does).
        #
        # Canonical K8s uses standard containerd paths:
        #   config:  /etc/containerd/config.toml
        #   socket:  /run/containerd/containerd.sock
        #   drop-in: /etc/containerd/conf.d/*.toml (imported by config.toml)
        helm install gpu-operator nvidia/gpu-operator \
            -n gpu-operator \
            --version="${GPU_OPERATOR_VERSION}" \
            --set driver.enabled=false \
            --set mig.strategy=mixed \
            --set cdi.enabled=false \
            --set toolkit.env[0].name=CONTAINERD_SET_DEFAULT_RUNTIME \
            --set-string toolkit.env[0].value=true \
            --set dcgmExporter.enabled=true \
            --set dcgmExporter.serviceMonitor.enabled=true \
            >> "$LOGFILE" 2>&1
        log_ok "GPU Operator installed (MIG mixed, mig-manager enabled, CDI off, nvidia default runtime)."
    fi

    # Ensure CDI is disabled and CONTAINERD_SET_DEFAULT_RUNTIME=true on ClusterPolicy
    # (idempotent — needed when the GPU Operator was installed previously
    # without these settings, or when re-running the script on an existing cluster)
    if k8s kubectl get clusterpolicy cluster-policy &>/dev/null 2>&1; then
        # Disable CDI (containerd v1.6 doesn't support it)
        CDI_ENABLED=$(k8s kubectl get clusterpolicy cluster-policy -o jsonpath='{.spec.cdi.enabled}' 2>/dev/null || true)
        if [[ "$CDI_ENABLED" == "true" ]]; then
            log "Disabling CDI on ClusterPolicy (containerd v1.6 does not support CDI)..."
            k8s kubectl patch clusterpolicy cluster-policy --type='json' \
                -p='[{"op":"replace","path":"/spec/cdi/enabled","value":false}]' \
                >> "$LOGFILE" 2>&1
            log_ok "CDI disabled on ClusterPolicy."
        else
            log_ok "ClusterPolicy CDI already disabled."
        fi

        # Set nvidia as default containerd runtime
        CURRENT_ENV=$(k8s kubectl get clusterpolicy cluster-policy -o jsonpath='{.spec.toolkit.env}' 2>/dev/null || true)
        if echo "$CURRENT_ENV" | grep -q "CONTAINERD_SET_DEFAULT_RUNTIME"; then
            log_ok "ClusterPolicy already has CONTAINERD_SET_DEFAULT_RUNTIME."
        else
            log "Patching ClusterPolicy to set nvidia as default containerd runtime..."
            k8s kubectl patch clusterpolicy cluster-policy --type='json' \
                -p='[{"op":"add","path":"/spec/toolkit/env/-","value":{"name":"CONTAINERD_SET_DEFAULT_RUNTIME","value":"true"}}]' \
                >> "$LOGFILE" 2>&1 \
                || {
                    # If /spec/toolkit/env doesn't exist yet, create it
                    k8s kubectl patch clusterpolicy cluster-policy --type='json' \
                        -p='[{"op":"add","path":"/spec/toolkit/env","value":[{"name":"CONTAINERD_SET_DEFAULT_RUNTIME","value":"true"}]}]' \
                        >> "$LOGFILE" 2>&1
                }
            log_ok "ClusterPolicy patched: nvidia is now the default containerd runtime."
            log "The nvidia-container-toolkit pod will restart to reconfigure containerd."
        fi
    fi

    # Wait for GPU operator pods to be ready before configuring
    log "Waiting for GPU Operator pods to be ready..."
    k8s kubectl wait --for=condition=ready pod -l app=nvidia-device-plugin-daemonset \
        -n gpu-operator --timeout=300s >> "$LOGFILE" 2>&1 \
        || log_warn "Device plugin not ready yet, continuing..."

    # ---------------------------------------------------------------
    # Step 3: Apply MIG configuration via mig-manager
    # ---------------------------------------------------------------
    # The GPU Operator's mig-manager watches for a node label
    # (nvidia.com/mig.config) and reads a ConfigMap to determine the
    # MIG slice geometry. It creates the GPU Instances (GIs) and
    # Compute Instances (CIs) automatically, and re-creates them
    # on every reboot.
    #
    # Our ConfigMap defines the profile:
    #   lenovo-2gpu-0nomig-1mig-2x1g24-1x2g48
    #     GPU 0: non-MIG (dedicated to LLM)
    #     GPU 1: 2x 1g.24gb + 1x 2g.48gb
    MIG_CONFIG_FILE="${SCRIPT_DIR}/rag_blueprint_lenovo/deploy/helm/mig-slicing/mig-config-lenovo-2gpu.yaml"
    MIG_CONFIG_LABEL="lenovo-2gpu-0nomig-1mig-2x1g24-1x2g48"

    log "Applying MIG configuration ConfigMap..."
    k8s kubectl apply -n gpu-operator -f "$MIG_CONFIG_FILE" >> "$LOGFILE" 2>&1
    log_ok "MIG ConfigMap applied."

    # Point the GPU Operator's mig-manager at our ConfigMap
    log "Patching ClusterPolicy to use custom MIG config..."
    k8s kubectl patch clusterpolicy cluster-policy --type='json' \
        -p='[{"op":"replace", "path":"/spec/migManager/config/name", "value":"custom-mig-config"}]' \
        >> "$LOGFILE" 2>&1
    log_ok "ClusterPolicy patched for mig-manager."

    # Label the node to trigger mig-manager to create the MIG slices
    NODE_NAME=$(k8s kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
    log "Labeling node '${NODE_NAME}' with MIG config: ${MIG_CONFIG_LABEL}..."
    k8s kubectl label nodes "$NODE_NAME" "nvidia.com/mig.config=${MIG_CONFIG_LABEL}" --overwrite >> "$LOGFILE" 2>&1
    log_ok "Node labeled. mig-manager will now create the MIG slices."

    # Wait for mig-manager to apply the configuration
    # mig-manager sets nvidia.com/mig.config.state=success on the node when done
    log "Waiting for mig-manager to apply MIG configuration (up to 5 minutes)..."
    MIG_APPLIED=false
    for i in $(seq 1 60); do
        MIG_STATE=$(k8s kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}' 2>/dev/null || true)
        if [[ "$MIG_STATE" == "success" ]]; then
            log_ok "mig-manager successfully applied MIG configuration."
            MIG_APPLIED=true
            break
        elif [[ "$MIG_STATE" == "failed" ]]; then
            log_err "mig-manager FAILED to apply MIG configuration."
            log "Check mig-manager logs: k8s kubectl logs -n gpu-operator -l app=nvidia-mig-manager"
            break
        fi
        sleep 5
    done
    if [[ "$MIG_APPLIED" != "true" ]]; then
        log_warn "mig-manager has not confirmed success yet (state: ${MIG_STATE:-pending})."
        log_warn "MIG slices may still be in progress. Check:"
        log_warn "  k8s kubectl get node ${NODE_NAME} -o jsonpath='{.metadata.labels}' | jq . | grep mig"
        log_warn "  k8s kubectl logs -n gpu-operator -l app=nvidia-mig-manager"
    fi

    # Verify MIG instances are visible
    log "MIG device listing:"
    nvidia-smi -L >> "$LOGFILE" 2>&1

    # ---------------------------------------------------------------
    # Step 4: Configure MIG time-slicing (GPU 0 is dedicated — no time-slicing)
    # ---------------------------------------------------------------
    # GPU 0 is non-MIG and dedicated to the LLM (no time-slicing).
    #   nvidia.com/gpu has 1 allocatable (the LLM is the sole consumer).
    #
    # GPU 1 MIG slices are each shared by 2 pods via CUDA time-slicing:
    #   1g.24gb slice 0 (2x): Embed + Rerank
    #   1g.24gb slice 1 (2x): Graphic Elements + Table Structure
    #   2g.48gb slice 2 (2x): OCR + Page Elements
    #
    # The GPU Operator device plugin reads a ConfigMap and advertises
    # `replicas` copies of each MIG resource type.
    # With 2x physical 1g.24gb and replicas=2, K8s sees 4 allocatable.
    # With 1x physical 2g.48gb and replicas=2, K8s sees 2 allocatable.
    log "Configuring MIG time-slicing (${MIG_PROFILE_SMALL}: ${MIG_SMALL_TIME_SLICE_COUNT}x, ${MIG_PROFILE_LARGE}: ${MIG_LARGE_TIME_SLICE_COUNT}x)..."

    k8s kubectl apply -n gpu-operator -f - <<EOF >> "$LOGFILE" 2>&1
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
data:
  any: |-
    version: v1
    flags:
      migStrategy: mixed
    sharing:
      timeSlicing:
        resources:
        - name: nvidia.com/mig-${MIG_PROFILE_SMALL}
          replicas: ${MIG_SMALL_TIME_SLICE_COUNT}
        - name: nvidia.com/mig-${MIG_PROFILE_LARGE}
          replicas: ${MIG_LARGE_TIME_SLICE_COUNT}
EOF
    log_ok "Time-slicing ConfigMap created (MIG ${MIG_PROFILE_SMALL}: ${MIG_SMALL_TIME_SLICE_COUNT}x, MIG ${MIG_PROFILE_LARGE}: ${MIG_LARGE_TIME_SLICE_COUNT}x). GPU 0 dedicated (no time-slicing)."

    # Patch the GPU Operator's ClusterPolicy to use the time-slicing config.
    # The device plugin reads this ConfigMap and advertises the replicated slots.
    if k8s kubectl get clusterpolicy cluster-policy &>/dev/null; then
        k8s kubectl patch clusterpolicy cluster-policy --type=merge -p '
{
  "spec": {
    "devicePlugin": {
      "config": {
        "name": "time-slicing-config",
        "default": "any"
      }
    }
  }
}' >> "$LOGFILE" 2>&1
        log_ok "ClusterPolicy patched for time-slicing."
    else
        log_warn "ClusterPolicy 'cluster-policy' not found yet — time-slicing patch deferred."
        log_warn "The GPU Operator may still be initializing. Re-run this script if needed."
    fi

    # Wait for device plugin to pick up the new configuration
    log "Waiting for device plugin to restart with new configuration..."
    sleep 15

    # Verify GPU resources are visible to Kubernetes
    log "GPU resources visible in Kubernetes:"
    k8s kubectl get nodes -o json | jq '.items[].status.allocatable | with_entries(select(.key | startswith("nvidia")))' >> "$LOGFILE" 2>&1

    # Log all GPU Operator pod statuses for diagnostics
    log "GPU Operator pod statuses:"
    k8s kubectl get pods -n gpu-operator -o wide >> "$LOGFILE" 2>&1

    # Verify containerd was reconfigured with nvidia as default runtime.
    # With CDI disabled + CONTAINERD_SET_DEFAULT_RUNTIME=true, the toolkit
    # registers an "nvidia" runtime handler in containerd and sets it as the
    # default. The nvidia RuntimeClass K8s object may or may not be created
    # (it's mainly used with CDI). What matters is that containerd's
    # default_runtime_name is "nvidia".
    log "Verifying nvidia runtime configuration..."
    sleep 10  # Give toolkit pod time to reconfigure containerd
    if grep -q 'default_runtime_name.*nvidia' /etc/containerd/config.toml 2>/dev/null \
        || grep -rq 'default_runtime_name.*nvidia' /etc/containerd/conf.d/ 2>/dev/null; then
        log_ok "containerd default runtime is nvidia."
    else
        log_warn "containerd default_runtime_name may not be set to nvidia yet."
        log_warn "The toolkit pod may still be reconfiguring containerd."
        log_warn "Check: grep -r default_runtime_name /etc/containerd/"
        log_warn "Check: k8s kubectl logs -n gpu-operator -l app=nvidia-container-toolkit-daemonset"
    fi
    k8s kubectl get runtimeclass >> "$LOGFILE" 2>&1 || true
fi

log_ok "Phase 4 complete."

# ============================================================================
# Phase 5: Load Balancer Configuration (built-in)
# ============================================================================
log_step "5 - Load Balancer Configuration"

# Canonical K8s ships with a built-in load balancer (MetalLB managed by k8sd).
# It was enabled in Phase 3 via `k8s enable load-balancer`.
# Now configure the IP address pool and L2 mode.

HOST_IP=$(detect_host_ip)

if [[ -n "${LB_IP_RANGE:-}" ]]; then
    LB_RANGE="$LB_IP_RANGE"
else
    IP_BASE=$(echo "$HOST_IP" | cut -d. -f1-3)
    LB_RANGE="${IP_BASE}.200-${IP_BASE}.210"
fi

log "Configuring built-in load balancer with IP range: $LB_RANGE"
k8s set load-balancer.cidrs="[\"${LB_RANGE}\"]" >> "$LOGFILE" 2>&1
k8s set load-balancer.l2-mode=true >> "$LOGFILE" 2>&1
log_ok "Load balancer configured (L2 mode, range: $LB_RANGE)."

# Verify
log "Load balancer status:"
k8s get load-balancer >> "$LOGFILE" 2>&1

log_ok "Phase 5 complete."

# ============================================================================
# Phase 6: Namespace Setup, OpenSearch Bridge & Secrets
# ============================================================================
log_step "6 - Namespace Setup, OpenSearch Bridge & Secrets"

# Verify credentials are loaded
if [[ -z "${OPENSEARCH_ADMIN_PASSWORD:-}" ]]; then
    log_err "OPENSEARCH_ADMIN_PASSWORD is empty or unset."
    log_err "Check ${CREDENTIAL_STORE}/opensearch_admin_password or re-run the script."
    exit 1
fi

# Verify root-ca.pem exists (copied from OpenSearch in Phase 2)
ROOT_CA_PATH_CHECK="${SCRIPT_DIR}/root-ca.pem"
if [[ ! -f "$ROOT_CA_PATH_CHECK" ]]; then
    # Try to recover it from OpenSearch snap if available
    local_opensearch_ca="/var/snap/opensearch/current/etc/opensearch/certificates/root-ca.pem"
    if [[ -f "$local_opensearch_ca" ]]; then
        log_warn "root-ca.pem not found in ${SCRIPT_DIR}/, copying from OpenSearch snap..."
        cp "$local_opensearch_ca" "$ROOT_CA_PATH_CHECK"
        chmod 644 "$ROOT_CA_PATH_CHECK"
        log_ok "Recovered root-ca.pem from OpenSearch snap."
    else
        log_err "root-ca.pem not found at ${ROOT_CA_PATH_CHECK}"
        log_err "Phase 2 (OpenSearch) must complete successfully first."
        log_err "Expected source: ${local_opensearch_ca}"
        exit 1
    fi
fi

# Verify required config variables
for var in K8S_NAMESPACE_INFERENCE K8S_NAMESPACE_RAG OPENSEARCH_PORT; do
    if [[ -z "${!var:-}" ]]; then
        log_err "Required config variable ${var} is empty or unset. Check config.env."
        exit 1
    fi
done

HOST_IP=$(detect_host_ip)

# Create namespaces for workloads
k8s kubectl create namespace "${K8S_NAMESPACE_INFERENCE}" --dry-run=client -o yaml | k8s kubectl apply -f - >> "$LOGFILE" 2>&1
k8s kubectl create namespace "${K8S_NAMESPACE_RAG}" --dry-run=client -o yaml | k8s kubectl apply -f - >> "$LOGFILE" 2>&1

# Label inference namespace for GPU access (privileged for GPU device plugin)
k8s kubectl label ns "${K8S_NAMESPACE_INFERENCE}" pod-security.kubernetes.io/enforce=privileged --overwrite >> "$LOGFILE" 2>&1

# --- OpenSearch Service Bridge ---
log "Creating OpenSearch service bridge (opensearch -> ${HOST_IP})..."
for ns in "${K8S_NAMESPACE_RAG}" "default"; do
    k8s kubectl apply -n "$ns" -f - <<EOF >> "$LOGFILE" 2>&1
apiVersion: v1
kind: Service
metadata:
  name: opensearch
spec:
  ports:
  - protocol: TCP
    port: ${OPENSEARCH_PORT}
    targetPort: ${OPENSEARCH_PORT}
---
apiVersion: v1
kind: Endpoints
metadata:
  name: opensearch
subsets:
- addresses:
  - ip: "${HOST_IP}"
  ports:
  - port: ${OPENSEARCH_PORT}
EOF
done
log_ok "OpenSearch service bridge created."

# --- OpenSearch Credentials ---
log "Creating OpenSearch secrets..."
ROOT_CA_PATH="${SCRIPT_DIR}/root-ca.pem"

for ns in "${K8S_NAMESPACE_RAG}" "default"; do
    k8s kubectl create secret generic opensearch-ca \
        --from-file=ca.crt="$ROOT_CA_PATH" \
        -n "$ns" --dry-run=client -o yaml | k8s kubectl apply -f - >> "$LOGFILE" 2>&1

    k8s kubectl create secret generic opensearch-creds \
        --from-literal=username="admin" \
        --from-literal=password="$OPENSEARCH_ADMIN_PASSWORD" \
        -n "$ns" --dry-run=client -o yaml | k8s kubectl apply -f - >> "$LOGFILE" 2>&1
done
log_ok "OpenSearch secrets created."

log_ok "Phase 6 complete."

# ============================================================================
# Summary
# ============================================================================
log_step "INFRASTRUCTURE SETUP COMPLETE"

HOST_IP=$(detect_host_ip)

if [[ "$SKIP_GPU" == true ]]; then
cat <<SUMMARY | tee -a "$LOGFILE"

========================================================================
  INFRASTRUCTURE READY (--skip-gpu mode)
========================================================================

  OS:             Ubuntu 24.04 LTS (Ubuntu Pro)
  GPU:            SKIPPED (--skip-gpu)

  Infrastructure:
    Kubernetes:    Canonical K8s (snap)
    GPU Operator:  SKIPPED
    Load Balancer: Built-in (k8sd-managed, L2 mode)
    OpenSearch:    Snap (bare metal), TLS-secured, k-NN plugin enabled

  Endpoints:
    OpenSearch:    https://${HOST_IP}:${OPENSEARCH_PORT}

  Next Step:
    sudo bash deploy_apps.sh
    (GPU workloads will fail without GPUs — use for infra testing only)

  Full log: ${LOGFILE}

========================================================================
SUMMARY
else
cat <<SUMMARY | tee -a "$LOGFILE"

========================================================================
  INFRASTRUCTURE READY
========================================================================

  Server:         Lenovo ThinkSystem SR650a V4
  OS:             Ubuntu 24.04 LTS (Ubuntu Pro)
  GPUs:           2x NVIDIA RTX PRO 6000 Blackwell (96GB each)

  GPU Layout:
    GPU 0:  Full 96GB, non-MIG, dedicated (LLM only)
    GPU 1:  96GB, MIG ${MIG_SMALL_SLICE_COUNT}x ${MIG_PROFILE_SMALL} + ${MIG_LARGE_SLICE_COUNT}x ${MIG_PROFILE_LARGE}
            ${MIG_PROFILE_SMALL} time-sliced ${MIG_SMALL_TIME_SLICE_COUNT}x each (Embed+Rerank, GraphicElements+TableStructure)
            ${MIG_PROFILE_LARGE} time-sliced ${MIG_LARGE_TIME_SLICE_COUNT}x (OCR + Page Elements)

  K8s allocatable GPU resources:
    nvidia.com/gpu:               1  (GPU 0, dedicated)
    nvidia.com/mig-${MIG_PROFILE_SMALL}:  $((MIG_SMALL_SLICE_COUNT * MIG_SMALL_TIME_SLICE_COUNT))  (${MIG_SMALL_SLICE_COUNT} physical x ${MIG_SMALL_TIME_SLICE_COUNT} replicas)
    nvidia.com/mig-${MIG_PROFILE_LARGE}:  $((MIG_LARGE_SLICE_COUNT * MIG_LARGE_TIME_SLICE_COUNT))  (${MIG_LARGE_SLICE_COUNT} physical x ${MIG_LARGE_TIME_SLICE_COUNT} replicas)

  Infrastructure:
    Kubernetes:    Canonical K8s (snap)
    GPU Operator:  NVIDIA GPU Operator ${GPU_OPERATOR_VERSION} (MIG mixed strategy)
    Load Balancer: Built-in (k8sd-managed, L2 mode)
    OpenSearch:    Snap (bare metal), TLS-secured, k-NN plugin enabled

  Endpoints:
    OpenSearch:    https://${HOST_IP}:${OPENSEARCH_PORT}

  Next Step:
    sudo bash deploy_apps.sh

  Full log: ${LOGFILE}

========================================================================
SUMMARY
fi
