"""Per-request tool-call budget and Action_Log, as a Strands hook provider."""

from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any

from strands.hooks import AfterToolCallEvent, BeforeToolCallEvent, HookProvider, HookRegistry

from .config import TOOL_CALL_LIMIT

LIMIT_MESSAGE = (
    "Tool call limit reached for this message. Do not call more tools. "
    "Answer with the data you already have."
)

_DECISIONS = frozenset({"allowed", "restricted", "forbidden"})


@dataclass
class RequestRecorder:
    """State for one request. A new instance per request resets the budget."""

    attempts: int = 0
    actions: list[dict] = field(default_factory=list)


def action_from_result(tool_name: str, result: Mapping[str, Any]) -> dict:
    """Build an Action_Log entry. Holds only tool name, decision, and row count."""
    decision: str | None = None
    row_count = 0
    try:
        payload = json.loads(result["content"][0]["text"])
        meta = payload.get("meta") if isinstance(payload, dict) else None
        if isinstance(meta, dict):
            raw_decision = meta.get("decision")
            if isinstance(raw_decision, str) and raw_decision in _DECISIONS:
                decision = raw_decision
            raw_count = meta.get("row_count")
            if isinstance(raw_count, int) and not isinstance(raw_count, bool) and raw_count >= 0:
                row_count = raw_count
    except (KeyError, IndexError, TypeError, ValueError):
        pass
    return {"tool": tool_name, "decision": decision, "row_count": row_count}


class ToolBudgetHook(HookProvider):
    """Caps tool calls per request and records what ran."""

    def register_hooks(self, registry: HookRegistry, **kwargs: Any) -> None:
        registry.add_callback(BeforeToolCallEvent, self._before)
        registry.add_callback(AfterToolCallEvent, self._after)

    def _before(self, event: BeforeToolCallEvent) -> None:
        recorder = event.invocation_state.get("recorder")
        if not isinstance(recorder, RequestRecorder):
            event.cancel_tool = LIMIT_MESSAGE  # fail closed
            return
        if recorder.attempts >= TOOL_CALL_LIMIT:
            event.cancel_tool = LIMIT_MESSAGE
            return
        recorder.attempts += 1

    def _after(self, event: AfterToolCallEvent) -> None:
        if event.cancel_message is not None or event.selected_tool is None:
            return
        recorder = event.invocation_state.get("recorder")
        if not isinstance(recorder, RequestRecorder):
            return
        name = str(event.tool_use.get("name", ""))
        recorder.actions.append(action_from_result(name, event.result))
