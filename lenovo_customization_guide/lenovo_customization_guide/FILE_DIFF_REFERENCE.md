# Lenovo Customization — File Diff Reference

This document lists every file that differs between the upstream NVIDIA RAG
Blueprint 2.5.0 and the Lenovo customization. Use this as a checklist when
upgrading to a new upstream release.

---

## Summary

| Category | Files Changed | Files Added |
|----------|--------------|-------------|
| OpenSearch VDB operator | 0 | 3 |
| VDB factory registration | 1 | 0 |
| Python dependencies | 2 | 0 |
| Helm values.yaml | 1 | 0 |
| Lenovo MIG config | 0 | 1 |
| Infrastructure scripts | 0 | 4 |
| **Total** | **4** | **8** |

---

## NEW FILES (added by Lenovo, not in upstream)

### OpenSearch VDB Operator

These files implement the "Define Your Own Vector Database" pattern from
NVIDIA's documentation. They are completely self-contained and do not modify
any upstream code.

| File | Lines | Purpose |
|------|-------|---------|
| `src/nvidia_rag/utils/vdb/opensearch/__init__.py` | ~5 | Module init, exports `OpenSearchVDB` |
| `src/nvidia_rag/utils/vdb/opensearch/opensearch_vdb.py` | ~951 | Full OpenSearch VDB implementation: ingestion, retrieval, CRUD, health, metadata management. Uses `opensearch-py` + `langchain-community.OpenSearchVectorSearch` |
| `src/nvidia_rag/utils/vdb/opensearch/os_queries.py` | ~200 | OpenSearch query builders: aggregation, deletion, metadata, document info (10 functions) |

### Lenovo MIG Configuration

| File | Lines | Purpose |
|------|-------|---------|
| `deploy/helm/mig-slicing/mig-config-lenovo-2gpu.yaml` | ~80 | GPU partitioning ConfigMap for Lenovo ThinkSystem SR650a V4 with 2x RTX PRO 6000 Blackwell. GPU 0 = non-MIG (LLM), GPU 1 = MIG (2x1g.24gb + 1x2g.48gb) |

### Infrastructure Scripts (project root, outside blueprint directory)

These are deployment automation scripts that live at the project root level,
not inside the blueprint directory:

| File | Purpose |
|------|---------|
| `setup_infra.sh` | Installs OpenSearch (snap), configures TLS/auth, applies MIG config |
| `deploy_apps.sh` | 8-phase deployment: secrets, NIM operator, Helm install, port-forwards, health checks |
| `cleanup.sh` | Tears down the deployment |
| `config_infra.env` | Environment variables: IPs, credentials, image refs |

---

## MODIFIED FILES (changed from upstream defaults)

### 1. VDB Factory — `src/nvidia_rag/utils/vdb/__init__.py`

**Nature of change**: Added 12 lines to the `_get_vdb_op()` factory function.

**Location**: After the `elif config.vector_store.name == "elasticsearch":` branch
(approximately line 123).

**Exact addition**:
```python
    elif config.vector_store.name == "opensearch":
        from nvidia_rag.utils.vdb.opensearch.opensearch_vdb import OpenSearchVDB

        return OpenSearchVDB(
            opensearch_url=vdb_endpoint or config.vector_store.url,
            index_name=collection_name,
            meta_source_field=meta_source_field,
            meta_fields=meta_fields,
            embedding_model=embedding_model,
            csv_file_path=csv_file_path,
            config=config,
        )
```

**Upgrade risk**: LOW. Only risk is if `_get_vdb_op()` signature changes or
new parameters are added.

---

### 2. Python Dependencies — `pyproject.toml`

**Nature of change**: Added `opensearch-py` dependency.

**Lines changed**:
- Line 40 (in `[project] dependencies`): `"opensearch-py>=2.4,<3.0",`
- Lines 108-109 (new optional group):
  ```toml
  [project.optional-dependencies]
  opensearch = [
      "opensearch-py>=2.4,<3.0",
  ]
  ```

**Upgrade risk**: LOW. Just re-add the dependency line and regenerate `uv.lock`.

---

### 3. Lock File — `uv.lock`

**Nature of change**: Regenerated to include `opensearch-py` and its transitive
dependencies.

**Upgrade action**: After editing `pyproject.toml`, run `uv lock` to regenerate.

---

### 4. Helm Values — `deploy/helm/nvidia-blueprint-rag/values.yaml`

**Nature of change**: Configuration-only changes. No Helm templates were modified.

**Key changes** (grouped by category):

#### Container Images
```yaml
# Upstream:
ragServer.image.repository: nvcr.io/nvidia/blueprint/rag-server
ragServer.image.tag: "2.5.0"
ingestorServer.image.repository: nvcr.io/nvidia/blueprint/ingestor-server
ingestorServer.image.tag: "2.5.0"

# Lenovo:
ragServer.image.repository: lenovo/rag-server
ragServer.image.tag: "2.5.0-opensearch"
ingestorServer.image.repository: lenovo/ingestor-server
ingestorServer.image.tag: "2.5.0-opensearch"
```

#### Vector Store Configuration
```yaml
# Upstream:
APP_VECTORSTORE_NAME: milvus
APP_VECTORSTORE_URL: http://milvus:19530

# Lenovo:
APP_VECTORSTORE_NAME: opensearch
APP_VECTORSTORE_URL: https://opensearch:9200
```

(Both `ragServer.envVars` and `ingestorServer.envVars` sections.)

#### OpenSearch Credentials (added)
```yaml
# Added env vars for OpenSearch TLS + basic auth:
APP_VECTORSTORE_USERNAME: admin
APP_VECTORSTORE_PASSWORD: <password>
APP_VECTORSTORE_SSL_VERIFY: "false"  # Self-signed cert
```

#### Milvus Disabled
```yaml
# Upstream:
milvusDeployed: true
milvus:
  enabled: true

# Lenovo:
milvusDeployed: false
milvus:
  enabled: false
```

#### MinIO Disabled (was a Milvus sub-dependency)
```yaml
# Upstream has MinIO endpoints configured
# Lenovo: emptied all MinIO endpoint references
```

#### GPU Resources (MIG layout)
```yaml
# Upstream uses full GPU resources:
#   nvidia.com/gpu: 1

# Lenovo uses MIG slice resources:
# LLM NIM:     nvidia.com/gpu: 1       (GPU 0, non-MIG)
# Embed NIM:   nvidia.com/mig-1g.24gb: 1  (GPU 1, slice 0)
# Rerank NIM:  nvidia.com/mig-1g.24gb: 1  (GPU 1, slice 0, time-sliced)
# Graphic NIM: nvidia.com/mig-1g.24gb: 1  (GPU 1, slice 1)
# Table NIM:   nvidia.com/mig-1g.24gb: 1  (GPU 1, slice 1, time-sliced)
# OCR NIM:     nvidia.com/mig-2g.48gb: 1  (GPU 1, slice 2)
# Page NIM:    nvidia.com/mig-2g.48gb: 1  (GPU 1, slice 2, time-sliced)
```

#### LLM Model Profile
```yaml
# Upstream:
llmNim.model.modelProduct: (varies by values file)

# Lenovo:
llmNim.model.modelProduct: rtx6000_blackwell_sv
llmNim.model.precision: nvfp4
```

**Upgrade risk**: MEDIUM. The values.yaml is the most change-prone file between
releases. Use `diff` to compare old upstream vs new upstream values.yaml and
merge Lenovo-specific values carefully. Pay special attention to:
- New NIM services (might need GPU resource assignments)
- Changed env var names
- New subchart toggles
- Changed default ports or image tags

---

## FILES NOT MODIFIED (notable)

These upstream files were intentionally **not** changed:

| File | Why It Was Left Alone |
|------|----------------------|
| All Helm templates (`deploy/helm/.../templates/*.yaml`) | Customization is purely through `values.yaml` |
| `frontend/` (entire directory) | Frontend is unmodified — uses stock NVIDIA image. See `FRONTEND_CUSTOMIZATION.md` for branding changes |
| `src/nvidia_rag/rag_server/` | No server code changes needed — VDB is abstracted behind the factory |
| `src/nvidia_rag/ingestor_server/` | Same — VDB abstraction handles OpenSearch transparently |
| `src/nvidia_rag/utils/vdb/milvus/` | Left intact (just disabled via config) |
| `src/nvidia_rag/utils/vdb/elasticsearch/` | Left intact (reference for OpenSearch implementation) |
| `notebooks/` | Evaluation notebooks work as-is (except `evaluation_01_ragas.ipynb` has hardcoded Milvus endpoint — we use our own `run_evaluation.py` instead) |
