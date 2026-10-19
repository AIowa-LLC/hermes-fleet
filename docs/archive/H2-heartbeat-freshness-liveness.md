# H2: Heartbeat freshness and liveness

> Historical implementation reference

This milestone introduced tiered liveness evaluation so recent valid transport activity can suppress unnecessary status probing while stale connections still reconnect.

Current transport behavior is defined by source and tests. Historical card IDs and execution logs are intentionally omitted from public documentation.
