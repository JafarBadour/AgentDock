"""Keep every test out of the real ~/.agentdock.

Several tests build a Worker or Daemon without patching paths, and anything
they persist lands under the home directory. Windows `expanduser` reads
USERPROFILE rather than HOME, so point both at a throwaway directory.
"""

from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def _isolated_home(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("USERPROFILE", str(home))
    yield home
