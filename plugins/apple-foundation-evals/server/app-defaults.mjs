// Defaults captured from the bundled application engine suite-defaults operation.
export const SPOTLIGHT_DEFAULTS = {
  "contactIdentity": {
    "alternateNames": [],
    "displayName": "",
    "emailAddresses": [],
    "enabled": false,
    "phoneNumbers": []
  },
  "coreSpotlightSource": {
    "allowMail": false,
    "enabled": false,
    "fetchedAttributes": {
      "customAttributeNames": [],
      "presets": [
        "title",
        "contentDescription",
        "contentType"
      ]
    },
    "maximumResults": 8
  },
  "enabled": false,
  "fileSource": {
    "enabled": true,
    "fetchedAttributes": {
      "customAttributeNames": [],
      "presets": [
        "title",
        "contentDescription",
        "contentType",
        "contentModificationDate"
      ]
    },
    "folderPath": "",
    "maximumResults": 8
  },
  "guidance": {
    "dynamicProfile": {
      "attributes": {
        "customAttributeNames": [],
        "presets": []
      },
      "contentType": "unused",
      "dates": "unused",
      "numericMatch": "unused",
      "people": "unused",
      "similarityMatch": "unused",
      "textMatch": "allowed"
    },
    "focusedDomain": "documents",
    "mode": "focused",
    "outputFormat": "compact"
  },
  "maximumResponseSize": 1024,
  "pipeline": {
    "deduplicateItems": false
  }
};

export const PROFILE_DEFAULTS = {
  "afterToolCustomReasoning": "",
  "afterToolInstructions": "",
  "afterToolProbabilityThreshold": 0.9,
  "afterToolReasoningLevel": "automatic",
  "afterToolSamplingMode": "automatic",
  "afterToolSeed": 42,
  "afterToolSeedEnabled": false,
  "afterToolTemperature": 0.7,
  "afterToolTemperatureEnabled": false,
  "afterToolTopK": 40,
  "afterToolTranscriptErrorPolicy": "automatic",
  "enabled": false,
  "name": "Tool workflow",
  "requireToolFirst": false
};
