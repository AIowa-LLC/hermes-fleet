# T3B: Read-only Kanban board

> Historical implementation reference

This milestone added a read-only Kanban surface backed by the gateway's board snapshot and change-event stream, with reconnect/cursor handling and periodic snapshot refresh.

The client intentionally exposes no card mutation API in this surface. Current feature status is summarized in [`features.md`](features.md).
