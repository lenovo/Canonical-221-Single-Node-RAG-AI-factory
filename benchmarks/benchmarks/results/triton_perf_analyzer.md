# Triton Inference Server Benchmark Results
# Model: densenet_onnx (DenseNet-121, ONNX, FP32)
# GPU: NVIDIA RTX PRO 6000 Blackwell (2g.48gb MIG slice, 3x time-slicing)
# Server: Triton 26.03
# Tool: perf_analyzer (from tritonserver:26.03-py3-sdk)
# Date: 2026-04-10
# Measurement window: 10000ms per concurrency level

## HTTP Protocol (port 8000)

| Concurrency | Throughput (infer/sec) | p50 (usec) | p90 (usec) | p95 (usec) | p99 (usec) | Avg Compute (usec) | Avg Queue (usec) |
|-------------|----------------------|------------|------------|------------|------------|--------------------|--------------------|
| 1 | 192.4 | 4769 | 4960 | 5171 | 5274 | 4059 | 19 |
| 2 | 243.5 | 8042 | 8084 | 8108 | 8683 | 3951 | 3380 |
| 3 | 245.1 | 12036 | 12095 | 12132 | 12711 | 3969 | 7435 |
| 4 | 241.0 | 16403 | 16495 | 16542 | 17096 | 4050 | 11663 |
| 5 | 240.0 | 20596 | 20675 | 20717 | 22850 | 4067 | 15960 |
| 6 | 241.2 | 24635 | 24733 | 24780 | 28446 | 4051 | 20014 |
| 7 | 241.0 | 28846 | 29020 | 29162 | 29980 | 4054 | 24183 |
| 8 | 245.1 | 32129 | 32731 | 34507 | 38962 | 3992 | 27836 |

## gRPC Protocol (port 8001)

| Concurrency | Throughput (infer/sec) | p50 (usec) | p90 (usec) | p95 (usec) | p99 (usec) | Avg Compute (usec) | Avg Queue (usec) |
|-------------|----------------------|------------|------------|------------|------------|--------------------|--------------------|
| 1 | 196.9 | 4782 | 4938 | 4984 | 5204 | 4069 | 20 |
| 2 | 235.0 | 8330 | 8394 | 8420 | 8633 | 4030 | 3606 |
| 3 | 238.0 | 12439 | 12569 | 12657 | 12929 | 4031 | 7769 |
| 4 | 235.5 | 16693 | 17082 | 17280 | 20319 | 4085 | 12083 |
| 5 | 237.4 | 20852 | 20979 | 21028 | 21611 | 4059 | 16190 |
| 6 | 237.1 | 25052 | 25196 | 25549 | 25998 | 4061 | 20421 |
| 7 | 237.5 | 29212 | 29340 | 29400 | 33160 | 4063 | 24625 |
| 8 | 236.6 | 33454 | 33905 | 34200 | 38327 | 4079 | 28936 |

## Analysis

- Peak throughput: ~245 infer/sec (HTTP) / ~238 infer/sec (gRPC) at concurrency 2-3
- Compute time is constant at ~4ms regardless of concurrency (single inference, no batching)
- Queue time scales linearly with concurrency (expected for serial execution on MIG slice)
- Throughput saturates at concurrency 2 — additional concurrency only adds queuing latency
- HTTP slightly outperforms gRPC for this model (minimal marshaling overhead advantage)
- 0% error rate across all concurrency levels (7500-9200 requests per level)
- MIG 2g.48gb slice provides consistent ~4ms compute for DenseNet-121 ONNX inference
