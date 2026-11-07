---
doc_id: fusion-browser/changelog
product: fusion-browser
class: app
entry: service
doc_type: changelog
title: { zh: "fusion-browser 变更记录", en: "fusion-browser changelog" }
audience: engineer
status: draft
version: 0.2.4
updated: 2026-11-07
owner: @dahai
source_of_truth:
  - CHANGELOG.md
---

# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Release history lives in git tags (`v0.2.4`, `v0.2.3`, ...) and GitHub releases; the feature log in `README.md` (Phase 1-4) is the canonical narrative record.

## Unreleased

### Added

- Adopted the fusion docs-system v1.1 contract (app x service): added `docs/product-page.md`, `docs/get-started.md`, `docs/api-reference.md`, `docs/config-reference.md`, `docs/troubleshooting.md`, this `CHANGELOG.md`, `ci/validate_docs.py`, and the `docs` GitHub Actions workflow; added 12-key frontmatter to all in-repo markdown docs.
