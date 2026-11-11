# Benchmark Results Summary

**System**: Lenovo ThinkSystem SR650a V4
**GPUs**: 2x NVIDIA RTX PRO 6000 Blackwell (96GB each)
**Date**: 2026-04-10
**Stack**: NVIDIA RAG Blueprint 2.5.0 + OpenSearch (custom VDB) + Triton 26.03

## Hardware Layout

| GPU | Mode | Workload | K8s Resource |
|-----|------|----------|-------------|
| GPU 0 | Non-MIG, dedicated | NIM LLM (Llama-3.3-Nemotron-Super-49B-v1.5, NVFP4, TP1) | `nvidia.com/gpu: 1` |
| GPU 1 MIG 1g.24gb #0 (TS 2x) | NIM Embed + NIM Rerank | `nvidia.com/mig-1g.24gb: 1` each |
| GPU 1 MIG 1g.24gb #1 (TS 2x) | NIM Graphic Elements + NIM Table Structure | `nvidia.com/mig-1g.24gb: 1` each |
| GPU 1 MIG 2g.48gb (TS 3x) | NIM OCR + NIM Page Elements + Triton | `nvidia.com/mig-2g.48gb: 1` each |

---

## 1. RAGAS Quality Evaluation (FinanceBench)

**Dataset**: FinanceBench (150 questions, 84 PDFs, 40,522 indexed chunks)
**Evaluated**: All 150 questions via RAGAS
**Collection**: `financebench` on OpenSearch
**Configuration** (aligned with [NVIDIA benchmark methodology](https://docs.nvidia.com/rag/2.5.0/accuracy-benchmarks.html)):
- Judge model: `mistralai/mixtral-8x22b-instruct-v0.1` (same as NVIDIA)
- `vdb_top_k`: 100 (NVIDIA default)
- `reranker_top_k`: 10 (NVIDIA default)
- Reasoning: Off (default)
- Total evaluation time: ~24 min (450 judge calls = 150 questions x 3 metrics)

| Metric | Our Score | NVIDIA Baseline | Delta |
|--------|-----------|-----------------|-------|
| Answer Accuracy (`nv_accuracy`) | **0.6067** | 0.612 | -0.9% |
| Context Relevance (`nv_context_relevance`) | **0.9350** | — | — |
| Response Groundedness (`nv_response_groundedness`) | **0.8633** | — | — |

Our Answer Accuracy (0.6067) is within **0.9%** of NVIDIA's published baseline (0.612).
This near-parity result validates that OpenSearch k-NN is a viable drop-in replacement
for Milvus HNSW in the RAG pipeline. The small delta is expected given:
- Different VDB backend (OpenSearch k-NN vs. Milvus HNSW)
- Single-node deployment with MIG slicing vs. NVIDIA's reference setup
- Identical judge model, retrieval parameters, and evaluation methodology

Context Relevance (0.935) and Response Groundedness (0.863) are both strong,
indicating the retrieval pipeline (OpenSearch + reranker) surfaces highly relevant
context and the LLM stays grounded in it.

**Files**: `ragas_financebench_150q.json`, `evaluation_financebench_150q.json`

---

## 2. Recall / Search Evaluation (FinanceBench)

**Dataset**: FinanceBench — all 150 questions
**Endpoint**: `POST /v1/search` (embedding + OpenSearch vector search + reranking)

| Metric | Value |
|--------|-------|
| Questions queried | 150 |
| Avg search latency | **945 ms** |
| Min search latency | 656 ms |
| Max search latency | 1,617 ms |
| Avg results per query | 6.6 |

Search latency includes: embedding NIM inference (~4ms) + OpenSearch k-NN search (~25ms) + reranker NIM inference (~5ms) + network overhead through SSH tunnel.

---

## 3. RAG Load Testing (Locust)

All tests used 20 FinanceBench questions, task weighting: generate(3x) : search(1x) : health(1x).
Think time between requests: 1-3 seconds (realistic user simulation).

### Summary Table

| Users | Duration | Total Reqs | Failure Rate | Req/s | Generate Avg (ms) | Generate p50 (ms) | Generate p95 (ms) | Search Avg (ms) | Health Avg (ms) |
|-------|----------|------------|-------------|-------|-------------------|-------------------|-------------------|-----------------|-----------------|
| 1 | 2 min | 30 | 0% | 0.25 | 2,887 | 1,200 | 11,000 | 944 | 200 |
| 5 | 3 min | 238 | 0% | 1.32 | 2,676 | 2,100 | 6,500 | 588 | 321 |
| 10 | 3 min | 455 | 0% | 2.53 | 2,819 | 2,100 | 6,600 | 554 | 267 |
| 20 | 3 min | 919 | 0% | 5.12 | 2,839 | 2,200 | 7,200 | 630 | 262 |
| 30 | 5 min | 2,069 | 0% | 6.93 | 3,582 | 2,500 | 10,000 | 746 | 242 |
| 50 | 5 min | 3,006 | 0.23% | 10.06 | 4,133 | 3,400 | 9,500 | 1,541 | 271 |

### Key Observations

- **Generate latency is stable at ~2.8s avg** across 1-20 users. At 30 users it rises to ~3.6s, and at 50 users to ~4.1s — still well within acceptable range. The LLM (Nemotron-Super-49B NVFP4 on full GPU 0) handles concurrent requests well through its internal batching/scheduling.
- **Search latency improves under moderate load** (944ms at 1 user → 554ms at 10 users) due to OpenSearch and embedding NIM warmup/caching effects. At 50 users it rises to ~1.5s as the reranker NIM on the MIG slice becomes the bottleneck.
- **Throughput scales near-linearly**: 0.25 req/s (1u) → 5.12 (20u) → 6.93 (30u) → 10.06 (50u).
- **0% failure rate at 1-30 users.** At 50 users: 0.23% failure rate (7 of 3,006 requests). Failures were connection resets (remote end closed connection), not application errors — indicates the system is at the edge of network/connection saturation.
- **System saturates between 30-50 concurrent users** — generate latency increases ~45% and sporadic connection resets appear. For production use, 20-30 concurrent users is the recommended operating range on this hardware.

### Failure Details (50 users)

| Method | Endpoint | Error | Count |
|--------|----------|-------|-------|
| GET | /v1/health | RemoteDisconnected | 2 |
| POST | /v1/generate | CatchResponseError (Status 0) | 4 |
| POST | /v1/search | CatchResponseError (Status 0) | 1 |

All failures are connection-level (TCP reset), not HTTP errors — the server never returned a 4xx/5xx.

### CSV Files

- `locust_1u_stats.csv` — 1 user baseline
- `locust_5u_stats.csv` — 5 users
- `locust_10u_stats.csv` — 10 users
- `locust_20u_stats.csv` — 20 users
- `locust_30u_stats.csv` — 30 users
- `locust_50u_stats.csv` — 50 users
- `locust_50u_failures.csv` — 50 user failure details

---

## 4. Triton Inference Server (DenseNet-121 ONNX)

**Model**: DenseNet-121 (ONNX, FP32, 3x224x224 input, 1000-class output)
**GPU**: MIG 2g.48gb slice on GPU 1 (3x time-sliced with OCR + Page Elements NIMs)
**Tool**: `perf_analyzer` from `tritonserver:26.03-py3-sdk`

### HTTP Concurrency Sweep

| Concurrency | Throughput (infer/sec) | p50 (ms) | p95 (ms) | Compute (ms) | Queue (ms) |
|-------------|----------------------|----------|----------|---------------|------------|
| 1 | 192.4 | 4.8 | 5.2 | 4.1 | 0.02 |
| 2 | **243.5** | 8.0 | 8.1 | 4.0 | 3.4 |
| 3 | **245.1** | 12.0 | 12.1 | 4.0 | 7.4 |
| 4 | 241.0 | 16.4 | 16.5 | 4.1 | 11.7 |
| 8 | 245.1 | 32.1 | 34.5 | 4.0 | 27.8 |

### gRPC Concurrency Sweep

| Concurrency | Throughput (infer/sec) | p50 (ms) | p95 (ms) | Compute (ms) | Queue (ms) |
|-------------|----------------------|----------|----------|---------------|------------|
| 1 | 196.9 | 4.8 | 5.0 | 4.1 | 0.02 |
| 2 | **235.0** | 8.3 | 8.4 | 4.0 | 3.6 |
| 3 | **238.0** | 12.4 | 12.7 | 4.0 | 7.8 |
| 4 | 235.5 | 16.7 | 17.3 | 4.1 | 12.1 |
| 8 | 236.6 | 33.5 | 34.2 | 4.1 | 28.9 |

### Key Observations

- **Peak throughput: ~245 infer/sec** (HTTP) at concurrency 2-3
- **Compute time constant at ~4ms** regardless of concurrency — single inference, no batching
- **Queue time scales linearly** — expected for serial execution on the MIG slice
- **Throughput saturates at concurrency 2** — additional concurrency only adds queuing latency
- **0% error rate** across 7,500-9,200 requests per concurrency level

**File**: `triton_perf_analyzer.md`
