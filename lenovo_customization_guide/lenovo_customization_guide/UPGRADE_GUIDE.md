# Upgrading to a New NVIDIA RAG Blueprint Release

This guide explains how to rebase the Lenovo customizations onto a new upstream
NVIDIA RAG Blueprint release (e.g., upgrading from 2.5.0 to 2.6.0).

## Overview

The Lenovo customization makes a **small, targeted set of changes** to the
upstream NVIDIA RAG Blueprint. The design principle is to keep upstream template
modifications at zero and limit changes to:

1. **New files** (OpenSearch VDB operator, Lenovo MIG config)
2. **values.yaml** (configuration only, no template changes)
3. **pyproject.toml / uv.lock** (one added dependency: `opensearch-py`)
4. **VDB factory registration** (12-line addition to `vdb/__init__.py`)

No Helm templates were modified. This makes upgrades straightforward.

---

## Step-by-Step Upgrade Procedure

### 1. Obtain the New Upstream Blueprint

Download or clone the new NVIDIA RAG Blueprint release:

```bash
# Example for a hypothetical 2.6.0 release
export NEW_VERSION="2.6.0"
# Download from NVIDIA NGC or clone from the official repository
```

### 2. Copy the New Blueprint

Create a fresh working copy:

```bash
cp -r nvidia-rag-blueprint-${NEW_VERSION} rag_blueprint_lenovo/
```

### 3. Apply the Lenovo Customizations

Apply each change category in order. The sections below reference the exact
files and the nature of each change.

#### 3a. Add the OpenSearch VDB Operator (NEW FILES -- copy as-is)

Copy the entire OpenSearch VDB directory into the new blueprint:

```bash
cp -r <old>/src/nvidia_rag/utils/vdb/opensearch/ \
      <new>/src/nvidia_rag/utils/vdb/opensearch/
```

Files:
- `src/nvidia_rag/utils/vdb/opensearch/__init__.py`
- `src/nvidia_rag/utils/vdb/opensearch/opensearch_vdb.py` (~951 lines)
- `src/nvidia_rag/utils/vdb/opensearch/os_queries.py`

**Verification**: Review the upstream `vdb_base.py` and `vdb_ingest_base.py` for
any interface changes. If the base classes added new abstract methods, implement
them in `opensearch_vdb.py`.

#### 3b. Register OpenSearch in the VDB Factory (PATCH)

Edit `src/nvidia_rag/utils/vdb/__init__.py`. Find the `_get_vdb_op()` function
(look for the `elif config.vector_store.name == "elasticsearch":` branch) and
add immediately after it:

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

**Verification**: Check if the `_get_vdb_op()` function signature changed.
If new parameters were added, pass them to the `OpenSearchVDB` constructor
(and add them to the `OpenSearchVDB.__init__` signature if needed).

#### 3c. Add opensearch-py Dependency (PATCH)

Edit `pyproject.toml`. In the `[project] dependencies` list, add:

```toml
    "opensearch-py>=2.4,<3.0",
```

Also add the optional dependency group:

```toml
[project.optional-dependencies]
opensearch = [
    "opensearch-py>=2.4,<3.0",
]
```

Then regenerate the lock file:

```bash
uv lock
```

#### 3d. Customize Helm values.yaml (PATCH)

Edit `deploy/helm/nvidia-blueprint-rag/values.yaml`. The changes are all
configuration values, no template modifications required.

**Key changes to apply** (see `FILE_DIFF_REFERENCE.md` for the complete diff):

| Setting | Upstream Default | Lenovo Value | Purpose |
|---------|-----------------|--------------|---------|
| `ragServer.image.repository` | `nvcr.io/nvidia/blueprint/rag-server` | `lenovo/rag-server` | Custom image with OpenSearch deps |
| `ragServer.image.tag` | `2.x.0` | `2.x.0-opensearch` | Custom image tag |
| `ingestorServer.image.repository` | `nvcr.io/nvidia/blueprint/ingestor-server` | `lenovo/ingestor-server` | Custom image with OpenSearch deps |
| `ingestorServer.image.tag` | `2.x.0` | `2.x.0-opensearch` | Custom image tag |
| `ragServer.envVars` APP_VECTORSTORE_NAME | `milvus` | `opensearch` | Use OpenSearch VDB |
| `ragServer.envVars` APP_VECTORSTORE_URL | `http://milvus:19530` | `https://opensearch:9200` | OpenSearch endpoint |
| `ingestorServer.envVars` APP_VECTORSTORE_NAME | `milvus` | `opensearch` | Use OpenSearch VDB |
| `ingestorServer.envVars` APP_VECTORSTORE_URL | `http://milvus:19530` | `https://opensearch:9200` | OpenSearch endpoint |
| `milvusDeployed` | `true` | `false` | Disable Milvus |
| `milvus.enabled` | `true` | `false` | Disable Milvus subchart |
| Various GPU resource limits | Full GPU | MIG slice resources | Lenovo 2-GPU layout |
| `llmNim.model.modelProduct` | varies | `rtx6000_blackwell_sv` | Lenovo GPU profile |
| `llmNim.model.precision` | varies | `nvfp4` | Quantization for 96GB VRAM |
| `frontend.image.repository` | `nvcr.io/nvidia/blueprint/rag-frontend` | (keep or change) | See frontend customization guide |

**Important**: Compare the new upstream `values.yaml` with the old upstream
version to identify any new settings that need attention. New NIM services,
changed env var names, or new subchart toggles should be reviewed.

#### 3e. Copy Lenovo MIG Configuration (NEW FILE)

```bash
cp <old>/deploy/helm/mig-slicing/mig-config-lenovo-2gpu.yaml \
   <new>/deploy/helm/mig-slicing/mig-config-lenovo-2gpu.yaml
```

**Verification**: If NVIDIA changes the MIG config format or the
`gpu-operator` version, review the ConfigMap structure.

### 4. Deploy and Test the Upgrade

`deploy_apps.sh` Phase 3 automatically builds the custom container images
(`lenovo/rag-server` and `lenovo/ingestor-server`) with buildah, exports them
to tarballs, and imports them into the containerd image store. No manual image
build is needed.

```bash
sudo bash deploy_apps.sh
```

After deployment completes:

1. Verify all pods reach Running state: `sudo k8s kubectl get pods -n rag`
2. Run a smoke test: upload a PDF and query it
3. Run the benchmark suite (see `benchmarks/README.md`)

---

## Common Pitfalls

| Issue | Solution |
|-------|----------|
| New abstract methods in `vdb_base.py` | Implement them in `opensearch_vdb.py` |
| `opensearch-py` version conflict | Check if NVIDIA added `elasticsearch` as a hard dep; `opensearch-py` and `elasticsearch` can conflict |
| New env vars in values.yaml | Compare old vs new upstream values.yaml and merge any new vars |
| NIM API changes | If NIM services add new config options, review the Helm templates |
| MIG config format changes | Compare with upstream `mig-config-rtx6000.yaml` for format changes |
| Frontend image version bump | Update the tag in `values.yaml` to match the new release |

---

## Quick Verification Checklist

After applying all changes:

- [ ] `opensearch` directory exists under `src/nvidia_rag/utils/vdb/`
- [ ] `vdb/__init__.py` has the `elif config.vector_store.name == "opensearch":` branch
- [ ] `pyproject.toml` includes `opensearch-py>=2.4,<3.0`
- [ ] `uv.lock` is regenerated
- [ ] `values.yaml` has `APP_VECTORSTORE_NAME: opensearch` for both rag-server and ingestor-server
- [ ] `values.yaml` has `milvusDeployed: false` and `milvus.enabled: false`
- [ ] `values.yaml` references the correct Lenovo custom container images
- [ ] `mig-config-lenovo-2gpu.yaml` is present
- [ ] Custom container images build successfully (verified by `deploy_apps.sh` Phase 3)
