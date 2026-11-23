"""Load the versioned system prompt from a text file.

The first line must be ``prompt-version: <id>``. The version is returned
separately and is not part of the text the model receives.
"""

from __future__ import annotations

import re
from pathlib import Path

_VERSION_LINE = re.compile(r"prompt-version: ([A-Za-z0-9._-]{1,40})")


class PromptFileError(Exception):
    """The system prompt file is missing, unreadable, empty, or malformed."""


def load_system_prompt(path: str | Path) -> tuple[str, str]:
    """Return ``(version, text)`` from the prompt file at ``path``."""
    try:
        raw = Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise PromptFileError(f"cannot read prompt file {path}") from exc

    content = raw.strip()
    if not content:
        raise PromptFileError(f"prompt file is empty: {path}")

    first_line, _, rest = content.partition("\n")
    match = _VERSION_LINE.fullmatch(first_line.rstrip())
    if match is None:
        raise PromptFileError(f"prompt file {path} must start with 'prompt-version: <id>'")

    text = rest.strip()
    if not text:
        raise PromptFileError(f"prompt file has no prompt text: {path}")
    return match.group(1), text
