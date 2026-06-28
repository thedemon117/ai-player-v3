"""
File watcher — polls the Factorio script-output directory for request files.

The Factorio mod writes request_<id>.json each time it wants an LLM decision.
The watcher picks these up and hands them to the agent as PendingRequest objects.

Lifecycle of a request file:
  1. Mod writes  request_<id>.json  to output_dir
  2. poll()      returns a PendingRequest for it (added to _dispatched)
  3. agent       calls LLM, sends response via RCON
  4. ack(req_id) deletes the file, removes from _dispatched
     OR
  4. timeout     request expires after REQUEST_TIMEOUT seconds;
                 file is deleted and the mod will eventually re-request

The watcher never processes or interprets request content — it hands raw
parsed JSON to the caller. Deletion is always explicit via ack().
"""

import json
import logging
import time
from dataclasses import dataclass, field
from pathlib import Path

log = logging.getLogger(__name__)

# Fallback stale timeout if the caller doesn't pass one. The real value is
# derived from the bridge SDK timeout (AI_TIMEOUT + margin) and passed in by
# main.py, so it never expires a request before the model's allotted reply time.
DEFAULT_REQUEST_TIMEOUT = 300.0   # seconds


@dataclass
class PendingRequest:
    req_id: str
    payload: dict          # parsed JSON from request_<id>.json
    path: Path
    dispatched_at: float = field(default_factory=time.monotonic)
    retry_count: int = 0
    retry_after: float = 0.0   # monotonic time before which this request won't be returned


class FileWatcher:
    """
    Polls output_dir for request_*.json files and returns new ones each call.

    Usage:
        watcher = FileWatcher(output_dir)
        while True:
            for req in watcher.poll():
                response = agent.decide(req)
                rcon.send_ai_response(req.req_id, response)
                watcher.ack(req.req_id)
            time.sleep(poll_interval)
    """

    def __init__(self, output_dir: Path, poll_interval: float = 0.1,
                 request_timeout: float = DEFAULT_REQUEST_TIMEOUT):
        self._dir = Path(output_dir)
        self.poll_interval = poll_interval
        self.request_timeout = request_timeout
        self._dispatched: dict[str, PendingRequest] = {}   # req_id → PendingRequest

    def poll(self) -> list[PendingRequest]:
        """
        Scan for new request files. Returns only requests not already dispatched.
        Also expires and deletes stale requests that were never acknowledged.
        """
        self._expire_stale()

        new_requests: list[PendingRequest] = []

        try:
            candidates = sorted(self._dir.glob("request_*.json"))
        except OSError as e:
            log.warning("Cannot scan output dir %s: %s", self._dir, e)
            return []

        now = time.monotonic()

        for path in candidates:
            req_id = path.stem.replace("request_", "")

            existing = self._dispatched.get(req_id)
            if existing is not None:
                # Already dispatched — skip until retry_after has passed
                if now < existing.retry_after:
                    continue
                # Ready for retry — re-add to results
                new_requests.append(existing)
                continue

            payload = self._read(path)
            if payload is None:
                continue

            req = PendingRequest(req_id=req_id, payload=payload, path=path)
            self._dispatched[req_id] = req
            new_requests.append(req)
            log.info("New request: %s", req_id)

        return new_requests

    def purge_all(self) -> int:
        """
        Delete every request_*.json file in the output dir and forget all
        dispatched state. Call once at bridge startup, right after the mod's
        pending queue is cleared — any request file on disk corresponds to a
        mod-side pending entry that was just wiped, so replying to it would
        produce an "Unknown request id" and leave the file orphaned. (A2)
        """
        self._dispatched.clear()
        purged = 0
        try:
            for path in self._dir.glob("request_*.json"):
                self._delete(path)
                purged += 1
        except OSError as e:
            log.warning("Cannot purge output dir %s: %s", self._dir, e)
        if purged:
            log.info("Purged %d stale request file(s) at startup", purged)
        return purged

    def ack(self, req_id: str) -> None:
        """
        Mark a request as handled and delete its file.
        Call after the LLM response has been sent via RCON.
        """
        req = self._dispatched.pop(req_id, None)
        if req is None:
            log.warning("ack called for unknown request %s", req_id)
            return
        self._delete(req.path)
        log.debug("Acknowledged request %s", req_id)

    def nack(self, req_id: str) -> None:
        """
        Mark a request as failed and schedule a retry with exponential backoff.
        Delays: 2s, 4s, 8s, 16s, 30s cap — avoids tight retry loops when
        LM Studio or RCON is unavailable.
        """
        req = self._dispatched.get(req_id)
        if req is None:
            return
        req.retry_count += 1
        delay = min(2 ** req.retry_count, 30)
        req.retry_after = time.monotonic() + delay
        log.warning(
            "Request %s failed (attempt %d) — retrying in %.0fs",
            req_id, req.retry_count, delay,
        )

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _read(self, path: Path) -> dict | None:
        """Read and parse a request file. Returns None if unreadable or not yet complete."""
        try:
            text = path.read_text(encoding="utf-8")
            if not text.strip():
                return None
            return json.loads(text)
        except json.JSONDecodeError:
            # File may still be mid-write — skip this poll, pick it up next time
            return None
        except OSError:
            # File vanished between glob and read (race with another process)
            return None

    def _delete(self, path: Path) -> None:
        try:
            path.unlink(missing_ok=True)
        except OSError as e:
            log.warning("Could not delete %s: %s", path.name, e)

    def _expire_stale(self) -> None:
        """Delete and discard requests that were dispatched but never acknowledged."""
        now = time.monotonic()
        stale = [
            req_id for req_id, req in self._dispatched.items()
            if now - req.dispatched_at > self.request_timeout
        ]
        for req_id in stale:
            req = self._dispatched.pop(req_id)
            log.warning(
                "Request %s expired after %.0fs without acknowledgement — deleting",
                req_id, self.request_timeout,
            )
            self._delete(req.path)
