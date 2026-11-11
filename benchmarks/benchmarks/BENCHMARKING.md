# Benchmarking Guide — Lenovo ThinkSystem SR650a V4 RAG Deployment

This guide covers three benchmarking areas for the deployed RAG pipeline and Triton
Inference Server on the Lenovo ThinkSystem SR650a V4 with 2x NVIDIA RTX PRO 6000
Blackwell GPUs.

| Area | What It Measures | Tools |
|------|-----------------|-------|
| [RAG Quality](#1-rag-quality-evaluation) | Answer accuracy, context relevancy, groundedness, recall | NVIDIA RAGAS notebooks |
| [RAG Throughput](#2-rag-loadthroughput-testing) | Requests/sec, latency under load, error rate | Locust |
| [Triton Performance](#3-triton-inference-server-benchmarking) | Model throughput, latency percentiles, concurrency scaling | perf_analyzer |

**Prerequisites**: The full stack must be deployed and healthy (`deploy_apps.sh` completed,
all pods in Running state). Port-forward the rag-server to localhost:

```bash
nohup k8s kubectl port-forward -n rag svc/rag-server 8081:8081 --address 0.0.0.0 > /dev/null 2>&1 &
```

---

## 1. RAG Quality Evaluation

The NVIDIA RAG Blueprint 2.5.0 ships two evaluation notebooks that measure answer quality
using industry-standard RAGAS metrics. These notebooks are located in the bundle and require
no modification — they work against the deployed RAG server's HTTP API.

### 1.1 Metrics

| Metric | Notebook | Description |
|--------|----------|-------------|
| Answer Accuracy | `evaluation_01_ragas.ipynb` | Degree to which generated responses align with ground truth (0–4 scale, normalized). Measured by an LLM judge. |
| Context Relevancy | `evaluation_01_ragas.ipynb` | How relevant the retrieved context is to the question. |
| Response Groundedness | `evaluation_01_ragas.ipynb` | Whether the answer is grounded in the retrieved context (not hallucinated). |
| Context Recall@k | `evaluation_02_recall.ipynb` | Whether the correct source document appears in the top-k retrieved results. |

The LLM judge is `mistralai/Mixtral-8x22B-Instruct-v0.1` (hosted on NVIDIA API Catalog).

### 1.2 Datasets

NVIDIA benchmarked against 7 public datasets. You can use any subset:

| Dataset | Domain | Queries | Key Challenge |
|---------|--------|---------|---------------|
| FinanceBench | Finance (Public Equity) | 150 | Table-heavy, requires arithmetic |
| KG-RAG | Finance (SEC 10-Q) | 195 | Temporal reasoning across quarters |
| RAGBattle | Finance, Tax, Consulting | 92 | Charts, infographics, visual queries |
| DC767 | General (Gov, NGO, Health) | 488 | Dense text prose, semantic search |
| HotPotQA | Wikipedia | 979 | Multi-hop reasoning |
| Google Frames | History, Sports, Science | 824 | Multi-document fact synthesis |
| Vidore-V3 | 8 sub-domains (multilingual) | ~14,500 | Visual layouts, tables, charts |

### 1.3 Running the RAGAS Evaluation

**Location**: `rag_blueprint_lenovo/notebooks/evaluation_01_ragas.ipynb`

**Setup**:

```bash
# Install Jupyter if not already available (use the benchmark venv)
source ~/bench-venv/bin/activate
pip install jupyterlab

# Set the NVIDIA API key for the LLM judge
export NVIDIA_API_KEY="nvapi-..."

# Launch Jupyter
jupyter lab --ip 0.0.0.0 --port 8888 --no-browser \
  --notebook-dir=/workspace/lenovo_nvidia_rag_blueprint/rag_blueprint_lenovo/notebooks
```

**Key configuration cells in the notebook**:

```python
# Cell: Server connection (adjust if not using port-forward)
IPADDRESS = "localhost"
RAG_SERVER_PORT = "8081"
RAG_BASE_URL = f"http://{IPADDRESS}:{RAG_SERVER_PORT}"

# Cell: Query payload — adjust collection_names to match your ingested data
generate_payload = {
    "messages": [{"role": "user", "content": question}],
    "use_knowledge_base": True,
    "reranker_top_k": 2,
    "vdb_top_k": 10,
    "collection_names": ["multimodal_data"],  # <-- your collection name
    "enable_reranker": True,
    "enable_citations": True,
}
```

**What the notebook does**:
1. Sends each question to `POST /v1/generate` (SSE streaming)
2. Collects the answer text and retrieved citation contexts
3. Sends (question, answer, context, ground_truth) to the RAGAS evaluator
4. The LLM judge scores each response on the 0–4 scale
5. Outputs per-question and aggregate scores

**Expected runtime**: ~2–5 minutes per 100 questions (depends on LLM inference speed).

### 1.4 Running the Recall Evaluation

**Location**: `rag_blueprint_lenovo/notebooks/evaluation_02_recall.ipynb`

This notebook measures retrieval quality independently of the LLM — it only calls
`POST /v1/search` and checks whether the correct source document appears in the results.

```python
# Key configuration
data_search = {
    "query": query,
    "vdb_top_k": 10,            # test at k=5, 10, 20, 50, 100
    "collection_names": ["multimodal_data"],
}
```

**Interpreting results**: Recall@10 of 0.85 means 85% of questions had the correct
document in the top 10 retrieved results. Higher recall with lower k is better.

### 1.5 NVIDIA Reference Baselines

From NVIDIA's published benchmarks (default configuration, Reasoning Off):

| Dataset | LLM Only | With VLM |
|---------|----------|----------|
| FinanceBench | 0.612 | 0.622 |
| KG-RAG | 0.569 | 0.596 |
| RAGBattle | 0.812 | 0.867 |
| DC767 | 0.906 | 0.907 |
| HotPotQA | 0.672 | n/a |
| Google Frames | 0.486 | n/a |

Your OpenSearch-backed deployment should produce comparable numbers. Significant
deviations indicate a configuration issue (embedding quality, chunk size, reranker
settings, or VDB search parameters).

---

## 2. RAG Load/Throughput Testing

Use [Locust](https://locust.io/) to measure how many concurrent users and requests/sec
the RAG pipeline can sustain before latency degrades.

### 2.1 Install Locust

```bash
# Use the benchmark venv (see benchmarks/README.md Prerequisites)
source ~/bench-venv/bin/activate
pip install locust
```

### 2.2 Create the Locust Test File

The locust test file is at `benchmarks/scripts/locustfile.py`. It includes 20 FinanceBench
questions targeting the `financebench` collection. Here is a simplified version:

```python
"""
Locust load test for RAG Server API.

Targets:
  - POST /v1/generate  (streaming SSE — measures end-to-end RAG)
  - POST /v1/search    (retrieval only — measures VDB + reranker)
  - GET  /v1/health    (lightweight health check baseline)

Usage:
  locust --headless --users 10 --spawn-rate 2 --run-time 60s \
         --host http://localhost:8081 -f benchmarks/locustfile.py
"""

import random
from locust import HttpUser, task, between

# Sample questions — replace with domain-specific queries after ingesting your documents.
QUESTIONS = [
    "What was the total revenue for Q3 2024?",
    "Summarize the key findings from the annual report.",
    "What are the risk factors mentioned in the filing?",
    "How does the company's gross margin compare year over year?",
    "What is the company's debt-to-equity ratio?",
    "Describe the main products and services offered.",
    "What were the capital expenditures last fiscal year?",
    "Who are the members of the board of directors?",
]

# Adjust to match your ingested collection name.
COLLECTION = "multimodal_data"


class RAGUser(HttpUser):
    """Simulates a user interacting with the RAG server."""

    # Think time between requests (seconds). Adjust for realistic vs stress testing.
    wait_time = between(1, 3)

    @task(3)
    def generate(self):
        """Full RAG generation (LLM + retrieval). Weighted 3x — the primary workload."""
        payload = {
            "messages": [{"role": "user", "content": random.choice(QUESTIONS)}],
            "use_knowledge_base": True,
            "reranker_top_k": 2,
            "vdb_top_k": 10,
            "collection_names": [COLLECTION],
            "enable_reranker": True,
            "enable_citations": True,
            "max_tokens": 512,
        }
        # The /generate endpoint returns SSE. Locust measures time-to-last-byte.
        with self.client.post(
            "/v1/generate", json=payload, catch_response=True, timeout=120
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"Status {resp.status_code}: {resp.text[:200]}")

    @task(1)
    def search(self):
        """Retrieval-only query. Measures VDB + embedding + reranker latency."""
        payload = {
            "query": random.choice(QUESTIONS),
            "vdb_top_k": 10,
            "collection_names": [COLLECTION],
            "enable_reranker": True,
        }
        with self.client.post(
            "/v1/search", json=payload, catch_response=True, timeout=60
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"Status {resp.status_code}: {resp.text[:200]}")

    @task(1)
    def health(self):
        """Health check — establishes a latency baseline."""
        self.client.get("/v1/health")
```

### 2.3 Running the Load Test

```bash
# Quick smoke test: 5 users, 30 seconds
locust --headless \
  --users 5 \
  --spawn-rate 1 \
  --run-time 30s \
  --host http://localhost:8081 \
   -f benchmarks/scripts/locustfile.py

# Moderate load: 20 concurrent users, 5 minutes
locust --headless \
  --users 20 \
  --spawn-rate 2 \
  --run-time 5m \
  --host http://localhost:8081 \
  -f benchmarks/scripts/locustfile.py

# Stress test: ramp to 50 users
locust --headless \
  --users 50 \
  --spawn-rate 5 \
  --run-time 10m \
  --host http://localhost:8081 \
  -f benchmarks/scripts/locustfile.py

# With web UI (for real-time charts):
locust --host http://localhost:8081 -f benchmarks/scripts/locustfile.py
# Then open http://localhost:8089 in a browser
```

### 2.4 Metrics Reported

Locust prints a summary table at the end of each run:

| Metric | Description |
|--------|-------------|
| **# reqs** | Total completed requests per endpoint |
| **# fails** | Failed requests + failure percentage |
| **Avg (ms)** | Average response time |
| **Min / Max (ms)** | Minimum and maximum response times |
| **Median (ms)** | 50th percentile response time |
| **req/s** | Throughput — requests per second |
| **failures/s** | Failure rate per second |

### 2.5 Interpreting Results

**What to look for**:

- **`/v1/generate` latency**: This is dominated by LLM inference time. On the RTX PRO
  6000 with Llama-3.3-Nemotron-Super-49B (NVFP4, TP1), expect 5–30 seconds per request
  depending on output length. Latency should remain relatively stable until the LLM
  queuing limit is reached.

- **`/v1/search` latency**: Retrieval-only. Should be 200ms–2s depending on collection
  size and reranker. If this degrades rapidly under load, the bottleneck is likely the
  embedding NIM or OpenSearch.

- **`/v1/health` latency**: Should be <50ms consistently. Rising health latency indicates
  the rag-server's uvicorn workers (8 by default) are saturated.

- **Error rate**: Should be 0% at low concurrency. Errors under load usually indicate
  NIM timeout, OOM on a MIG slice, or OpenSearch connection pool exhaustion.

**Performance tuning levers**:

| Parameter | Location | Effect |
|-----------|----------|--------|
| `workers: 8` | values.yaml line 95 | Number of uvicorn workers in rag-server |
| `vdb_top_k` | Query payload | Higher = more VDB work, better recall |
| `reranker_top_k` | Query payload | Higher = more reranker inference |
| `enable_reranker` | Query payload | Disabling skips reranker NIM entirely |
| `max_tokens` | Query payload | Lower = faster LLM responses |

The blueprint also ships a performance-optimized preset at
`deploy/compose/perf_profile.env` (reranker off, top_k=4, chunk_size=512) that you can
use as a starting point for throughput-oriented benchmarking.

---

## 3. Triton Inference Server Benchmarking

The standalone Triton Inference Server (deployed in the `triton` namespace) serves the
DenseNet-121 ONNX model on a 2g.48gb MIG slice. Use NVIDIA's `perf_analyzer` to
benchmark it.

### 3.1 Launch the Triton SDK Container

`perf_analyzer` ships in the Triton SDK container. Run it as an ephemeral pod in the
`triton` namespace so it can reach the ClusterIP service:

```bash
k8s kubectl run perf-analyzer \
  --namespace=triton \
  --rm -it \
  --restart=Never \
  --image=nvcr.io/nvidia/tritonserver:26.03-py3-sdk \
  -- bash
```

This drops you into a shell with `perf_analyzer` available. All commands below are run
inside this container.

### 3.2 Basic Benchmark

```bash
# HTTP protocol (port 8000)
perf_analyzer \
  -m densenet_onnx \
  -u triton-inference-server.triton.svc.cluster.local:8000 \
  -i http

# gRPC protocol (port 8001) — generally higher throughput
perf_analyzer \
  -m densenet_onnx \
  -u triton-inference-server.triton.svc.cluster.local:8001 \
  -i grpc
```

### 3.3 Concurrency Sweep

The most useful benchmark — measures how throughput and latency scale as concurrent
requests increase:

```bash
perf_analyzer \
  -m densenet_onnx \
  -u triton-inference-server.triton.svc.cluster.local:8001 \
  -i grpc \
  --concurrency-range=1:8:1 \
  --percentile=95 \
  -v
```

This tests concurrency levels 1, 2, 3, ..., 8 and reports p95 latency at each level.

### 3.4 Batch Size Testing

Test how batching affects throughput:

```bash
# Batch size 4, concurrency sweep
perf_analyzer \
  -m densenet_onnx \
  -u triton-inference-server.triton.svc.cluster.local:8001 \
  -i grpc \
  -b 4 \
  --concurrency-range=1:8:2 \
  --percentile=95
```

### 3.5 Export Results to CSV

```bash
perf_analyzer \
  -m densenet_onnx \
  -u triton-inference-server.triton.svc.cluster.local:8001 \
  -i grpc \
  --concurrency-range=1:8:1 \
  --percentile=95 \
  -f /tmp/results.csv \
  --verbose-csv
```

Copy results out of the pod (from another terminal):
```bash
k8s kubectl cp triton/perf-analyzer:/tmp/results.csv ./triton-benchmark-results.csv
```

### 3.6 With Server-Side Prometheus Metrics

```bash
perf_analyzer \
  -m densenet_onnx \
  -u triton-inference-server.triton.svc.cluster.local:8001 \
  -i grpc \
  --concurrency-range=1:8:1 \
  --percentile=95 \
  -f /tmp/results.csv \
  --verbose-csv \
  --collect-metrics \
  --metrics-url=triton-inference-server.triton.svc.cluster.local:8002/metrics
```

This adds GPU utilization, GPU memory, and per-model queue/compute metrics to the CSV.

### 3.7 Non-Interactive (Job-Based) Benchmark

For reproducible, unattended runs:

```bash
k8s kubectl apply -n triton -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: triton-benchmark
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: perf-analyzer
        image: nvcr.io/nvidia/tritonserver:26.03-py3-sdk
        command:
        - perf_analyzer
        - -m
        - densenet_onnx
        - -u
        - triton-inference-server.triton.svc.cluster.local:8001
        - -i
        - grpc
        - --concurrency-range=1:8:1
        - --percentile=95
  backoffLimit: 0
EOF

# View results
k8s kubectl logs -n triton job/triton-benchmark

# Clean up
k8s kubectl delete -n triton job/triton-benchmark
```

### 3.8 Key perf_analyzer Flags

| Flag | Description |
|------|-------------|
| `-m <model>` | Model name (required) |
| `-u <url>` | Server URL (`host:port`) |
| `-i [http\|grpc]` | Protocol |
| `--concurrency-range=start:end:step` | Sweep concurrency levels |
| `-b <n>` | Batch size (default: 1) |
| `--percentile=<n>` | Report Nth percentile latency (e.g., 95, 99) |
| `-p <ms>` | Measurement interval in ms (default: 5000) |
| `--async` | Async inference (higher concurrency with fewer threads) |
| `--input-data=[random\|zero\|<path>]` | Input data source (default: random) |
| `-f <path>` | Output CSV file |
| `--verbose-csv` | Include detailed breakdown in CSV |
| `--collect-metrics` | Collect server-side Prometheus metrics |
| `-l <ms>` | Latency threshold — stop sweep if exceeded |
| `-v` | Verbose output |

### 3.9 Metrics Reported

**Per concurrency level**, perf_analyzer reports:

| Metric | Description |
|--------|-------------|
| Throughput (infer/sec) | Completed inferences per second |
| Avg latency (usec) | Mean end-to-end latency |
| p50, p90, p95, p99 latency | Percentile latencies |
| Avg server queue time | Time spent waiting in Triton's scheduler |
| Avg server compute time | Actual inference compute time |
| Avg server overhead | Triton framework overhead |

**Interpreting for MIG**: The DenseNet-121 model runs on a 2g.48gb MIG slice shared via
3x time-slicing with the OCR and Page Elements NIMs. Under heavy load, you may see
increased queue time as the GPU time-slices between workloads. This is expected — the
MIG slice provides memory isolation but shares compute cycles.

---

## 4. Recommended Benchmark Sequence

Run benchmarks in this order to build up from component-level to system-level:

### Phase 1: Component Health (5 minutes)

Verify all components are responsive before benchmarking:

```bash
# RAG server health
curl -s http://localhost:8081/v1/health?check_dependencies=true | python3 -m json.tool

# Triton server health (from inside cluster, or port-forward 8000 first)
k8s kubectl run curl-test --namespace=triton --rm -it --restart=Never \
  --image=curlimages/curl -- \
  curl -s http://triton-inference-server.triton.svc.cluster.local:8000/v2/health/ready
```

### Phase 2: Triton Standalone (15 minutes)

Benchmark Triton in isolation to establish a GPU compute baseline:

```bash
# Launch SDK pod and run concurrency sweep
k8s kubectl run perf-analyzer --namespace=triton --rm -it --restart=Never \
  --image=nvcr.io/nvidia/tritonserver:26.03-py3-sdk -- \
  perf_analyzer -m densenet_onnx \
    -u triton-inference-server.triton.svc.cluster.local:8001 \
    -i grpc --concurrency-range=1:8:1 --percentile=95
```

### Phase 3: RAG Retrieval Quality (30–60 minutes)

Run the recall notebook to verify retrieval accuracy before testing the full pipeline:

```bash
jupyter lab --ip 0.0.0.0 --port 8888 --no-browser \
  --notebook-dir=/workspace/lenovo_nvidia_rag_blueprint/rag_blueprint_lenovo/notebooks
```

Open `evaluation_02_recall.ipynb`, adjust the collection name, and run all cells.

### Phase 4: RAG End-to-End Quality (1–3 hours)

Run the RAGAS notebook for full answer quality evaluation:

Open `evaluation_01_ragas.ipynb`, set `NVIDIA_API_KEY`, adjust the collection name, and
run all cells. This calls the external Mixtral-8x22B judge API for each question.

### Phase 5: RAG Load Testing (30 minutes)

```bash
# Start light, increase gradually
locust --headless --users 5  --spawn-rate 1 --run-time 2m  --host http://localhost:8081 -f benchmarks/scripts/locustfile.py
locust --headless --users 10 --spawn-rate 2 --run-time 5m  --host http://localhost:8081 -f benchmarks/scripts/locustfile.py
locust --headless --users 20 --spawn-rate 2 --run-time 5m  --host http://localhost:8081 -f benchmarks/scripts/locustfile.py
locust --headless --users 50 --spawn-rate 5 --run-time 10m --host http://localhost:8081 -f benchmarks/scripts/locustfile.py
```

Record the point where error rate exceeds 1% or p95 latency becomes unacceptable.

---

## 5. Reference Links

- [NVIDIA RAG 2.5.0 Evaluation Guide](https://docs.nvidia.com/rag/2.5.0/evaluate.html)
- [NVIDIA Accuracy Benchmarks](https://docs.nvidia.com/rag/2.5.0/accuracy-benchmarks.html)
- [RAGAS NVIDIA Metrics](https://docs.ragas.io/en/stable/concepts/metrics/available_metrics/nvidia_metrics/)
- [Triton perf_analyzer Documentation](https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/client/perf_analyzer/docs/cli.html)
- [Locust Documentation](https://docs.locust.io/en/stable/)
- [Triton Model Analyzer](https://docs.nvidia.com/deeplearning/triton-inference-server/user-guide/docs/client/model_analyzer/README.html) (advanced — for finding optimal model configuration)
