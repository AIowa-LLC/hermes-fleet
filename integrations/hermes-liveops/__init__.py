"""Fleet live reporting (dashboard) plus opt-in push notifications (agent hooks).

Push is off by default. When enabled it registers observer hooks that send
end-to-end sealed alerts through a content-blind relay. It never answers,
blocks or modifies anything in the agent.
"""


def register(ctx):
    """Register push observers only when explicitly enabled; never fail loading."""
    try:
        from . import push_sender
        push_sender.register(ctx)
    except Exception:
        pass  # Dashboard reporting must keep working if push cannot start.
