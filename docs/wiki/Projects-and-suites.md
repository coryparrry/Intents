# Organize projects, suites, and cases

[Home](Home.md) · [Getting started](Getting-started.md) · [Models and scoring](Models-scoring-and-tools.md)

A **project** groups suites for one app or area of work. A **suite** contains shared instructions, model settings, scoring settings, reference files, and cases. Each **case** has a prompt. Some scoring methods also require expected text. Runs belong to the selected suite.

## Manage projects and suites

Use the **Project** menu at the top of the sidebar to change projects. This menu also has **New project…** and **Manage projects…**. The manager can create, rename, duplicate, and archive projects and suites.

Select **New Suite** in Overview or at the bottom of the sidebar. To duplicate or archive an existing suite, open its sidebar context menu.

Overview shows each active suite's latest check against its current definition. Search for a suite by name, or show only suites that need attention. Select a suite to open it. Select its play button to run it. Select **Refresh** to reload saved results.

The sidebar **Runs** list belongs to the selected suite. Its filter accepts a suite name or version. The run context menu can delete a saved run. This deletes its results and trace from this Mac. The app cannot undo the deletion.

The suite editor has four pages:

| Page | Purpose |
|---|---|
| **Cases** | Edit, add, duplicate, delete, or import cases. |
| **Results** | Read run history and the pass-rate chart. |
| **Compare** | Compare saved runs and inspect experiments. A comparison needs two runs. |
| **Setup** | Set instructions, scoring, the model, tools, output, the session profile, and performance. |

Intents saves suite edits automatically. Before you leave the suite, read the save status near its name. This is especially useful after a storage error.

## Write cases

1. Open **Cases**. Select a case in the left panel.
2. Enter a name and the exact prompt to send to the model.
3. Enter the expected value that your scoring method requires.
4. Use **Case actions** to duplicate or delete the case. A suite keeps at least one case.

The case field has a different label for each scoring method. **Exact text** uses **Expected response**. **Contains text** uses **Required text**. **AI rubric** has an optional **Reference answer**. **Collect only** has no expected-text field.

Use **Field checks** for exact checks on fields in structured JSON. A case can also have **Conversation** settings for more than one turn. Read [Models, scoring, and tools](Models-scoring-and-tools.md) before you combine field checks, tools, and an AI rubric.

## Import many cases

1. In **Cases**, select **Import Cases** beside **Add Case**.
2. Select a UTF-8 **CSV** or **JSON Lines** file.
3. Make sure that the selected format is correct.
4. Map a **Prompt** column. You can also map **Name** and **Expected** columns.
5. Read the preview and its warnings.
6. Select **Import _N_ Cases** after the preview accepts the rows.

Each line in a JSON Lines file is a JSON object. Nothing enters the suite before the preview accepts the file. The import button shows the number of cases that fit in the suite. After import, review expected text against the suite's scoring method.

## Add reference files to a suite

1. Open **Setup → Instructions → Reference files**.
2. Select **Add Files**, or drop files in the reference area.
3. Wait until the app finishes processing the files.

Intents accepts text, JSON, CSV, PDF, and image files. A suite can contain up to four images. Every case uses these shared files. If you remove a file, future runs omit it. Saved runs keep their recorded context.

Use **Setup → Model → Context and tool limits** to choose how the model receives reference text. Direct inclusion puts text in the request. Lookup delivery lets the model request relevant text with a tool. The input ceiling and context policy can limit large requests.

For image input, Intents cannot always count all input tokens. Read the saved admission and error details in the run. Before you import sensitive material, read [Data and privacy](Data-and-troubleshooting.md).
