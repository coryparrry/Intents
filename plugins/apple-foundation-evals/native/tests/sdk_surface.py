#!/usr/bin/env python3
"""Regression guard for known SDK 27-only dependencies; not an Xcode 26 build."""
from pathlib import Path
import re

native = Path(__file__).resolve().parent.parent
sources = "\n".join((native / name).read_text() for name in (
    "RunnerCore.swift", "FoundationModelsRunner.swift"))
# A runtime availability guard cannot make these declarations exist in SDK 26.
for symbol in ("LanguageModelError", "PrivateCloudComputeLanguageModel", "ContextOptions"):
    assert not re.search(r"\b" + symbol + r"\b", sources), "SDK 27-only reference: " + symbol
assert "LanguageModelSession.GenerationError" in sources
assert "RunnerFailure.unclassifiedGenerationError(error)" in sources
print("Native SDK surface guard: passed (known SDK 27-only dependencies absent)")
