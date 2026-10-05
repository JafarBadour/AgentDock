"""Tests for the history replayed into a fresh ACP session.

A reaped or cancelled worker opens a new session with no memory, so the next
prompt carries a replay block built from the durable transcript. Getting that
block wrong is user-visible: the agent answers the replay instead of the
message it was just sent.
"""

from __future__ import annotations

import re
import unittest

from adsm import transcript as transcript_store
from adsm.worker import Worker


def _bootstrap(chat_id: str, *, exclude_message_id: str | None = None) -> str:
    """Call the builder without standing up a real Worker/agent process."""

    class _Stub:
        pass

    stub = _Stub()
    stub.chat_id = chat_id
    stub._take_fork_marker = lambda: False
    return Worker._history_bootstrap_prompt(
        stub, exclude_message_id=exclude_message_id
    )


def _entries(block: str) -> list[tuple[str, str]]:
    """(role, first line) for each replayed turn, oldest first."""
    return [
        (m.group(1), m.group(2))
        for m in re.finditer(r"^(User|Assistant):\n(.*)$", block, flags=re.M)
    ]


class HistoryBootstrapTest(unittest.TestCase):
    def setUp(self) -> None:
        self.chat_id = "chat-bootstrap-1"

    def _append(self, role: str, content: str, mid: str) -> None:
        transcript_store.append_message(
            self.chat_id, role=role, content=content, message_id=mid
        )

    def test_empty_transcript_yields_no_block(self) -> None:
        self.assertEqual(_bootstrap(self.chat_id), "")

    def test_user_turns_survive_a_flood_of_assistant_rows(self) -> None:
        # One streamed segment is one row, so short assistant preambles pile
        # up far faster than user turns. A count-capped window replayed only
        # those and the agent never saw what it had been asked.
        self._append("user", "please run the migration", "u1")
        for i in range(400):
            self._append("assistant", f"step {i}: checking", f"a{i}")

        entries = _entries(_bootstrap(self.chat_id))

        self.assertIn(
            ("User", "please run the migration"),
            entries,
            "the user's only turn must survive the assistant flood",
        )

    def test_recent_user_turns_are_all_reserved(self) -> None:
        for turn in range(4):
            self._append("user", f"question {turn}", f"u{turn}")
            for i in range(120):
                self._append("assistant", f"turn {turn} segment {i}", f"a{turn}-{i}")

        entries = _entries(_bootstrap(self.chat_id))
        users = [text for role, text in entries if role == "User"]

        self.assertEqual(users, [f"question {t}" for t in range(4)])

    def test_duplicate_rows_are_replayed_once(self) -> None:
        # Re-imports land under fresh ids, so the host file holds the same
        # turn many times over. Replaying each copy burned the budget.
        self._append("user", "ship it", "u1")
        for i in range(5):
            self._append("assistant", "Running the tests now:", f"dup{i}")

        entries = _entries(_bootstrap(self.chat_id))
        repeats = [t for _, t in entries].count("Running the tests now:")

        self.assertEqual(repeats, 1)

    def test_window_is_not_capped_at_forty_short_messages(self) -> None:
        for i in range(150):
            self._append("assistant", f"segment {i}", f"a{i}")

        entries = _entries(_bootstrap(self.chat_id))

        self.assertGreater(
            len(entries), 40, "short rows should fill the byte budget, not a row count"
        )

    def test_block_stays_within_the_byte_budget(self) -> None:
        for i in range(200):
            self._append("user", f"u{i} " + "x" * 2_000, f"u{i}")
            self._append("assistant", f"a{i} " + "y" * 2_000, f"a{i}")

        block = _bootstrap(self.chat_id)

        # Budget covers the replayed turns; the preamble and footer sit on top.
        self.assertLess(len(block), 32_000)

    def test_oversized_message_is_truncated(self) -> None:
        self._append("assistant", "z" * 9_000, "a1")

        block = _bootstrap(self.chat_id)

        self.assertIn("…(truncated)", block)

    def test_excluded_message_is_left_out(self) -> None:
        self._append("user", "earlier question", "u1")
        self._append("user", "the message being sent right now", "u2")

        entries = _entries(_bootstrap(self.chat_id, exclude_message_id="u2"))
        texts = [t for _, t in entries]

        self.assertIn("earlier question", texts)
        self.assertNotIn("the message being sent right now", texts)

    def test_reserved_older_turn_is_marked_as_a_gap(self) -> None:
        self._append("user", "the original request", "u1")
        for i in range(400):
            self._append("assistant", f"segment {i}", f"a{i}")

        block = _bootstrap(self.chat_id)

        self.assertIn("\n…\n", block)

    def test_tool_and_system_rows_are_not_replayed(self) -> None:
        self._append("system", "boot", "s1")
        self._append("tool", '{"toolCallId":"t1"}', "t1")
        self._append("user", "hello", "u1")

        entries = _entries(_bootstrap(self.chat_id))

        self.assertEqual(entries, [("User", "hello")])


if __name__ == "__main__":
    unittest.main()
