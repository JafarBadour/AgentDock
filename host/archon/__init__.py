"""Archon: the manager process that directs agents across hosts.

Archon never executes anything itself — every action goes through an agent it
commands. This package holds the state that makes it a daemon rather than a
chat: where its folder lives, the timers that wake it, and what it remembers.
"""
