"""In-process, bounded session registry.

Each entry holds the Strands agent of one session, the owner (the verified
user ID, ``sub``), and a lock that serializes calls to the agent. Entries are
kept in memory only, ordered by last use, and the least recently used entry
is evicted when the registry is full. Nothing is written to a file or database.
"""

from __future__ import annotations

import threading
from collections import OrderedDict
from collections.abc import Callable
from dataclasses import dataclass
from typing import TYPE_CHECKING

from .config import MAX_SESSIONS

if TYPE_CHECKING:
    from strands import Agent


class SessionOwnerMismatch(Exception):
    """The session exists and belongs to a different user."""


@dataclass
class SessionEntry:
    agent: Agent
    owner: str
    lock: threading.Lock


class SessionRegistry:
    def __init__(self, max_sessions: int = MAX_SESSIONS) -> None:
        if max_sessions < 1:
            raise ValueError("max_sessions must be at least 1")
        self._max_sessions = max_sessions
        self._entries: OrderedDict[str, SessionEntry] = OrderedDict()
        self._lock = threading.Lock()

    def acquire(
        self,
        session_id: str,
        owner: str,
        factory: Callable[[], Agent],
    ) -> SessionEntry:
        with self._lock:
            entry = self._entries.get(session_id)
            if entry is not None:
                if entry.owner != owner:
                    raise SessionOwnerMismatch
                self._entries.move_to_end(session_id)
                return entry
            while len(self._entries) >= self._max_sessions:
                self._entries.popitem(last=False)
            entry = SessionEntry(agent=factory(), owner=owner, lock=threading.Lock())
            self._entries[session_id] = entry
            return entry
