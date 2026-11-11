#!/usr/bin/env python3
"""
RAG Benchmark Script — Ingests test documents, runs quality and load tests.

This script:
1. Creates a benchmark collection in the RAG pipeline
2. Uploads test documents
3. Waits for ingestion to complete
4. Runs search (retrieval) quality tests
5. Runs generate (end-to-end RAG) quality tests
6. Runs load tests with increasing concurrency
7. Saves all results to benchmarks/results/

Usage:
    pip install requests locust
    python3 benchmarks/scripts/run_rag_benchmark.py --rag-url http://localhost:8081 --ingestor-url http://localhost:8082

Requirements:
    - RAG server accessible at the specified URL
    - Ingestor server accessible at the specified URL
    - Test documents in benchmarks/test-data/
"""

import argparse
import json
import os
import sys
import time
import subprocess
import requests
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
BENCH_DIR = SCRIPT_DIR.parent
RESULTS_DIR = BENCH_DIR / "results"
TEST_DATA_DIR = BENCH_DIR / "test-data"

COLLECTION_NAME = "benchmark_collection"

# Ground-truth Q&A pairs for the Lenovo SR650a V4 specs document.
# Each entry: (question, expected_answer_substring, expected_source_file)
QA_PAIRS = [
    (
        "What is the maximum memory capacity of the SR650a V4?",
        "4.6 TB",
        "lenovo-sr650a-v4-specs.txt",
    ),
    (
        "How many GPU accelerators does the SR650a V4 support?",
        "four",
        "lenovo-sr650a-v4-specs.txt",
    ),
    (
        "What is the maximum core count of the SR650a V4 server?",
        "256",
        "lenovo-sr650a-v4-specs.txt",
    ),
    (
        "What is the base price of the SR650a V4?",
        "12,500",
        "lenovo-sr650a-v4-specs.txt",
    ),
    (
        "What management controller does the SR650a V4 use?",
        "XClarity",
        "lenovo-sr650a-v4-specs.txt",
    ),
    (
        "What is the idle power consumption of the SR650a V4?",
        "350W",
        "lenovo-sr650a-v4-specs.txt",
    ),
    (
        "What is the depth of the SR650a V4 server?",
        "868mm",
        "lenovo-sr650a-v4-specs.txt",
    ),
    (
        "What InfiniBand bandwidth does the server support?",
        "400 Gb/s",
        "lenovo-sr650a-v4-specs.txt",
    ),
    (
        "What is the recommended operating system for AI workloads?",
        "Ubuntu 24.04",
        "lenovo-sr650a-v4-specs.txt",
    ),
    (
        "What is the maximum weight of a fully configured SR650a V4?",
        "35 kg",
        "lenovo-sr650a-v4-specs.txt",
    ),
    (
        "How much GDDR7 memory does the RTX PRO 6000 Blackwell have?",
        "96 GB",
        "lenovo-sr650a-v4-specs.txt",
    ),
    (
        "What is the INT8 performance of the RTX PRO 6000 Blackwell?",
        "4,000 TOPS",
        "lenovo-sr650a-v4-specs.txt",
    ),
    (
        "How many drive bays does the SR650a V4 have in total?",
        "20",
        "lenovo-sr650a-v4-specs.txt",
    ),
    (
        "What is the standard warranty period?",
        "3-year",
        "lenovo-sr650a-v4-specs.txt",
    ),
    (
        "What is the maximum raw storage capacity?",
        "368 TB",
        "lenovo-sr650a-v4-specs.txt",
    ),
]


def log(msg: str):
    ts = datetime.now(timezone.utc).strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def wait_for_service(url: str, name: str, timeout: int = 60):
    """Wait for a service to become healthy."""
    log(f"Waiting for {name} at {url} ...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            r = requests.get(f"{url}/health", timeout=5)
            if r.status_code == 200:
                log(f"  {name} is healthy.")
                return True
        except requests.ConnectionError:
            pass
        time.sleep(2)
    log(f"  ERROR: {name} not healthy after {timeout}s")
    return False


def create_collection(ingestor_url: str) -> bool:
    """Create the benchmark collection."""
    log(f"Creating collection '{COLLECTION_NAME}' ...")
    try:
        r = requests.post(
            f"{ingestor_url}/collection",
            json={"collection_name": COLLECTION_NAME},
            timeout=30,
        )
        if r.status_code in (200, 201, 409):  # 409 = already exists
            log(f"  Collection ready (status {r.status_code}).")
            return True
        log(f"  Failed: {r.status_code} {r.text[:200]}")
        return False
    except Exception as e:
        log(f"  Error: {e}")
        return False


def upload_documents(ingestor_url: str) -> bool:
    """Upload all test documents to the benchmark collection."""
    log("Uploading test documents ...")
    files = list(TEST_DATA_DIR.glob("*"))
    if not files:
        log("  ERROR: No test documents found in benchmarks/test-data/")
        return False

    for fpath in files:
        if fpath.name.startswith("."):
            continue
        log(f"  Uploading {fpath.name} ...")
        with open(fpath, "rb") as f:
            r = requests.post(
                f"{ingestor_url}/documents",
                files={"file": (fpath.name, f)},
                data={"collection_name": COLLECTION_NAME},
                timeout=120,
            )
        if r.status_code in (200, 201, 202):
            log(f"    OK (status {r.status_code})")
        else:
            log(f"    WARN: status {r.status_code}: {r.text[:200]}")

    return True


def wait_for_ingestion(ingestor_url: str, timeout: int = 300) -> bool:
    """Wait for ingestion to complete by polling collection status."""
    log(f"Waiting for ingestion to complete (timeout {timeout}s) ...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            r = requests.get(f"{ingestor_url}/collections", timeout=10)
            if r.status_code == 200:
                data = r.json()
                for coll in data.get("collections", []):
                    if coll["collection_name"] == COLLECTION_NAME:
                        info = coll.get("collection_info", {})
                        status = info.get("ingestion_status", "")
                        count = coll.get("num_entities", 0)
                        log(f"  Status: {status}, entities: {count}")
                        if status == "Success" and count > 0:
                            return True
                        if status == "Failed":
                            log(
                                f"  Ingestion FAILED: {info.get('last_ingestion_error', '')}"
                            )
                            return False
        except Exception as e:
            log(f"  Poll error: {e}")
        time.sleep(5)
    log("  Timeout waiting for ingestion.")
    return False


def run_search_benchmark(rag_url: str) -> dict:
    """Run retrieval (search) quality benchmark."""
    log("=" * 60)
    log("SEARCH (RETRIEVAL) QUALITY BENCHMARK")
    log("=" * 60)

    results = []
    for i, (question, expected, source_file) in enumerate(QA_PAIRS):
        log(f"  [{i + 1}/{len(QA_PAIRS)}] {question}")
        try:
            r = requests.post(
                f"{rag_url}/v1/search",
                json={
                    "query": question,
                    "vdb_top_k": 10,
                    "collection_names": [COLLECTION_NAME],
                    "enable_reranker": True,
                },
                timeout=60,
            )
            latency_ms = r.elapsed.total_seconds() * 1000

            if r.status_code != 200:
                log(f"    ERROR: status {r.status_code}")
                results.append(
                    {
                        "question": question,
                        "expected": expected,
                        "status": "error",
                        "latency_ms": latency_ms,
                    }
                )
                continue

            data = r.json()
            search_results = data.get("results", [])

            # Check if expected content appears in any result
            found_content = False
            found_source = False
            best_score = 0.0
            rank_of_answer = -1

            for rank, res in enumerate(search_results):
                content = res.get("content", "")
                doc_name = res.get("document_name", "")
                score = res.get("score", 0.0)

                if expected.lower() in content.lower() and not found_content:
                    found_content = True
                    rank_of_answer = rank + 1
                    best_score = score

                if source_file and source_file in doc_name:
                    found_source = True

            result = {
                "question": question,
                "expected": expected,
                "found_in_results": found_content,
                "correct_source_found": found_source,
                "rank_of_answer": rank_of_answer,
                "best_score": best_score,
                "num_results": len(search_results),
                "latency_ms": round(latency_ms, 1),
                "status": "ok",
            }
            results.append(result)

            status = "PASS" if found_content else "MISS"
            log(
                f"    {status} | rank={rank_of_answer} | score={best_score:.4f} | latency={latency_ms:.0f}ms | results={len(search_results)}"
            )

        except Exception as e:
            log(f"    EXCEPTION: {e}")
            results.append(
                {
                    "question": question,
                    "expected": expected,
                    "status": "exception",
                    "error": str(e),
                }
            )

    # Summary
    ok_results = [r for r in results if r["status"] == "ok"]
    hits = [r for r in ok_results if r.get("found_in_results")]
    avg_latency = (
        sum(r["latency_ms"] for r in ok_results) / len(ok_results) if ok_results else 0
    )

    summary = {
        "total_questions": len(QA_PAIRS),
        "successful_queries": len(ok_results),
        "content_found_count": len(hits),
        "recall_at_10": round(len(hits) / len(ok_results), 4) if ok_results else 0,
        "avg_latency_ms": round(avg_latency, 1),
        "min_latency_ms": round(min(r["latency_ms"] for r in ok_results), 1)
        if ok_results
        else 0,
        "max_latency_ms": round(max(r["latency_ms"] for r in ok_results), 1)
        if ok_results
        else 0,
    }

    log(f"\n  SEARCH SUMMARY:")
    log(f"    Recall@10:     {summary['recall_at_10']:.2%}")
    log(f"    Avg latency:   {summary['avg_latency_ms']:.0f} ms")
    log(f"    Min latency:   {summary['min_latency_ms']:.0f} ms")
    log(f"    Max latency:   {summary['max_latency_ms']:.0f} ms")

    return {"summary": summary, "details": results}


def run_generate_benchmark(rag_url: str) -> dict:
    """Run end-to-end RAG generation quality benchmark."""
    log("=" * 60)
    log("GENERATE (END-TO-END RAG) QUALITY BENCHMARK")
    log("=" * 60)

    results = []
    for i, (question, expected, _) in enumerate(QA_PAIRS):
        log(f"  [{i + 1}/{len(QA_PAIRS)}] {question}")
        try:
            start = time.time()
            r = requests.post(
                f"{rag_url}/v1/generate",
                json={
                    "messages": [{"role": "user", "content": question}],
                    "use_knowledge_base": True,
                    "reranker_top_k": 2,
                    "vdb_top_k": 10,
                    "collection_names": [COLLECTION_NAME],
                    "enable_reranker": True,
                    "enable_citations": True,
                    "max_tokens": 512,
                },
                timeout=120,
                stream=True,
            )
            latency_ms = (time.time() - start) * 1000

            if r.status_code != 200:
                log(f"    ERROR: status {r.status_code}")
                results.append(
                    {
                        "question": question,
                        "expected": expected,
                        "status": "error",
                        "latency_ms": round(latency_ms, 1),
                    }
                )
                continue

            # Parse SSE stream
            answer_text = ""
            first_token_time = None
            for line in r.iter_lines(decode_unicode=True):
                if first_token_time is None and line:
                    first_token_time = time.time()
                if line and line.startswith("data: "):
                    data_str = line[6:]
                    if data_str.strip() == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data_str)
                        choices = chunk.get("choices", [])
                        if choices:
                            delta = choices[0].get("message", {})
                            content = delta.get("content", "")
                            if content:
                                answer_text += content
                    except json.JSONDecodeError:
                        pass

            end_time = time.time()
            total_latency_ms = (end_time - start) * 1000
            ttft_ms = (
                ((first_token_time - start) * 1000)
                if first_token_time
                else total_latency_ms
            )

            # Check if answer contains expected content
            answer_correct = expected.lower() in answer_text.lower()

            result = {
                "question": question,
                "expected": expected,
                "answer_correct": answer_correct,
                "answer_preview": answer_text[:300],
                "answer_length": len(answer_text),
                "ttft_ms": round(ttft_ms, 1),
                "total_latency_ms": round(total_latency_ms, 1),
                "status": "ok",
            }
            results.append(result)

            status = "PASS" if answer_correct else "MISS"
            log(
                f"    {status} | ttft={ttft_ms:.0f}ms | total={total_latency_ms:.0f}ms | len={len(answer_text)}"
            )

        except Exception as e:
            log(f"    EXCEPTION: {e}")
            results.append(
                {
                    "question": question,
                    "expected": expected,
                    "status": "exception",
                    "error": str(e),
                }
            )

    # Summary
    ok_results = [r for r in results if r["status"] == "ok"]
    correct = [r for r in ok_results if r.get("answer_correct")]
    avg_ttft = (
        sum(r["ttft_ms"] for r in ok_results) / len(ok_results) if ok_results else 0
    )
    avg_total = (
        sum(r["total_latency_ms"] for r in ok_results) / len(ok_results)
        if ok_results
        else 0
    )

    summary = {
        "total_questions": len(QA_PAIRS),
        "successful_queries": len(ok_results),
        "correct_answers": len(correct),
        "accuracy": round(len(correct) / len(ok_results), 4) if ok_results else 0,
        "avg_ttft_ms": round(avg_ttft, 1),
        "avg_total_latency_ms": round(avg_total, 1),
        "min_total_latency_ms": round(min(r["total_latency_ms"] for r in ok_results), 1)
        if ok_results
        else 0,
        "max_total_latency_ms": round(max(r["total_latency_ms"] for r in ok_results), 1)
        if ok_results
        else 0,
    }

    log(f"\n  GENERATE SUMMARY:")
    log(f"    Accuracy:          {summary['accuracy']:.2%}")
    log(f"    Avg TTFT:          {summary['avg_ttft_ms']:.0f} ms")
    log(f"    Avg total latency: {summary['avg_total_latency_ms']:.0f} ms")
    log(f"    Min total latency: {summary['min_total_latency_ms']:.0f} ms")
    log(f"    Max total latency: {summary['max_total_latency_ms']:.0f} ms")

    return {"summary": summary, "details": results}


def run_locust_benchmark(
    rag_url: str, users: int, spawn_rate: int, duration: str
) -> dict:
    """Run Locust load test and capture results."""
    log(f"  Locust: {users} users, spawn_rate={spawn_rate}, duration={duration}")

    locustfile = BENCH_DIR / "scripts" / "locustfile_bench.py"
    csv_prefix = RESULTS_DIR / f"locust_{users}u"

    cmd = [
        sys.executable,
        "-m",
        "locust",
        "--headless",
        f"--users={users}",
        f"--spawn-rate={spawn_rate}",
        f"--run-time={duration}",
        f"--host={rag_url}",
        f"-f",
        str(locustfile),
        f"--csv={csv_prefix}",
        "--only-summary",
    ]

    env = os.environ.copy()
    env["BENCH_COLLECTION"] = COLLECTION_NAME

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=600,
            env=env,
        )
        log(f"    Exit code: {result.returncode}")
        # Print the summary output
        for line in result.stdout.split("\n"):
            if line.strip():
                log(f"    {line}")
        if result.returncode != 0:
            for line in result.stderr.split("\n")[-10:]:
                if line.strip():
                    log(f"    STDERR: {line}")
    except subprocess.TimeoutExpired:
        log("    Locust timed out!")
    except Exception as e:
        log(f"    Error running Locust: {e}")

    # Read CSV stats if generated
    stats_file = Path(f"{csv_prefix}_stats.csv")
    if stats_file.exists():
        with open(stats_file) as f:
            return {"csv_stats": f.read(), "users": users, "duration": duration}
    return {"error": "no stats file", "users": users, "duration": duration}


def run_load_benchmarks(rag_url: str) -> list:
    """Run load tests at increasing concurrency levels."""
    log("=" * 60)
    log("RAG LOAD/THROUGHPUT BENCHMARK (Locust)")
    log("=" * 60)

    # Create the locust file that uses the benchmark collection
    locustfile = BENCH_DIR / "scripts" / "locustfile_bench.py"
    locustfile.write_text(f'''"""Auto-generated Locust file for benchmark collection."""
import os
import random
from locust import HttpUser, task, between

QUESTIONS = [
    "What is the maximum memory capacity of the SR650a V4?",
    "How many GPU accelerators does the SR650a V4 support?",
    "What is the base price of the SR650a V4?",
    "What management controller does the SR650a V4 use?",
    "What is the idle power consumption?",
    "What InfiniBand bandwidth does the server support?",
    "What is the recommended operating system for AI workloads?",
    "What is the maximum weight of a fully configured SR650a V4?",
]

COLLECTION = os.environ.get("BENCH_COLLECTION", "{COLLECTION_NAME}")

class RAGUser(HttpUser):
    wait_time = between(0.5, 1.5)

    @task(3)
    def generate(self):
        payload = {{
            "messages": [{{"role": "user", "content": random.choice(QUESTIONS)}}],
            "use_knowledge_base": True,
            "reranker_top_k": 2,
            "vdb_top_k": 10,
            "collection_names": [COLLECTION],
            "enable_reranker": True,
            "enable_citations": True,
            "max_tokens": 256,
        }}
        with self.client.post("/v1/generate", json=payload, catch_response=True, timeout=120) as resp:
            if resp.status_code != 200:
                resp.failure(f"Status {{resp.status_code}}")

    @task(1)
    def search(self):
        payload = {{
            "query": random.choice(QUESTIONS),
            "vdb_top_k": 10,
            "collection_names": [COLLECTION],
            "enable_reranker": True,
        }}
        with self.client.post("/v1/search", json=payload, catch_response=True, timeout=60) as resp:
            if resp.status_code != 200:
                resp.failure(f"Status {{resp.status_code}}")

    @task(1)
    def health(self):
        self.client.get("/v1/health")
''')

    load_results = []
    test_configs = [
        (1, 1, "60s"),  # Baseline: 1 user, 60 seconds
        (5, 1, "90s"),  # Light: 5 users
        (10, 2, "90s"),  # Moderate: 10 users
        (20, 4, "90s"),  # Heavy: 20 users
    ]

    for users, spawn_rate, duration in test_configs:
        result = run_locust_benchmark(rag_url, users, spawn_rate, duration)
        load_results.append(result)

    return load_results


def main():
    parser = argparse.ArgumentParser(description="RAG Benchmark Suite")
    parser.add_argument(
        "--rag-url", default="http://localhost:8081", help="RAG server URL"
    )
    parser.add_argument(
        "--ingestor-url", default="http://localhost:8082", help="Ingestor server URL"
    )
    parser.add_argument(
        "--skip-ingest", action="store_true", help="Skip document ingestion"
    )
    parser.add_argument(
        "--skip-search", action="store_true", help="Skip search benchmark"
    )
    parser.add_argument(
        "--skip-generate", action="store_true", help="Skip generate benchmark"
    )
    parser.add_argument("--skip-load", action="store_true", help="Skip load benchmark")
    args = parser.parse_args()

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    all_results = {
        "timestamp": timestamp,
        "rag_url": args.rag_url,
        "ingestor_url": args.ingestor_url,
        "collection": COLLECTION_NAME,
    }

    # Health checks
    log("=" * 60)
    log("HEALTH CHECKS")
    log("=" * 60)
    if not wait_for_service(args.rag_url, "RAG Server"):
        log("RAG Server not available. Aborting.")
        sys.exit(1)

    # Check dependencies
    try:
        r = requests.get(
            f"{args.rag_url}/v1/health?check_dependencies=true", timeout=30
        )
        health = r.json()
        all_results["health"] = health
        log(f"  Health details: {json.dumps(health, indent=2)}")
    except Exception as e:
        log(f"  Could not get detailed health: {e}")

    # Ingest documents
    if not args.skip_ingest:
        if not wait_for_service(args.ingestor_url, "Ingestor Server"):
            log(
                "Ingestor not available. Use --skip-ingest if documents are already loaded."
            )
            sys.exit(1)
        create_collection(args.ingestor_url)
        upload_documents(args.ingestor_url)
        wait_for_ingestion(args.ingestor_url, timeout=300)
    else:
        log("Skipping document ingestion (--skip-ingest).")

    # Search benchmark
    if not args.skip_search:
        search_results = run_search_benchmark(args.rag_url)
        all_results["search"] = search_results
    else:
        log("Skipping search benchmark (--skip-search).")

    # Generate benchmark
    if not args.skip_generate:
        generate_results = run_generate_benchmark(args.rag_url)
        all_results["generate"] = generate_results
    else:
        log("Skipping generate benchmark (--skip-generate).")

    # Load benchmark
    if not args.skip_load:
        load_results = run_load_benchmarks(args.rag_url)
        all_results["load"] = load_results
    else:
        log("Skipping load benchmark (--skip-load).")

    # Save results
    results_file = RESULTS_DIR / f"rag_benchmark_{timestamp}.json"
    with open(results_file, "w") as f:
        json.dump(all_results, f, indent=2, default=str)
    log(f"\nAll results saved to: {results_file}")

    return all_results


if __name__ == "__main__":
    main()
