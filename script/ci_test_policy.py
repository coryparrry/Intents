"""Explicit runtime opt-ins omitted by ordinary CI dispatch."""

# This loader check needs locally configured model resources.
NATIVE_MANUAL_METHODS = frozenset({
    "FoundationEvalsTests/CoreAIModelLoaderTests/configuredResourcesLoadAndGenerate()",
})

SWIFT_MANUAL_METHODS = frozenset()


def swift_manual_methods():
    """Return the explicitly opted-in Swift method identifiers that ordinary CI dispatch must omit."""
    return SWIFT_MANUAL_METHODS
