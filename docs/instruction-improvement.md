# Improve a suite's instructions

Intents can suggest and compare two alternatives to the shared instructions in a
suite. You review the results and choose whether to apply a suggestion.

Use a scored suite with at least two distinct cases and at most 100 planned
samples (cases × repetitions). Document suites are not supported. Generating
suggestions requires Apple's on-device model to be available, even when the
suite uses another provider for comparisons.

## Start a comparison

1. Open a suite and choose **Improve instructions** from **Setup → Instructions**
   or **Compare → Instruction experiments**.
2. Use at least two distinct cases with scoring enabled. Resolve any readiness
   issue shown in the setup sheet.
3. Review the **Practice** and **Final check** groups. Expand **Choose examples**
   to change which cases are reserved for the final check. Keep at least one case
   in each group and use fresh final-check cases for each comparison.
4. Read the maximum response budget before starting. Suggestions are written on
   this Mac. Comparisons use the suite's model, tools, references, and scoring,
   including an approved external judge when configured.

Intents saves the suite definition and the selected groups with the comparison.
It changes only the shared instructions; case prompts, expected answers, rubrics,
tools, and model settings remain part of the frozen comparison.

## Read the result

Intents runs the original instructions on Practice cases, generates two
suggestions using those cases and outputs, and compares both suggestions on the
same cases. Final-check cases and outputs are withheld from suggestion generation.

Only a suggestion with a higher Practice pass rate advances to the final check.
Intents then compares that suggestion and the original instructions on the
reserved cases. A suggestion is eligible to apply only when the evidence is
complete and error-free and no final-check case's pass rate gets worse.

Review the pass counts, both instruction texts, and the saved evidence before
applying. These counts describe the selected cases; they do not establish
statistical significance or guarantee better responses on other inputs.

## Save or cancel

Nothing is applied automatically. Applying a suggestion requires the source suite
and instruction draft to still match the comparison. If they have changed, start
a new comparison with suitable fresh final-check cases.

You can close and reopen the comparison while it runs, or cancel it. Cancelled,
interrupted, incomplete, and unsuccessful comparisons cannot be applied. Read any
storage error before leaving the result. Completed comparison runs also appear
in run history, where you can inspect their traces.

Use [Review outputs and check a judge](EVAL_REVIEW_GUIDE.md) to inspect scoring
evidence and confirmed failures before deciding what to improve next.
