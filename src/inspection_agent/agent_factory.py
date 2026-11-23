"""Builds the Strands agent. Takes no identity: the Principal arrives per call."""

from __future__ import annotations

from strands import Agent
from strands.models.bedrock import BedrockModel
from strands.tools.executors import SequentialToolExecutor

from .budget import ToolBudgetHook
from .config import AgentConfig
from .strands_tools import TOOLS


def build_agent(config: AgentConfig, prompt_text: str, prompt_version: str) -> Agent:
    """Return one agent with exactly the four inspection tools and no identity."""
    model_kwargs: dict = {}
    if config.additional_request_fields is not None:
        model_kwargs["additional_request_fields"] = config.additional_request_fields
    model = BedrockModel(
        model_id=config.model_id,
        region_name=config.region,
        **model_kwargs,
    )
    return Agent(
        model=model,
        system_prompt=prompt_text,
        tools=list(TOOLS),
        hooks=[ToolBudgetHook()],
        tool_executor=SequentialToolExecutor(),
        callback_handler=None,
        trace_attributes={
            "inspection.prompt_version": prompt_version,
            "inspection.model_id": config.model_id,
        },
    )
