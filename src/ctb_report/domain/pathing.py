from __future__ import annotations

import re


def normalize_path_without_revision(path: str, revision_pattern: str = r"\|[A-Za-z][A-Za-z0-9]{0,2}\|") -> str:
    """Strip revision segments and collapse duplicate separators."""
    if not path:
        return path

    has_inline_revision = bool(re.search(r":REV[A-Za-z0-9]+", path))
    normalized = re.sub(r":REV[A-Za-z0-9]+", "", path)
    if not has_inline_revision:
        normalized = re.sub(revision_pattern, "|", normalized)
    normalized = re.sub(r"\|{2,}", "|", normalized)
    if has_inline_revision:
        return normalized.strip("|")

    if path.startswith("|") and not normalized.startswith("|"):
        normalized = "|" + normalized
    if path.endswith("|") and not normalized.endswith("|"):
        normalized = normalized + "|"
    return normalized
