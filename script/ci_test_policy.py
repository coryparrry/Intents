"""Explicit runtime opt-ins omitted by ordinary CI dispatch."""

# This loader check needs locally configured model resources.
NATIVE_MANUAL_METHODS = frozenset({
    "FoundationEvalsTests/CoreAIModelLoaderTests/configuredResourcesLoadAndGenerate()",
})

# Live Siri drives the UI and may use Private Cloud Compute on a signed Mac.
SWIFT_MANUAL_METHODS = frozenset({
    "SiriStudioLiveTests/signedCourtsideSiri",
})


def swift_manual_methods():
    """Return the explicitly opted-in Swift method identifiers that ordinary CI dispatch must omit."""
    return SWIFT_MANUAL_METHODS
