#!/usr/bin/env bash
# ============================================================================
# CLEANUP — Remove All Lenovo RAG Blueprint Components
# ============================================================================
# Lenovo ThinkSystem SR650a V4 - GPU Inference Server
#
# This script reverses everything installed by setup_infra.sh and
# deploy_apps.sh. It removes:
#   - Helm releases (RAG Blueprint, NIM Operator, GPU Operator)
#   - Kubernetes namespaces and resources
#   - Custom container images from containerd
#   - Snap packages (OpenSearch, Canonical K8s)
#   - NVIDIA drivers and CUDA packages
#   - Kernel module configs, sysctl changes
#   - Helm repos and binary
#   - Credential files and logs
#
# Usage:
#   sudo bash cleanup.sh           # Interactive (prompts before each phase)
#   sudo bash cleanup.sh --force   # Non-interactive (no prompts)
#
# WARNING: This is destructive and irreversible. All data in OpenSearch,
# Kubernetes PVCs, and the model repository will be lost.
# ============================================================================

set -uo pipefail

# ============================================================================
# Configuration
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="/var/log/lenovo-cleanup.log"
FORCE=false

if [[ "${1:-}" == "--force" ]]; then
    FORCE=true
fi

# ============================================================================
# Helpers
# ============================================================================
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"; }

confirm() {
    if $FORCE; then return 0; fi
    local msg="$1"
    echo ""
    read -r -p "  $msg [y/N] " answer
    case "$answer" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

phase() {
    local num="$1"
    local desc="$2"
    echo ""
    echo "========================================"
    echo "  Phase ${num}: ${desc}"
    echo "========================================"
    log "Phase ${num}: ${desc}"
}

ok()   { echo "  [OK] $1"; log "[OK] $1"; }
skip() { echo "  [SKIP] $1"; log "[SKIP] $1"; }
warn() { echo "  [WARN] $1"; log "[WARN] $1"; }

# ============================================================================
# Pre-flight
# ============================================================================
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    echo "Usage: sudo bash cleanup.sh [--force]"
    exit 1
fi

mkdir -p "$(dirname "$LOGFILE")"

echo ""
echo "========================================================================"
echo "  Lenovo RAG Blueprint — Full Cleanup"
echo "========================================================================"
echo "  Log: ${LOGFILE}"
echo ""
echo "  WARNING: This will remove ALL components installed by setup_infra.sh"
echo "  and deploy_apps.sh, including Kubernetes, OpenSearch, NVIDIA drivers,"
echo "  all data, and all credentials."
echo ""

if ! $FORCE; then
    read -r -p "  Are you sure you want to proceed? Type 'yes' to confirm: " answer
    if [[ "$answer" != "yes" ]]; then
        echo "  Aborted."
        exit 0
    fi
fi

# ============================================================================
# Phase 1: Stop port-forward processes
# ============================================================================
phase 1 "Stop port-forward processes"

if pgrep -f "kubectl port-forward.*svc/rag-frontend" &>/dev/null; then
    pkill -f "kubectl port-forward.*svc/rag-frontend" 2>/dev/null || true
    ok "Killed rag-frontend port-forward."
else
    skip "No rag-frontend port-forward running."
fi

# ============================================================================
# Phase 2: Remove Helm releases and K8s resources
# ============================================================================
phase 2 "Remove Helm releases and Kubernetes resources"

# Check if K8s is available
K8S_AVAILABLE=false
if command -v k8s &>/dev/null && k8s status &>/dev/null 2>&1; then
    K8S_AVAILABLE=true
    export KUBECONFIG=/tmp/kubeconfig
    k8s config > "$KUBECONFIG" 2>/dev/null || true
fi

if $K8S_AVAILABLE; then
    # Uninstall RAG Blueprint Helm release
    if helm list -n rag 2>/dev/null | grep -q "rag"; then
        echo "  Uninstalling Helm release 'rag'..."
        helm uninstall rag -n rag >> "$LOGFILE" 2>&1 || warn "helm uninstall rag failed."
        ok "Helm release 'rag' uninstalled."
    else
        skip "Helm release 'rag' not found."
    fi

    # Uninstall NIM Operator
    if helm list -n nim-operator 2>/dev/null | grep -q "nim-operator"; then
        echo "  Uninstalling Helm release 'nim-operator'..."
        helm uninstall nim-operator -n nim-operator >> "$LOGFILE" 2>&1 || warn "helm uninstall nim-operator failed."
        ok "Helm release 'nim-operator' uninstalled."
    else
        skip "Helm release 'nim-operator' not found."
    fi

    # Delete Triton resources
    if k8s kubectl get namespace triton &>/dev/null 2>&1; then
        echo "  Deleting Triton resources..."
        k8s kubectl delete -n triton -f "${SCRIPT_DIR}/triton/triton-server.yaml" >> "$LOGFILE" 2>&1 || true
        ok "Triton resources deleted."
    else
        skip "Triton namespace not found."
    fi

    # Uninstall GPU Operator
    if helm list -n gpu-operator 2>/dev/null | grep -q "gpu-operator"; then
        echo "  Uninstalling Helm release 'gpu-operator'..."
        helm uninstall gpu-operator -n gpu-operator >> "$LOGFILE" 2>&1 || warn "helm uninstall gpu-operator failed."
        ok "Helm release 'gpu-operator' uninstalled."
    else
        skip "Helm release 'gpu-operator' not found."
    fi

    # Delete namespaces
    for ns in rag triton nim-operator gpu-operator inference; do
        if k8s kubectl get namespace "$ns" &>/dev/null 2>&1; then
            echo "  Deleting namespace '${ns}'..."
            k8s kubectl delete namespace "$ns" --timeout=120s >> "$LOGFILE" 2>&1 || warn "Namespace '${ns}' deletion timed out."
            ok "Namespace '${ns}' deleted."
        fi
    done

    # Delete OpenSearch bridge resources from default namespace
    k8s kubectl delete service opensearch -n default >> "$LOGFILE" 2>&1 || true
    k8s kubectl delete endpoints opensearch -n default >> "$LOGFILE" 2>&1 || true
    k8s kubectl delete secret opensearch-ca opensearch-creds -n default >> "$LOGFILE" 2>&1 || true

    # Remove custom images from containerd
    CTR="/snap/k8s/current/bin/ctr"
    CTR_ARGS="--address /run/containerd/containerd.sock --namespace k8s.io"
    for img in "docker.io/lenovo/rag-server:2.5.0-opensearch" "docker.io/lenovo/ingestor-server:2.5.0-opensearch"; do
        if $CTR $CTR_ARGS images list -q 2>/dev/null | grep -q "$img"; then
            $CTR $CTR_ARGS images rm "$img" >> "$LOGFILE" 2>&1 || true
            ok "Removed image '${img}' from containerd."
        fi
    done

    ok "Helm releases and K8s resources cleaned up."
else
    skip "Kubernetes not available — skipping Helm/K8s cleanup."
fi

# ============================================================================
# Phase 3: Remove Helm repos and binary
# ============================================================================
phase 3 "Remove Helm repos and binary"

if command -v helm &>/dev/null; then
    for repo in nvidia nvidia-nemo elastic zipkin otel prometheus; do
        helm repo remove "$repo" >> "$LOGFILE" 2>&1 || true
    done
    ok "Helm repos removed."
fi

if [[ -f /usr/local/bin/helm ]]; then
    rm -f /usr/local/bin/helm
    ok "Helm binary removed."
else
    skip "Helm binary not found at /usr/local/bin/helm."
fi

# ============================================================================
# Phase 4: Disable MIG and remove MIG node labels
# ============================================================================
phase 4 "Disable MIG mode"

if command -v nvidia-smi &>/dev/null; then
    # Check if MIG is enabled on GPU 1
    MIG_ENABLED=$(nvidia-smi -i 1 --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null | tr -d '[:space:]')
    if [[ "$MIG_ENABLED" == "Enabled" ]]; then
        echo "  Disabling MIG on GPU 1..."
        nvidia-smi -i 1 -mig 0 >> "$LOGFILE" 2>&1 || warn "MIG disable failed (may require reboot)."
        ok "MIG disabled on GPU 1 (reboot may be required to take effect)."
    else
        skip "MIG not enabled on GPU 1."
    fi
else
    skip "nvidia-smi not available."
fi

# ============================================================================
# Phase 5: Remove snaps (K8s, then OpenSearch)
# ============================================================================
phase 5 "Remove snap packages"

OPENSEARCH_REMOVED=false

if confirm "Remove Canonical K8s snap? This destroys the entire cluster and all PVCs."; then
    if snap list k8s &>/dev/null 2>&1; then
        echo "  Removing Canonical K8s snap..."
        snap stop k8s >> "$LOGFILE" 2>&1 || true
        snap remove k8s --purge >> "$LOGFILE" 2>&1 || warn "snap remove k8s failed."
        ok "Canonical K8s snap removed."
    else
        skip "K8s snap not installed."
    fi
else
    skip "K8s snap removal declined."
fi

if confirm "Remove OpenSearch snap? This destroys all indexed data."; then
    if snap list opensearch &>/dev/null 2>&1; then
        echo "  Removing OpenSearch snap..."
        snap stop opensearch.daemon >> "$LOGFILE" 2>&1 || true
        snap remove opensearch --purge >> "$LOGFILE" 2>&1 || warn "snap remove opensearch failed."
        ok "OpenSearch snap removed."
        OPENSEARCH_REMOVED=true
    else
        skip "OpenSearch snap not installed."
    fi

    # Remove vm.max_map_count (required only by OpenSearch)
    if grep -q "vm.max_map_count=262144" /etc/sysctl.conf 2>/dev/null; then
        sed -i '/vm\.max_map_count=262144/d' /etc/sysctl.conf
        sysctl -p >> "$LOGFILE" 2>&1 || true
        ok "Removed vm.max_map_count=262144 from /etc/sysctl.conf"
    fi
else
    skip "OpenSearch snap removal declined."
fi

# ============================================================================
# Phase 6: Remove NVIDIA drivers and CUDA packages
# ============================================================================
phase 6 "Remove NVIDIA drivers and CUDA packages"

DRIVERS_REMOVED=false

if confirm "Remove NVIDIA drivers, CUDA toolkit, and related packages? (Answer 'n' to keep the drivers installed)"; then
    # Official NVIDIA driver removal for Ubuntu 22.04/24.04:
    # https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/removing-the-driver.html
    #
    # We first query dpkg for installed NVIDIA/CUDA packages, then pass only
    # those to apt remove. This avoids "Unable to locate package" errors from
    # globs that match nothing (apt treats that as a hard failure).
    NVIDIA_PKGS=$(dpkg -l 2>/dev/null \
        | grep -iE '^ii.*(nvidia|cuda|libnvsdm|libxnvctrl|xserver-xorg-video-nvidia)' \
        | awk '{print $2}' \
        | sort -u)

    if [[ -z "$NVIDIA_PKGS" ]]; then
        skip "No NVIDIA/CUDA packages found installed — nothing to remove."
    else
        PKG_COUNT=$(echo "$NVIDIA_PKGS" | wc -l)
        echo "  Found ${PKG_COUNT} NVIDIA/CUDA package(s) to remove."
        echo "$NVIDIA_PKGS" >> "$LOGFILE"

        # shellcheck disable=SC2086
        if apt remove --autoremove --purge -y $NVIDIA_PKGS >> "$LOGFILE" 2>&1; then
            ok "NVIDIA driver and CUDA packages removed (${PKG_COUNT} packages)."
            DRIVERS_REMOVED=true
        else
            warn "apt remove completed with errors — check ${LOGFILE} for details."
        fi
    fi

    # Remove the CUDA apt keyring package and repository sources
    if dpkg -l cuda-keyring &>/dev/null 2>&1; then
        dpkg --purge cuda-keyring >> "$LOGFILE" 2>&1 || true
        ok "CUDA keyring package removed."
    fi
    rm -f /etc/apt/sources.list.d/cuda*.list 2>/dev/null || true
    rm -f /usr/share/keyrings/cuda*.gpg 2>/dev/null || true

    # Clean up any local NVIDIA driver repo left behind
    rm -rf /var/nvidia-driver-local-repo-* 2>/dev/null || true

    apt-get update >> "$LOGFILE" 2>&1 || true

    # Remove kernel module configs that were added for the NVIDIA drivers
    INITRAMFS_DIRTY=false
    if [[ -f /etc/modprobe.d/blacklist-nouveau.conf ]]; then
        rm -f /etc/modprobe.d/blacklist-nouveau.conf
        ok "Removed /etc/modprobe.d/blacklist-nouveau.conf"
        INITRAMFS_DIRTY=true
    fi
    if [[ -f /etc/modprobe.d/nvidia-uvm.conf ]]; then
        rm -f /etc/modprobe.d/nvidia-uvm.conf
        ok "Removed /etc/modprobe.d/nvidia-uvm.conf"
        INITRAMFS_DIRTY=true
    fi
    if $INITRAMFS_DIRTY && command -v update-initramfs &>/dev/null; then
        update-initramfs -u >> "$LOGFILE" 2>&1 || warn "update-initramfs failed."
        ok "Initramfs rebuilt."
    fi
else
    skip "NVIDIA driver removal skipped — drivers and kernel configs kept in place."
fi

# ============================================================================
# Phase 7: Remove credentials, logs, and config files
# ============================================================================
phase 7 "Remove credentials, logs, and temporary files"

# Credential store
if [[ -d /root/.credentials/lenovo-rag ]]; then
    rm -rf /root/.credentials/lenovo-rag
    ok "Removed /root/.credentials/lenovo-rag"
fi

# Kubeconfig files
rm -f /tmp/kubeconfig 2>/dev/null || true
rm -f /root/.kube/config 2>/dev/null || true

# Try to clean up the sudo user's kubeconfig too
REAL_USER="${SUDO_USER:-}"
if [[ -n "$REAL_USER" ]]; then
    REAL_HOME=$(eval echo "~${REAL_USER}")
    rm -f "${REAL_HOME}/.kube/config" 2>/dev/null || true
fi

# Log files
rm -f /var/log/lenovo-infra-setup.log 2>/dev/null || true
rm -f /var/log/lenovo-apps-deploy.log 2>/dev/null || true


# Build temp directory
rm -rf "${SCRIPT_DIR}/.build-tmp" 2>/dev/null || true

ok "Credentials, logs, and temporary files removed."

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "========================================================================"
echo "  CLEANUP COMPLETE"
echo "========================================================================"
echo ""
echo "  Removed:"
echo "    - Helm releases (rag, nim-operator, gpu-operator)"
echo "    - K8s namespaces (rag, triton, nim-operator, gpu-operator, inference)"
echo "    - Custom container images"
echo "    - Snap packages (k8s, opensearch) — if confirmed"
echo "    - NVIDIA drivers and CUDA packages — if confirmed (may have been kept)"
echo "    - Credentials, logs, and temp files"
echo ""
if $DRIVERS_REMOVED; then
    echo "  NVIDIA kernel module configs (nouveau blacklist, nvidia-uvm) were removed."
    echo "  A reboot is recommended to fully unload NVIDIA kernel modules."
else
    echo "  NVIDIA drivers were kept — kernel module configs left in place."
fi
if $OPENSEARCH_REMOVED; then
    echo "  OpenSearch sysctl tuning (vm.max_map_count) was removed."
fi
echo ""
echo "  Cleanup log: ${LOGFILE}"
echo ""
echo "========================================================================"
