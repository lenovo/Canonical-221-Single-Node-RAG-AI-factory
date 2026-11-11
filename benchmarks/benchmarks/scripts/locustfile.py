"""
Locust load test for RAG Server API.

Targets:
  - POST /v1/generate  (streaming SSE — measures end-to-end RAG)
  - POST /v1/search    (retrieval only — measures VDB + reranker)
  - GET  /v1/health    (lightweight health check baseline)

Usage:
  # Quick smoke test: 5 users, 30 seconds
  locust --headless --users 5 --spawn-rate 1 --run-time 30s \
         --host http://localhost:8081 -f benchmarks/locustfile.py

  # Moderate load: 20 concurrent users, 5 minutes
  locust --headless --users 20 --spawn-rate 2 --run-time 5m \
         --host http://localhost:8081 -f benchmarks/locustfile.py

  # With web UI (real-time charts at http://localhost:8089):
  locust --host http://localhost:8081 -f benchmarks/locustfile.py

Prerequisites:
  pip install locust
  k8s kubectl port-forward -n rag svc/rag-server 8081:8081 --address 0.0.0.0
"""

import random
from locust import HttpUser, task, between

# ---------------------------------------------------------------------------
# Sample questions — replace with domain-specific queries after ingesting
# your documents. For meaningful results, these should be questions whose
# answers exist in your ingested collection.
# ---------------------------------------------------------------------------
QUESTIONS = [
    # FinanceBench questions (subset covering different companies and question types)
    "What is the FY2018 capital expenditure amount (in USD millions) for 3M?",
    "Is 3M a capital-intensive business based on FY2022 data?",
    "Does 3M have a reasonably healthy liquidity profile based on its quick ratio for FY2022?",
    "Does 3M maintain a stable trend of dividend distribution?",
    "What is the FY2019 fixed asset turnover ratio for Activision Blizzard?",
    "What is Adobe's year-over-year change in unadjusted operating income from FY2015 to FY2016?",
    "Does Adobe have an improving operating margin profile as of FY2022?",
    "What is Amazon's FY2017 days payable outstanding (DPO)?",
    "What is Amazon's year-over-year change in revenue from FY2016 to FY2017?",
    "What industry does AMCOR primarily operate in?",
    "Does AMCOR have an improving gross margin profile as of FY2023?",
    "What are the major products and services that AMD sells as of FY22?",
    "What drove revenue change as of the FY22 for AMD?",
    "Did AMD report customer concentration in FY22?",
    "What are the geographies that American Express primarily operates in as of 2022?",
    "What was the largest liability in American Express's Balance Sheet in 2022?",
    "Does American Water Works have positive working capital based on FY2022 data?",
    "What is the year end FY2019 total amount of inventories for Best Buy?",
    "What is Corning's FY2015 net income (in USD millions)?",
    "What is the FY2021 return on assets (ROA) for Coca-Cola?",
]

# FinanceBench collection name
COLLECTION = "financebench"


class RAGUser(HttpUser):
    """Simulates a user interacting with the RAG server."""

    # Think time between requests (seconds).
    # - between(1, 3): realistic user simulation
    # - between(0, 0): maximum stress (no pause between requests)
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
        # The /generate endpoint returns SSE. Locust measures time-to-last-byte,
        # which includes full LLM token generation time.
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
        """Health check — establishes a latency baseline for the rag-server itself."""
        self.client.get("/v1/health")
