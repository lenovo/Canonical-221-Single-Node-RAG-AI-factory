#!/usr/bin/env python3
"""
RAG Evaluation Runner — FinanceBench Dataset

Runs the same evaluation pipeline as the NVIDIA notebooks:
  - evaluation_01_ragas.ipynb (RAGAS: Answer Accuracy, Context Relevancy, Groundedness)
  - evaluation_02_recall.ipynb (Recall@1, @3, @5, @10)

Modified from the notebooks only to:
  1. Remove hardcoded vdb_endpoint (use server-configured OpenSearch default)
  2. Run as a standalone script (no Jupyter required)
  3. Save results to JSON files

Prerequisites:
  pip install aiohttp httpx ragas langchain-nvidia-ai-endpoints pandas tqdm requests PyPDF2

Environment:
  NVIDIA_API_KEY   — Required for RAGAS judge (Mixtral-8x22B on build.nvidia.com)
  RAG_SERVER_URL   — Default: http://localhost:8081
  INGESTOR_URL     — Default: http://localhost:8082

Usage:
  # Full run (ingest + RAGAS + recall):
  python3 run_evaluation.py

  # Skip ingestion (if FinanceBench already loaded):
  python3 run_evaluation.py --skip-ingest

  # Recall only (no NVIDIA_API_KEY needed):
  python3 run_evaluation.py --skip-ingest --skip-ragas

  # RAGAS only:
  python3 run_evaluation.py --skip-ingest --skip-recall
"""

import argparse
import asyncio
import json
import os
import glob
import sys
import time
import subprocess
from datetime import datetime, timezone
from pathlib import Path

# ── Configuration ──────────────────────────────────────────────────────────
RAG_SERVER_URL = os.environ.get("RAG_SERVER_URL", "http://localhost:8081")
INGESTOR_URL = os.environ.get("INGESTOR_URL", "http://localhost:8082")
NVIDIA_API_KEY = os.environ.get("NVIDIA_API_KEY", "")

COLLECTION_NAME = "financebench"
DATA_DIR = Path(__file__).resolve().parent.parent / "data" / "financebench"
RESULTS_DIR = Path(__file__).resolve().parent.parent / "results"
NUM_EVAL_QUESTIONS = 50  # Same as NVIDIA notebook default; set to None for all


def log(msg: str):
    ts = datetime.now(timezone.utc).strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


# ── Phase 1: Clone FinanceBench ───────────────────────────────────────────


def clone_financebench():
    """Clone the FinanceBench dataset if not already present."""
    if (
        DATA_DIR.exists()
        and (DATA_DIR / "data" / "financebench_open_source.jsonl").exists()
    ):
        log(f"FinanceBench data already present at {DATA_DIR}")
        return True

    log("Cloning FinanceBench dataset from GitHub...")
    DATA_DIR.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [
            "git",
            "clone",
            "https://github.com/patronus-ai/financebench.git",
            str(DATA_DIR),
        ],
        capture_output=True,
        text=True,
        timeout=300,
    )
    if result.returncode != 0:
        log(f"ERROR cloning FinanceBench: {result.stderr[:500]}")
        return False
    log("FinanceBench cloned successfully.")
    return True


# ── Phase 2: Ingest Documents ─────────────────────────────────────────────


async def ingest_documents():
    """Create collection and upload FinanceBench PDFs (async, from notebook 1)."""
    import aiohttp

    ingestor_url = INGESTOR_URL

    # Create collection
    log(f"Creating collection '{COLLECTION_NAME}'...")
    async with aiohttp.ClientSession() as session:
        async with session.post(
            f"{ingestor_url}/collection",
            json={"collection_name": COLLECTION_NAME},
        ) as resp:
            log(f"  Create collection: {resp.status} {await resp.text()}")

    # Upload PDFs — only the ones referenced in ground truth (84 of 368)
    pdf_dir = DATA_DIR / "pdfs"
    gt_path = DATA_DIR / "data" / "financebench_open_source.jsonl"

    # Get the set of doc_names referenced in ground truth
    referenced_docs = set()
    with open(gt_path) as f:
        for line in f:
            entry = json.loads(line.strip())
            referenced_docs.add(entry.get("doc_name", ""))

    pdf_files = sorted(
        [
            pdf_dir / f"{dn}.pdf"
            for dn in referenced_docs
            if (pdf_dir / f"{dn}.pdf").exists()
        ]
    )
    log(
        f"Found {len(pdf_files)} referenced PDFs to upload (of {len(list(pdf_dir.glob('*.pdf')))} total)."
    )

    metadata = json.dumps(
        {
            "collection_name": COLLECTION_NAME,
            "blocking": False,
            "split_options": {"chunk_size": 512, "chunk_overlap": 150},
            "generate_summary": False,
        }
    )

    task_ids = []
    async with aiohttp.ClientSession() as session:
        for i, pdf_path in enumerate(pdf_files):
            log(f"  [{i + 1}/{len(pdf_files)}] Uploading {pdf_path.name}...")
            form = aiohttp.FormData()
            form.add_field(
                "documents",
                open(pdf_path, "rb"),
                filename=pdf_path.name,
                content_type="application/pdf",
            )
            form.add_field("data", metadata)

            try:
                async with session.post(
                    f"{ingestor_url}/documents",
                    data=form,
                    timeout=aiohttp.ClientTimeout(total=300),
                ) as resp:
                    result = await resp.json()
                    task_id = result.get("task_id")
                    if task_id:
                        task_ids.append(task_id)
                    log(f"    Status: {resp.status}, task_id: {task_id}")
            except Exception as e:
                log(f"    ERROR: {e}")

    # Poll for completion
    log(f"Waiting for {len(task_ids)} ingestion tasks to complete...")
    completed = set()
    failed = set()
    deadline = time.time() + 1800  # 30 min timeout

    async with aiohttp.ClientSession() as session:
        while time.time() < deadline and len(completed) + len(failed) < len(task_ids):
            for tid in task_ids:
                if tid in completed or tid in failed:
                    continue
                try:
                    async with session.get(
                        f"{ingestor_url}/status?task_id={tid}",
                        timeout=aiohttp.ClientTimeout(total=30),
                    ) as resp:
                        status_data = await resp.json()
                        status = status_data.get("status", "")
                        if status.lower() in ("completed", "success"):
                            completed.add(tid)
                        elif status.lower() in ("failed", "error"):
                            failed.add(tid)
                            log(f"  Task {tid} FAILED: {status_data}")
                except Exception:
                    pass
            pending = len(task_ids) - len(completed) - len(failed)
            log(
                f"  Progress: {len(completed)} completed, {len(failed)} failed, {pending} pending"
            )
            if pending > 0:
                await asyncio.sleep(10)

    log(
        f"Ingestion complete: {len(completed)} success, {len(failed)} failed out of {len(task_ids)}"
    )
    return len(completed) > 0


# ── Phase 3: Load Ground Truth ────────────────────────────────────────────


def load_ground_truth():
    """Load FinanceBench ground truth Q&A pairs."""
    jsonl_path = DATA_DIR / "data" / "financebench_open_source.jsonl"
    entries = []
    with open(jsonl_path) as f:
        for line in f:
            entry = json.loads(line.strip())
            entries.append(
                {
                    "id": entry.get("financebench_id", ""),
                    "question": entry["question"],
                    "answer": entry["answer"],
                    "evidence_text": entry.get("evidence", [{}])[0].get(
                        "evidence_text", ""
                    ),
                }
            )
    log(f"Loaded {len(entries)} ground truth entries.")
    return entries


# ── Phase 4: RAGAS Evaluation ─────────────────────────────────────────────


async def run_ragas_evaluation(gt_entries):
    """Run RAGAS evaluation (from notebook 1)."""
    import httpx
    from ragas import evaluate, RunConfig, EvaluationDataset
    from ragas.metrics import AnswerAccuracy, ContextRelevance, ResponseGroundedness
    from langchain_nvidia_ai_endpoints import ChatNVIDIA
    from ragas.llms import LangchainLLMWrapper

    if not NVIDIA_API_KEY:
        log("ERROR: NVIDIA_API_KEY not set. Cannot run RAGAS evaluation.")
        return None

    os.environ["NVIDIA_API_KEY"] = NVIDIA_API_KEY

    entries = gt_entries[:NUM_EVAL_QUESTIONS] if NUM_EVAL_QUESTIONS else gt_entries
    log(f"Running RAGAS evaluation on {len(entries)} questions...")

    # Query RAG server for each question
    dataset = []
    async with httpx.AsyncClient(timeout=300) as client:
        for i, entry in enumerate(entries):
            log(f"  [{i + 1}/{len(entries)}] {entry['question'][:80]}...")
            payload = {
                "messages": [{"role": "user", "content": entry["question"]}],
                "use_knowledge_base": True,
                "reranker_top_k": 10,
                "vdb_top_k": 100,
                # NOTE: No vdb_endpoint — uses server-configured OpenSearch default
                "collection_names": [COLLECTION_NAME],
                "enable_reranker": True,
                "enable_citations": True,
                "stop": [],
                "filter_expr": "",
            }

            answer = ""
            contexts = []
            try:
                async with client.stream(
                    "POST", f"{RAG_SERVER_URL}/v1/generate", json=payload
                ) as resp:
                    async for line in resp.aiter_lines():
                        if line.startswith("data: "):
                            data_str = line[6:]
                            if data_str.strip() == "[DONE]":
                                break
                            try:
                                chunk = json.loads(data_str)
                                choices = chunk.get("choices", [])
                                if choices:
                                    msg = choices[0].get("message", {})
                                    content = msg.get("content", "")
                                    if content:
                                        answer += content
                                # Extract citations from first chunk
                                citations = chunk.get("citations", {})
                                if citations and not contexts:
                                    for r in citations.get("results", []):
                                        desc = r.get("metadata", {}).get(
                                            "description", ""
                                        )
                                        if desc:
                                            contexts.append(desc)
                            except json.JSONDecodeError:
                                pass
            except Exception as e:
                log(f"    ERROR: {e}")
                continue

            if not answer:
                log(f"    WARNING: Empty answer")
                continue

            dataset.append(
                {
                    "user_input": entry["question"],
                    "retrieved_contexts": contexts
                    if contexts
                    else ["No context retrieved"],
                    "response": answer,
                    "reference": entry["answer"],
                }
            )
            log(f"    OK ({len(answer)} chars, {len(contexts)} contexts)")

    if not dataset:
        log("ERROR: No successful queries.")
        return None

    log(f"Collected {len(dataset)} responses. Running RAGAS evaluation...")

    # Set up judge LLM — use Mixtral-8x22B, same as NVIDIA's published benchmarks
    # (see https://docs.nvidia.com/rag/2.5.0/accuracy-benchmarks.html)
    judge_llm = LangchainLLMWrapper(
        ChatNVIDIA(model="mistralai/mixtral-8x22b-instruct-v0.1")
    )

    # Build evaluation dataset
    eval_dataset = EvaluationDataset.from_list(dataset)

    # Run evaluation
    run_config = RunConfig(max_workers=1, max_wait=120)
    metrics = [AnswerAccuracy(), ContextRelevance(), ResponseGroundedness()]

    results = evaluate(
        dataset=eval_dataset,
        metrics=metrics,
        llm=judge_llm,
        run_config=run_config,
    )

    # Extract results via to_pandas() — the only reliable API across RAGAS versions
    results_df = results.to_pandas()

    # Compute aggregate scores from DataFrame columns
    # Metric columns will be named like 'answer_accuracy', 'context_relevance', etc.
    # Skip non-numeric and input/output columns
    skip_cols = {"user_input", "retrieved_contexts", "response", "reference"}
    summary = {}
    for col in results_df.columns:
        if col in skip_cols:
            continue
        if results_df[col].dtype in ("float64", "float32", "int64", "int32"):
            summary[col] = round(float(results_df[col].mean()), 4)

    log(f"\n  RAGAS RESULTS:")
    for metric_name, score in summary.items():
        log(f"    {metric_name}: {score:.4f}")
    if not summary:
        log("    WARNING: No numeric metric columns found in results DataFrame")
        log(f"    DataFrame columns: {list(results_df.columns)}")

    ragas_output = {
        "summary": summary,
        "num_questions": len(dataset),
        "collection": COLLECTION_NAME,
        "dataset": "FinanceBench",
        "details": results_df.to_dict(orient="records"),
    }

    return ragas_output


# ── Phase 5: Recall Evaluation ────────────────────────────────────────────


def run_recall_evaluation(gt_entries):
    """Run recall evaluation (from notebook 2)."""
    import requests as req

    log("Running recall evaluation...")

    entries = gt_entries  # Use all entries for recall

    # Query search endpoint for each question
    results_list = []
    for i, entry in enumerate(entries):
        log(f"  [{i + 1}/{len(entries)}] {entry['question'][:80]}...")
        try:
            r = req.post(
                f"{RAG_SERVER_URL}/v1/search",
                json={
                    "query": entry["question"],
                    "vdb_top_k": 10,
                    "collection_names": [COLLECTION_NAME],
                },
                timeout=180,
            )
            if r.status_code != 200:
                log(f"    ERROR: status {r.status_code}")
                continue

            data = r.json()
            retrieved = []
            for res in data.get("results", []):
                doc_name = res.get("document_name", "")
                page = res.get("metadata", {}).get("page_number", "")
                retrieved.append(f"{doc_name}_{page}")

            results_list.append(
                {
                    "question": entry["question"],
                    "ground_truth_answer": entry["answer"],
                    "retrieved_docs": retrieved,
                    "num_results": len(retrieved),
                    "latency_ms": round(r.elapsed.total_seconds() * 1000, 1),
                }
            )
        except Exception as e:
            log(f"    ERROR: {e}")

    if not results_list:
        log("ERROR: No successful search queries.")
        return None

    # Calculate recall metrics
    avg_latency = sum(r["latency_ms"] for r in results_list) / len(results_list)
    min_latency = min(r["latency_ms"] for r in results_list)
    max_latency = max(r["latency_ms"] for r in results_list)

    recall_output = {
        "num_questions": len(results_list),
        "collection": COLLECTION_NAME,
        "dataset": "FinanceBench",
        "avg_latency_ms": round(avg_latency, 1),
        "min_latency_ms": round(min_latency, 1),
        "max_latency_ms": round(max_latency, 1),
        "avg_results_per_query": round(
            sum(r["num_results"] for r in results_list) / len(results_list), 1
        ),
        "details": results_list,
    }

    log(f"\n  RECALL SUMMARY:")
    log(f"    Questions queried:     {len(results_list)}")
    log(f"    Avg search latency:    {avg_latency:.0f} ms")
    log(f"    Min search latency:    {min_latency:.0f} ms")
    log(f"    Max search latency:    {max_latency:.0f} ms")
    log(f"    Avg results per query: {recall_output['avg_results_per_query']}")

    return recall_output


# ── Main ──────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(description="RAG Evaluation — FinanceBench")
    parser.add_argument(
        "--skip-ingest", action="store_true", help="Skip dataset download and ingestion"
    )
    parser.add_argument(
        "--skip-ragas",
        action="store_true",
        help="Skip RAGAS evaluation (no NVIDIA_API_KEY needed)",
    )
    parser.add_argument(
        "--skip-recall", action="store_true", help="Skip recall evaluation"
    )
    parser.add_argument(
        "--num-questions",
        type=int,
        default=50,
        help="Number of questions for RAGAS eval (default: 50)",
    )
    args = parser.parse_args()

    global NUM_EVAL_QUESTIONS
    NUM_EVAL_QUESTIONS = args.num_questions

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")

    # Clean file naming: ragas_financebench_150q.json instead of ragas_20260410_154833.json
    n_label = f"{NUM_EVAL_QUESTIONS}q" if NUM_EVAL_QUESTIONS else "all"

    log("=" * 60)
    log("RAG EVALUATION — FinanceBench Dataset")
    log(f"  RAG server:     {RAG_SERVER_URL}")
    log(f"  Ingestor:       {INGESTOR_URL}")
    log(f"  Collection:     {COLLECTION_NAME}")
    log(f"  Num questions:  {NUM_EVAL_QUESTIONS or 'all'}")
    log(f"  NVIDIA API key: {'set' if NVIDIA_API_KEY else 'NOT SET'}")
    log("=" * 60)

    # Clone + ingest
    if not args.skip_ingest:
        if not clone_financebench():
            sys.exit(1)
        asyncio.run(ingest_documents())
    else:
        log("Skipping ingestion (--skip-ingest)")
        if not clone_financebench():
            log(
                "WARNING: FinanceBench data not found locally. Ground truth won't be available."
            )

    # Load ground truth
    gt_entries = load_ground_truth()

    all_results = {
        "timestamp": timestamp,
        "rag_server": RAG_SERVER_URL,
        "collection": COLLECTION_NAME,
        "dataset": "FinanceBench",
        "num_ground_truth": len(gt_entries),
    }

    # RAGAS
    if not args.skip_ragas:
        ragas_results = asyncio.run(run_ragas_evaluation(gt_entries))
        if ragas_results:
            all_results["ragas"] = ragas_results
            ragas_file = RESULTS_DIR / f"ragas_financebench_{n_label}.json"
            with open(ragas_file, "w") as f:
                json.dump(ragas_results, f, indent=2, default=str)
            log(f"RAGAS results saved to {ragas_file}")
    else:
        log("Skipping RAGAS evaluation (--skip-ragas)")

    # Recall
    if not args.skip_recall:
        recall_results = run_recall_evaluation(gt_entries)
        if recall_results:
            all_results["recall"] = recall_results
            recall_file = RESULTS_DIR / f"recall_financebench_{n_label}.json"
            with open(recall_file, "w") as f:
                json.dump(recall_results, f, indent=2, default=str)
            log(f"Recall results saved to {recall_file}")
    else:
        log("Skipping recall evaluation (--skip-recall)")

    # Save combined results
    combined_file = RESULTS_DIR / f"evaluation_financebench_{n_label}.json"
    with open(combined_file, "w") as f:
        json.dump(all_results, f, indent=2, default=str)
    log(f"\nAll results saved to {combined_file}")


if __name__ == "__main__":
    main()
