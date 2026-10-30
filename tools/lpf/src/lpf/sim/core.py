"""Minimal deterministic discrete-event core: a time-ordered heap with FIFO tie-breaking and seeded RNG streams."""
from __future__ import annotations

import heapq
import random
from typing import Any, Callable


class EventLoop:
    def __init__(self, seed: int = 0):
        self.now = 0.0
        self.seed = seed
        self._q: list[tuple[float, int, Callable, tuple]] = []
        self._n = 0
        self.stopped = False

    def rng(self, stream: int) -> random.Random:
        """Independent seeded stream (one per agent) so changing N does not reshuffle everyone's luck."""
        return random.Random(self.seed * 1_000_003 + stream)

    def at(self, t: float, fn: Callable[..., Any], *args: Any) -> None:
        heapq.heappush(self._q, (max(t, self.now), self._n, fn, args))
        self._n += 1

    def stop(self) -> None:
        self.stopped = True

    def run(self, until: float) -> float:
        """Process events up to `until` (or until stop()); returns the final time."""
        while self._q and not self.stopped:
            t, _, fn, args = self._q[0]
            if t > until:
                break
            heapq.heappop(self._q)
            self.now = t
            fn(*args)
        return self.now
