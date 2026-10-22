"""Explicit runtime opt-ins omitted by ordinary CI dispatch."""

# This loader check needs locally configured model resources.
NATIVE_MANUAL_METHODS = frozenset({
    "FoundationEvalsTests/CoreAIModelLoaderTests/configuredResourcesLoadAndGenerate()",
})

SWIFT_MANUAL_METHODS = frozenset()


def swift_manual_methods():
    return SWIFT_MANUAL_METHODS
