# Lenovo RAG Blueprint for ThinkSystem SR650a V4

NVIDIA RAG Blueprint 2.5.0 customized for a Lenovo ThinkSystem SR650a V4 with
2x NVIDIA RTX PRO 6000 Blackwell GPUs (96 GB each). Replaces Milvus with
OpenSearch as the vector database, assigns workloads across a custom MIG layout,
and adds a standalone Triton Inference Server for general-purpose ML inference.

---

## Solution Layout

```
lenovo_nvidia_rag_blueprint/
  config_infra.env           # Shared configuration (hardware, MIG, OpenSearch)
  setup_infra.sh             # Phase 1: Infrastructure (drivers, K8s, GPU Operator, OpenSearch)
  deploy_apps.sh             # Phase 2: Applications  (images, Helm chart, Triton)
  cleanup.sh                 # Full teardown (snaps, drivers, K8s, credentials)
  rag_blueprint_lenovo/      # Customized RAG Blueprint (Helm chart, VDB code, Dockerfiles)
  triton/
    triton-server.yaml       # Standalone Triton deployment (K8s manifests)
```

### Component Map

| Component | Role | Runs On |
|-----------|------|---------|
| NIM LLM (Llama-3.3-Nemotron-Super-49B-v1.5) | Chat completion, answer generation | GPU 0 (full, non-MIG) |
| NIM Embedding (llama-nemotron-embed-1b-v2) | Query and document embedding | GPU 1 MIG 1g.24 GB |
| NIM Reranking (llama-nemotron-rerank-1b-v2) | Result re-ranking | GPU 1 MIG 1g.24 GB |
| NIM OCR (nemoretriever-ocr-v1) | Text extraction from scanned pages | GPU 1 MIG 2g.48 GB |
| NIM Page Elements (nemotron-page-elements-v3) | Layout detection (tables, charts, text) | GPU 1 MIG 2g.48 GB |
| NIM Graphic Elements (nemotron-graphic-elements-v1) | Chart and graphic detection | GPU 1 MIG 1g.24 GB |
| NIM Table Structure (nemotron-table-structure-v1) | Table cell/row recognition | GPU 1 MIG 1g.24 GB |
| RAG Server | Query orchestration (embed, search, rerank, LLM) | CPU |
| Ingestor Server | Document ingestion API | CPU |
| nv-ingest | Document processing pipeline (Ray, CPU) | CPU |
| OpenSearch | Vector store (k-NN) + BM25 full-text search | Bare metal (snap) |
| Redis | Message broker for nv-ingest | CPU |
| Triton Inference Server | General ML inference (ONNX, TensorRT, etc.) | GPU 1 MIG 2g.48 GB |

### GPU Layout

GPU 0 is dedicated entirely to the LLM with no MIG and no time-slicing.
GPU 1 runs MIG mode with three hardware-isolated slices. Within each slice,
CUDA time-slicing shares the hardware between multiple workloads.

| GPU | Slice | VRAM | Workloads (time-sliced) | K8s Resource |
|-----|-------|------|------------------------|--------------|
| 0 | Full GPU | 96 GB | NIM LLM | `nvidia.com/gpu: 1` |
| 1 | 1g.24 GB #0 (2x TS) | 24 GB | NIM Embed + NIM Rerank | `nvidia.com/mig-1g.24gb: 1` |
| 1 | 1g.24 GB #1 (2x TS) | 24 GB | NIM Graphic Elems + NIM Table Struct | `nvidia.com/mig-1g.24gb: 1` |
| 1 | 2g.48 GB #0 (3x TS) | 48 GB | NIM OCR + NIM Page Elems + Triton | `nvidia.com/mig-2g.48gb: 1` |

MIG provides memory and SM isolation between slices. Time-slicing within a
slice allows multiple pods to share it by context-switching on the GPU.

---

## What We Customized (vs. Upstream Blueprint)

- **OpenSearch** replaces Milvus as the vector database (bare-metal snap, k-NN + BM25)
- **Custom GPU layout** maps all workloads across a 2-GPU MIG configuration
- **Custom container images** add the OpenSearch VDB operator (built automatically by `deploy_apps.sh`)
- **Triton Inference Server** runs as a standalone deployment sharing a MIG slice

No upstream Helm templates were modified — all changes are in `values.yaml`,
new files, and one 12-line patch to the VDB factory.

---

## Support Matrix

| Component | Version | Provider |
|-----------|---------|----------|
| Ubuntu | 24.04 LTS (Ubuntu Pro) | Canonical |
| Canonical K8s (snap) | 1.32 | Canonical |
| OpenSearch (snap) | 2/stable | Canonical |
| NVIDIA Drivers (open kernel) | 595.58.03 | NVIDIA |
| CUDA Toolkit | 13 | NVIDIA |
| GPU Operator | v26.3.0 | NVIDIA |
| NVIDIA RAG Blueprint | 2.5.0 | NVIDIA |
| NIM Operator | 3.1.0 | NVIDIA |
| NIM Containers | 2.0.x | NVIDIA |
| Triton Inference Server | 26.03 | NVIDIA |

### Hardware Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| Server | 2U rack, PCIe Gen5 x16 slots | Lenovo ThinkSystem SR650a V4 |
| GPUs | 2x NVIDIA RTX PRO 6000 Blackwell (96 GB) | Same |
| RAM | 512 GB | 1 TB |
| CPU | 64 cores | 192 cores |
| Storage | 1 TB NVMe | 2 TB NVMe |

---

## Installation

### Prerequisites

1. Ubuntu 24.04 LTS installed on the server
2. Root (sudo) access
3. Internet connectivity (for container image pulls and model downloads)
4. An [NGC API key](https://org.ngc.nvidia.com/setup) with access to NIM
   containers on `nvcr.io`

### Step 1 -- Deploy Infrastructure

`setup_infra.sh` installs NVIDIA drivers, OpenSearch, Canonical K8s, the GPU
Operator with MIG configuration, and creates the OpenSearch K8s bridge.

```bash
sudo bash setup_infra.sh
```

The script will prompt for a **reboot** after installing NVIDIA drivers on the
first run. After rebooting, re-run the same command to continue from where it
left off. The script is idempotent.

**Phases:**

| # | What it does |
|---|-------------|
| 1 | NVIDIA drivers (open kernel 595.58.03) + CUDA 13 |
| 2 | OpenSearch snap (TLS, admin password, k-NN plugin) |
| 3 | Canonical K8s 1.32 (single-node, DNS, local-storage, LB) |
| 4 | GPU Operator v26.3.0 + MIG configuration (mig-manager) |
| 5 | Load balancer (MetalLB / k8sd, L2 mode) |
| 6 | K8s namespaces, OpenSearch Service+Endpoints bridge, secrets |

### Step 2 -- Deploy Applications

`deploy_apps.sh` builds the custom images, installs the NIM Operator, deploys
the RAG Blueprint via Helm, and deploys Triton.

```bash
sudo bash deploy_apps.sh
```

The script will prompt for the NGC API key if not already saved. On subsequent
runs it detects the existing deployment and offers to upgrade.

**Phases:**

| # | What it does |
|---|-------------|
| 1 | Validate prerequisites (K8s, GPU Operator, OpenSearch bridge) |
| 2 | NGC credentials (prompt or load from store) |
| 3 | Build custom images with buildah (OpenSearch VDB support) |
| 4 | Build Helm chart dependencies |
| 5 | Install NIM Operator (CRDs + controller) |
| 6 | Helm install/upgrade of the RAG Blueprint |
| 7 | Deploy Triton Inference Server into `triton` namespace |
| 8 | Post-deploy status and pod readiness check |

**Flags:**

```
--upgrade    Upgrade an existing Helm release
--dry-run    Render templates only (helm template)
--uninstall  Remove the RAG Blueprint and Triton deployments
```

### Step 3 -- Wait for NIM Images

NIM container images are large (10--40 GB each). After `deploy_apps.sh`
completes, pods will be in `ContainerCreating` or `Pending` state while images
are pulled. Monitor progress:

```bash
k8s kubectl get pods -n rag -w
k8s kubectl get pods -n triton -w
```

### Step 4 -- Access the Frontend

The frontend service is exposed via a LoadBalancer. Once all pods are running,
get the external IP:

```bash
k8s kubectl get svc rag-frontend -n rag
```

Open `http://<EXTERNAL-IP>:3000` in a browser.

Note: OpenSearch survives reboots automatically (enabled via `snap start --enable`).

### Verify Triton

```bash
# Check Triton readiness
k8s kubectl exec -n triton deploy/triton-inference-server -- \
  curl -s localhost:8000/v2/health/ready

# List loaded models
k8s kubectl exec -n triton deploy/triton-inference-server -- \
  curl -s localhost:8000/v2/models | python3 -m json.tool

# Test inference with the SDK container (from a machine with Docker):
docker run --rm --net=host nvcr.io/nvidia/tritonserver:26.03-py3-sdk \
  /workspace/install/bin/image_client -m densenet_onnx -c 3 -s INCEPTION \
  -u <server-ip>:8000 /workspace/images/mug.jpg
```

### Adding Models to Triton

Copy model directories into the PVC:

```bash
k8s kubectl cp ./my-model triton/<triton-pod>:/models/my-model
```

Triton will detect and load new models automatically (polling mode is enabled).

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Pods stuck in `Pending` | MIG slices not created, or time-slicing not configured | Check `k8s kubectl describe node` for allocatable GPU resources |
| NIM pods `CrashLoopBackOff` | Image pull failed (NGC auth), or GPU resource mismatch | Check `k8s kubectl describe pod <pod> -n rag` for events |
| OpenSearch connection refused | Bridge Service/Endpoints missing, or snap not running | `snap services opensearch`, then check `k8s kubectl get endpoints opensearch -n rag` |
| Triton `CrashLoopBackOff` | Empty model repo or download failure in initContainer | `k8s kubectl logs -n triton deploy/triton-inference-server -c model-loader` |
| `runtimeClassName` errors | CDI enabled in GPU Operator (incompatible with containerd 1.6) | Verify `cdi.enabled=false` in GPU Operator ClusterPolicy |

Full deployment logs are written to `/var/log/lenovo-apps-deploy.log`.

---

## Benchmarks

This solution has been validated against the NVIDIA RAG Blueprint 2.5.0
accuracy benchmarks using the FinanceBench dataset (150 questions, 84 PDFs).

| Metric | Value |
|--------|-------|
| RAGAS Answer Accuracy | **0.6067** (NVIDIA baseline: 0.612, within 0.9%) |
| RAG Throughput (20 concurrent users) | 5.12 req/s, 0% failure rate |
| Triton Peak Throughput (DenseNet ONNX) | ~245 infer/sec |

---

## Cleanup

To completely remove all components (Helm releases, Kubernetes, snaps, NVIDIA
drivers, credentials, and system configurations):

```bash
sudo bash cleanup.sh
```

The script is interactive by default -- it prompts before removing snaps and
NVIDIA packages. Use `--force` to skip all prompts:

```bash
sudo bash cleanup.sh --force
```

A reboot is recommended after cleanup to fully unload kernel modules.
