# Benchmarks — Lenovo ThinkSystem SR650a V4 RAG Deployment

This directory contains benchmark scripts, results, and a comprehensive guide for
evaluating the NVIDIA RAG Blueprint 2.5.0 deployment on the Lenovo ThinkSystem SR650a V4
with 2x NVIDIA RTX PRO 6000 Blackwell GPUs and OpenSearch as the vector database.

## Directory Structure

```
benchmarks/
├── README.md                  # This file — replication guide + results
├── BENCHMARKING.md            # Detailed benchmarking methodology reference
├── scripts/
│   ├── run_evaluation.py      # RAGAS + Recall evaluation runner (FinanceBench)
│   ├── locustfile.py          # Locust load test definition
│   └── run_rag_benchmark.py   # Legacy custom Q&A benchmark (superseded)
├── results/
│   ├── benchmark_summary.md          # Consolidated results summary
│   ├── ragas_financebench_150q.json  # RAGAS evaluation results (per-question details)
│   ├── evaluation_financebench_150q.json # Combined evaluation results (RAGAS + recall)
│   ├── triton_perf_analyzer.md       # Triton perf_analyzer results (HTTP + gRPC)
│   ├── locust_{1,5,10,20,30,50}u_stats.csv  # Locust aggregate stats per concurrency level
│   └── locust_50u_failures.csv       # Locust failure details at 50 users
├── data/                              # Created automatically on first run
│   └── financebench/                  # FinanceBench dataset (cloned from GitHub)
└── test-data/
    └── lenovo-sr650a-v4-specs.txt  # Sample test document
```

## Prerequisites

1. **Deployed stack**: All pods in Running state (`deploy_apps.sh` completed)
2. **Port-forwards** on the server:
   ```bash
   nohup sudo k8s kubectl port-forward -n rag svc/rag-server 8081:8081 --address 0.0.0.0 > /dev/null 2>&1 &
   nohup sudo k8s kubectl port-forward -n rag svc/ingestor-server 8082:8082 --address 0.0.0.0 > /dev/null 2>&1 &
   nohup sudo k8s kubectl port-forward -n triton svc/triton-inference-server 8000:8000 --address 0.0.0.0 > /dev/null 2>&1 &
   nohup sudo k8s kubectl port-forward -n triton svc/triton-inference-server 8001:8001 --address 0.0.0.0 > /dev/null 2>&1 &
   ```
3. **SSH tunnel** (if running from a remote workstation):
   ```bash
   ssh -fN -L 8081:localhost:8081 -L 8082:localhost:8082 -L 8000:localhost:8000 -L 8001:localhost:8001 user@server-ip
   ```
4. **Python packages** (for evaluation scripts):
   ```bash
   sudo apt install -y python3-venv
   python3 -m venv ~/bench-venv
   source ~/bench-venv/bin/activate
   pip install aiohttp httpx ragas langchain-nvidia-ai-endpoints pandas tqdm requests locust
   ```
   Activate the venv (`source ~/bench-venv/bin/activate`) before running any
   benchmark commands below.
5. **NVIDIA API key** (for RAGAS evaluation only — the LLM judge calls NVIDIA API Catalog):
   ```bash
   export NVIDIA_API_KEY="nvapi-..."
   ```

## Quick Start — Replicate All Benchmarks

```bash
# 1. Verify health
curl -s http://localhost:8081/health

# 2. RAGAS evaluation (all 150 questions, ~24 min)
#    Requires NVIDIA_API_KEY and FinanceBench already ingested
NVIDIA_API_KEY="nvapi-..." python3 -u benchmarks/scripts/run_evaluation.py \
  --skip-ingest --skip-recall --num-questions 150

# 3. Recall evaluation (150 questions, ~3 min)
python3 -u benchmarks/scripts/run_evaluation.py \
  --skip-ingest --skip-ragas

# 4. Locust load tests (1, 5, 10, 20, 30, 50 users)
for users in 1 5 10 20; do
  locust --headless --users $users --spawn-rate 2 --run-time 3m \
    --host http://localhost:8081 -f benchmarks/scripts/locustfile.py \
    --csv benchmarks/results/locust_${users}u
done
for users in 30 50; do
  locust --headless --users $users --spawn-rate 5 --run-time 5m \
    --host http://localhost:8081 -f benchmarks/scripts/locustfile.py \
    --csv benchmarks/results/locust_${users}u
done

# 5. Triton perf_analyzer (run inside cluster)
sudo k8s kubectl run perf-analyzer --namespace=triton --rm -it --restart=Never \
  --image=nvcr.io/nvidia/tritonserver:26.03-py3-sdk -- \
  perf_analyzer -m densenet_onnx \
    -u triton-inference-server.triton.svc.cluster.local:8001 \
    -i grpc --concurrency-range=1:8:1 --percentile=95
```

---

## Results (2026-04-10)

### RAGAS Quality — FinanceBench

All 150 questions evaluated with `mistralai/mixtral-8x22b-instruct-v0.1` as the LLM judge
(same judge model as NVIDIA's published benchmarks).
Collection: `financebench` (84 PDFs, 40,522 chunks on OpenSearch).
Query params: `vdb_top_k=100`, `reranker_top_k=10` (NVIDIA defaults).

| Metric | Our Score | NVIDIA Baseline | Delta |
|--------|-----------|-----------------|-------|
| Answer Accuracy | **0.6067** | 0.612 | -0.9% |
| Context Relevance | **0.9350** | — | — |
| Response Groundedness | **0.8633** | — | — |

Our Answer Accuracy is within 0.9% of NVIDIA's published baseline — near parity.
See `results/benchmark_summary.md` for analysis.

### Search / Recall — FinanceBench

150 questions, `POST /v1/search` endpoint.

| Metric | Value |
|--------|-------|
| Avg search latency | **945 ms** |
| Min / Max latency | 656 / 1,617 ms |
| Avg results per query | 6.6 |

### RAG Load Testing — Locust

0% failure rate at 1-30 users. 0.23% failure rate at 50 users (connection saturation).

| Users | Total Reqs | Failure Rate | Req/s | Generate Avg (ms) | Generate p50 (ms) | Generate p95 (ms) | Search Avg (ms) |
|-------|------------|-------------|-------|-------------------|-------------------|-------------------|-----------------|
| 1 | 30 | 0% | 0.25 | 2,887 | 1,200 | 11,000 | 944 |
| 5 | 238 | 0% | 1.32 | 2,676 | 2,100 | 6,500 | 588 |
| 10 | 455 | 0% | 2.53 | 2,819 | 2,100 | 6,600 | 554 |
| 20 | 919 | 0% | 5.12 | 2,839 | 2,200 | 7,200 | 630 |
| 30 | 2,069 | 0% | 6.93 | 3,582 | 2,500 | 10,000 | 746 |
| 50 | 3,006 | 0.23% | 10.06 | 4,133 | 3,400 | 9,500 | 1,541 |

Generate latency stays stable at ~2.8s avg across 1-20 users, rising to ~3.6s at 30
and ~4.1s at 50 users. Throughput scales near-linearly to 10.06 req/s at 50 users.
Recommended operating range: 20-30 concurrent users.

### Triton — DenseNet-121 ONNX

Peak throughput: **~245 infer/sec** (HTTP), **~238 infer/sec** (gRPC) at concurrency 2-3.
Compute time constant at ~4ms. 0% error rate.
See `results/triton_perf_analyzer.md` for full concurrency sweep tables.

---

## Evaluation Scripts

### `scripts/run_evaluation.py`

Standalone script that reproduces the NVIDIA evaluation notebooks without Jupyter:

```bash
# Full pipeline: clone FinanceBench, ingest, run RAGAS + recall
python3 -u benchmarks/scripts/run_evaluation.py

# Skip ingestion (data already loaded)
python3 -u benchmarks/scripts/run_evaluation.py --skip-ingest

# RAGAS only (requires NVIDIA_API_KEY)
python3 -u benchmarks/scripts/run_evaluation.py --skip-ingest --skip-recall

# Recall only (no API key needed)
python3 -u benchmarks/scripts/run_evaluation.py --skip-ingest --skip-ragas

# Custom number of RAGAS questions (default: 50)
python3 -u benchmarks/scripts/run_evaluation.py --skip-ingest --num-questions 150
```

Environment variables:
- `NVIDIA_API_KEY` — Required for RAGAS (LLM judge)
- `RAG_SERVER_URL` — Default: `http://localhost:8081`
- `INGESTOR_URL` — Default: `http://localhost:8082`

### `scripts/locustfile.py`

Locust load test with three weighted tasks:
- `generate` (3x weight) — full RAG pipeline via `POST /v1/generate` (SSE streaming)
- `search` (1x weight) — retrieval only via `POST /v1/search`
- `health` (1x weight) — baseline health check via `GET /v1/health`

Uses 20 FinanceBench questions with the `financebench` collection.

```bash
# Headless with CSV output
locust --headless --users 10 --spawn-rate 2 --run-time 5m \
  --host http://localhost:8081 -f benchmarks/scripts/locustfile.py \
  --csv benchmarks/results/locust_10u

# Web UI (charts at http://localhost:8089)
locust --host http://localhost:8081 -f benchmarks/scripts/locustfile.py
```

---

## FinanceBench Ingestion

If you need to re-ingest the FinanceBench dataset:

```bash
# Option 1: Via the evaluation script (all 84 referenced PDFs)
python3 -u benchmarks/scripts/run_evaluation.py --skip-ragas --skip-recall

# Option 2: Manual upload via the ingestor API
curl -X POST http://localhost:8082/collection \
  -H "Content-Type: application/json" \
  -d '{"collection_name": "financebench"}'

# Then upload PDFs (batch of 10 at a time recommended):
curl -X POST http://localhost:8082/documents \
  -F "documents=@file1.pdf" -F "documents=@file2.pdf" ... \
  -F 'data={"collection_name":"financebench","blocking":true,"split_options":{"chunk_size":512,"chunk_overlap":150}}'
```

**Important**: NV-Ingest can deadlock with large concurrent batches. Upload in batches
of 10 PDFs with `blocking: true`. Each batch takes 60-130 seconds.

---

## Further Reading

- `BENCHMARKING.md` — Detailed methodology, Triton `perf_analyzer` flags, tuning parameters
- `results/benchmark_summary.md` — Full results with analysis
- [NVIDIA RAG 2.5.0 Evaluation Guide](https://docs.nvidia.com/rag/2.5.0/evaluate.html)
- [NVIDIA Accuracy Benchmarks](https://docs.nvidia.com/rag/2.5.0/accuracy-benchmarks.html)
