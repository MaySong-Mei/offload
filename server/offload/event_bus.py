from __future__ import annotations

import queue
import threading
import uuid
from typing import Dict, Tuple

from .models import EventRecord


class EventBus:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._subscribers: Dict[str, "queue.Queue[EventRecord]"] = {}

    def subscribe(self) -> Tuple[str, "queue.Queue[EventRecord]"]:
        subscriber_id = f"sub-{uuid.uuid4().hex[:12]}"
        subscription: "queue.Queue[EventRecord]" = queue.Queue()
        with self._lock:
            self._subscribers[subscriber_id] = subscription
        return subscriber_id, subscription

    def unsubscribe(self, subscriber_id: str) -> None:
        with self._lock:
            self._subscribers.pop(subscriber_id, None)

    def publish(self, event: EventRecord) -> None:
        with self._lock:
            subscribers = list(self._subscribers.values())
        for subscription in subscribers:
            subscription.put(event)

