# Use a Core AI model

Foundation Evals can evaluate a local model exported for Apple's Core AI runtime. Model resources are supplied separately; the app does not download them for you.

## Choose and load a model

1. Open the suite's **Model** page and set **Model provider** to **Core AI model**.
2. Click **Choose Folder…** and select the exported resource folder. Selecting a folder starts loading it. You can also enter a path in **Model resource folder** and click **Load Model**.
3. Wait for the loaded model name, context window, and capabilities to appear. Loading can take time and use substantial memory.
4. Configure the suite for the capabilities the model reports, then run it. Use **Reload Model** to load the selected configuration again, or **Clear** to remove the selection.

The folder must contain `metadata.json`, the model assets it references, and the required tokenizer resources. Select the exported folder itself, rather than a parent directory or a single model file. See [Apple's coreai-models project](https://github.com/apple/coreai-models) for the export tooling.

## Readiness and saved access

The app loads the engine and tokenizer before reporting readiness. An existing folder or readable metadata alone is not enough. Missing assets, malformed metadata, inaccessible folders, and loading failures appear as errors in the model controls.

The suite stores the selected resource path and a bookmark for folders chosen through the picker. If access expires or the folder moves, choose it again. The model files stay in their original folder.

A successful load establishes that the runtime can open the model; it does not establish answer quality. Start with a small suite and inspect its outputs and traces. Check the resource provider's license before using or redistributing model files.
