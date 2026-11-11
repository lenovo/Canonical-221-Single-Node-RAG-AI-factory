# Lenovo Customization Guide

This guide documents all Lenovo-specific customizations applied to the NVIDIA RAG
Blueprint 2.5.0 and provides instructions for maintaining, upgrading, and extending
the deployment.

## Documents

| Guide | Description |
|-------|-------------|
| [UPGRADE_GUIDE.md](UPGRADE_GUIDE.md) | Step-by-step procedure for rebasing Lenovo customizations onto new NVIDIA RAG Blueprint releases. Covers downloading new releases, diffing changes, merging customizations, rebuilding images, and validating the upgrade. |
| [FILE_DIFF_REFERENCE.md](FILE_DIFF_REFERENCE.md) | Complete inventory of every file modified or added relative to the upstream blueprint. Lists all 6 modified files and 8 new files with exact change descriptions, rationale, and upgrade risk assessment per file. |
| [FRONTEND_CUSTOMIZATION.md](FRONTEND_CUSTOMIZATION.md) | Guide for replacing the NVIDIA branding with Lenovo branding (logo, favicon, page title) and making general UI customizations (theming, adding pages, modifying chat/settings). Includes build and deployment instructions. |

## When to Use Each Guide

**Upgrading to a new NVIDIA blueprint release** — Start with the
[File Diff Reference](FILE_DIFF_REFERENCE.md) to understand what was changed,
then follow the [Upgrade Guide](UPGRADE_GUIDE.md) step by step.

**Applying Lenovo branding to the frontend** — Follow the
[Frontend Customization Guide](FRONTEND_CUSTOMIZATION.md). The frontend is
currently unmodified from upstream; the guide provides ready-to-follow
instructions for when branding is applied.

**Understanding what changed and why** — The
[File Diff Reference](FILE_DIFF_REFERENCE.md) is a complete annotated inventory
of every customization, organized by risk level (low/medium/high) for upgrade
conflicts.

## Summary of Customizations

The Lenovo deployment makes three categories of changes to the upstream NVIDIA
RAG Blueprint. No upstream Helm templates were modified.

1. **OpenSearch VDB operator** (3 new files) — Replaces Milvus as the vector
   database, following NVIDIA's "Define Your Own Vector Database" pattern.

2. **GPU resource assignments** (values.yaml changes) — Maps workloads to a
   custom MIG layout: GPU 0 dedicated to LLM, GPU 1 split into 1g.24gb and
   2g.48gb slices with time-slicing.

3. **Custom container images** (pyproject.toml + uv.lock changes) — Adds the
   `opensearch-py` dependency so the VDB operator is available at runtime.
   Images are built on the target machine with buildah.

Additionally, a standalone Triton Inference Server deployment (`triton/`) is
included but does not modify any blueprint files.
