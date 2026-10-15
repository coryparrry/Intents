import * as React from "react";

import {
  Plus,
  MoreHorizontal,
  Copy,
  Trash2,
  Check,
  WandSparkles,
  Settings2,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

import { Badge } from "@/components/ui/badge";

import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
} from "@/components/ui/dropdown-menu";

import {
  Accordion,
  AccordionItem,
  AccordionTrigger,
  AccordionContent,
} from "@/components/ui/accordion";
import {
  Field,
  FieldGroup,
  FieldLabel,
  FieldDescription,
} from "@/components/ui/field";

import {
  Empty,
  EmptyHeader,
  EmptyTitle,
  EmptyDescription,
} from "@/components/ui/empty";

import {
  caseEditingSelection,
  duplicateCase,
  removeCase,
  addCase,
} from "./case-actions";

import {
  isAppSuiteFormat,
  caseEditorDetails,
  commitCaseEditorDetails,
} from "../suite-form-state.js";
type Context = any;
import { Action, invoke, Choice, TextField } from "./shared";
export function Cases({ ctx }: { ctx: Context }) {
  const { state, actions } = ctx;
  const draft = state.draft;
  const [query, setQuery] = React.useState(state.caseSearch);
  const [, redraw] = React.useReducer((value) => value + 1, 0);
  const selection = caseEditingSelection(draft, state.caseId, query);
  const selected = selection.selected;
  const appFormat = isAppSuiteFormat(draft);
  const details = caseEditorDetails(selected);
  if (selected) state.caseId = selected.id;
  const edit = (object: any, key: string, value: any) => {
    object[key] = value;
    commitCaseEditorDetails(draft, selected, details);
    ctx.changed();
    redraw();
  };
  const mutate = (action: () => void) => {
    action();
    commitCaseEditorDetails(draft, selected, details);
    ctx.changed();
    ctx.renderMain();
  };
  const conversation = details.conversation;
  const projection = conversation.modelHistoryProjection;
  const checks = details.checks;
  return (
    <div className="flex min-h-full flex-col">
      <div className="flex flex-wrap items-center justify-between gap-3 border-b bg-background px-6 py-5">
        <div className="flex min-w-0 flex-1 flex-col gap-2">
          <Input
            aria-label="Suite name"
            value={draft.name}
            onChange={(event) => {
              edit(draft, "name", event.target.value);
              ctx.renderToolbar();
            }}
            className="max-w-lg"
          />
          <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
            <span>{draft.cases.length} cases</span>
            <span>·</span>
            <span>{appFormat ? ctx.scoringLabel(draft.scoringMode) : "Per-case scoring"}</span>
            <span>·</span>
            <span>On this Mac</span>
            <Badge variant="outline">
              <span id="save-state">{state.dirty ? "Saving…" : "Saved"}</span>
            </Badge>
          </div>
        </div>
        <Action
          ctx={ctx}
          action={actions.suiteDetails}
          variant="outline"
          size="sm"
        >
          Suite details
        </Action>
      </div>
      <div className="grid flex-1 grid-cols-1 md:grid-cols-[220px_minmax(0,1fr)]">
        <section
          className="flex flex-col gap-4 border-b bg-muted/30 p-4 md:border-r md:border-b-0"
          aria-label="Cases"
        >
          <div className="flex items-center justify-between">
            <h2 className="text-sm font-semibold">Cases</h2>
            <Badge variant="secondary">{draft.cases.length}</Badge>
          </div>
          <Input
            aria-label="Find a case"
            placeholder="Find a case…"
            value={query}
            onChange={(event) => {
              state.caseSearch = event.target.value;
              setQuery(event.target.value);
            }}
          />
          <div className="flex max-h-48 flex-col gap-1 overflow-y-auto md:max-h-none">
            {selection.visible.map((test: any, index: number) => (
              <Button
                key={test.id}
                variant={test.id === selected?.id ? "secondary" : "ghost"}
                aria-pressed={test.id === selected?.id}
                className="h-auto justify-start py-3 whitespace-normal"
                onClick={() => {
                  state.caseId = test.id;
                  ctx.renderMain();
                }}
              >
                <span className="flex min-w-0 flex-col items-start gap-1">
                  <span className="text-left">
                    {ctx.caseTitle(test, index)}
                  </span>
                  <span className="line-clamp-1 text-left text-xs text-muted-foreground">
                    {test.prompt || "Add a prompt"}
                  </span>
                </span>
              </Button>
            ))}
          </div>
          <div className="flex flex-wrap gap-2">
            <Button
              variant="outline"
              size="sm"
              disabled={draft.cases.length >= 100}
              onClick={() =>
                mutate(() => {
                  state.caseId = addCase(draft).id;
                  state.caseSearch = "";
                  setQuery("");
                })
              }
            >
              <Plus data-icon="inline-start" />
              Add Case
            </Button>
            <Action
              ctx={ctx}
              action={ctx.importCases}
              variant="ghost"
              size="sm"
            >
              Import
            </Action>
          </div>
        </section>
        {!selected ? (
          <Empty>
            <EmptyHeader>
              <EmptyTitle>No matching cases</EmptyTitle>
              <EmptyDescription>
                Try another search or add a case.
              </EmptyDescription>
            </EmptyHeader>
          </Empty>
        ) : (
          <div key={selected.id} className="flex min-w-0 flex-col">
            <div className="flex items-center justify-between gap-3 border-b px-6 py-4">
              <Input
                aria-label="Case name"
                value={selected.name || ""}
                onChange={(event) => edit(selected, "name", event.target.value)}
                className="max-w-md"
              />
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button
                    variant="ghost"
                    size="icon-sm"
                    aria-label="Case actions"
                  >
                    <MoreHorizontal />
                  </Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end">
                  <DropdownMenuGroup>
                    <DropdownMenuItem
                      disabled={draft.cases.length >= 100}
                      onSelect={() =>
                        mutate(() => {
                          state.caseId = duplicateCase(draft, selected.id).id;
                        })
                      }
                    >
                      <Copy />
                      Duplicate case
                    </DropdownMenuItem>
                    <DropdownMenuItem
                      variant="destructive"
                      disabled={draft.cases.length === 1}
                      onSelect={() =>
                        mutate(() => {
                          state.caseId = removeCase(draft, selected.id);
                        })
                      }
                    >
                      <Trash2 />
                      Delete case
                    </DropdownMenuItem>
                  </DropdownMenuGroup>
                </DropdownMenuContent>
              </DropdownMenu>
            </div>
            <div className="grid grid-cols-1 xl:grid-cols-[minmax(0,1fr)_280px]">
              <section className="flex min-w-0 flex-col gap-6 p-6">
                <FieldGroup>
                  <TextField
                    label="Prompt"
                    value={selected.prompt}
                    onChange={(value: string) =>
                      edit(selected, "prompt", value)
                    }
                    multiline
                    rows={9}
                  />
                  <div className="flex justify-end">
                    <DropdownMenu>
                      <DropdownMenuTrigger asChild>
                        <Button
                          variant="outline"
                          size="sm"
                          disabled={!selected.prompt?.trim() || ctx.active()}
                        >
                          <WandSparkles data-icon="inline-start" />
                          Writing Tools
                        </Button>
                      </DropdownMenuTrigger>
                      <DropdownMenuContent align="end">
                        <DropdownMenuGroup>
                          {[
                            ["rewrite", "Rewrite"],
                            ["grammar", "Grammar"],
                            ["shorten", "Shorten"],
                            ["tone", "Change tone"],
                            ["prompt", "Custom request"],
                          ].map(([id, label]) => (
                            <DropdownMenuItem
                              key={id}
                              onSelect={() =>
                                invoke(ctx, () =>
                                  ctx.rewritePrompt(selected, id),
                                )
                              }
                            >
                              {label}
                            </DropdownMenuItem>
                          ))}
                        </DropdownMenuGroup>
                      </DropdownMenuContent>
                    </DropdownMenu>
                  </div>
                  <TextField
                    label={
                      draft.scoringMode === "modelJudge"
                        ? "Reference answer"
                        : "Expected response"
                    }
                    value={selected.expected}
                    onChange={(value: string) =>
                      edit(selected, "expected", value)
                    }
                    multiline
                    rows={5}
                    description={
                      draft.scoringMode === "modelJudge"
                        ? "Give the judge a known-good answer when correctness can be verified."
                        : undefined
                    }
                  />
                  {!draft.scoringMode && (
                    <Choice
                      label="Scoring"
                      value={selected.scoring || "none"}
                      options={[
                        ["exact", "Exact match"],
                        ["contains", "Contains"],
                        ["none", "Trace only"],
                      ]}
                      onChange={(value: string) =>
                        edit(selected, "scoring", value)
                      }
                    />
                  )}
                </FieldGroup>
              </section>
              {appFormat && (
                <section
                className="border-t bg-muted/20 p-5 xl:border-l xl:border-t-0"
                aria-label="Case inspector"
              >
                <div className="mb-3 flex items-center gap-2 text-sm font-medium">
                  <Settings2 className="size-4" />
                  Case inspector
                </div>
                <Accordion type="multiple">
                  <AccordionItem value="checks">
                    <AccordionTrigger>
                      Field checks{" "}
                      <Badge variant="outline">{checks.length}</Badge>
                    </AccordionTrigger>
                    <AccordionContent>
                      <FieldGroup>
                        {checks.map((check: any) => (
                          <div
                            key={check.id}
                            className="flex flex-col gap-4 rounded-lg border p-3"
                          >
                            <TextField
                              label="JSON pointer"
                              value={check.pointer}
                              onChange={(value: string) =>
                                edit(check, "pointer", value)
                              }
                            />
                            <Choice
                              label="Check"
                              value={check.operation}
                              options={[
                                ["exists", "Exists"],
                                ["equals", "Equals JSON value"],
                                ["containsText", "Contains text"],
                                ["minimum", "Number ≥"],
                                ["maximum", "Number ≤"],
                              ]}
                              onChange={(value: string) =>
                                edit(check, "operation", value)
                              }
                            />
                            {check.operation !== "exists" && (
                              <TextField
                                label="Expected value"
                                value={check.expectedValue}
                                onChange={(value: string) =>
                                  edit(check, "expectedValue", value)
                                }
                              />
                            )}
                            <Button
                              variant="ghost"
                              size="sm"
                              onClick={() =>
                                mutate(() =>
                                  checks.splice(checks.indexOf(check), 1),
                                )
                              }
                            >
                              Remove check
                            </Button>
                          </div>
                        ))}
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() =>
                            mutate(() =>
                              checks.push({
                                id: crypto.randomUUID(),
                                pointer: "",
                                operation: "exists",
                                expectedValue: "",
                              }),
                            )
                          }
                        >
                          <Plus data-icon="inline-start" />
                          Add check
                        </Button>
                      </FieldGroup>
                    </AccordionContent>
                  </AccordionItem>
                  <AccordionItem value="conversation">
                    <AccordionTrigger>Conversation setup</AccordionTrigger>
                    <AccordionContent>
                      <FieldGroup>
                        <FieldDescription>
                          Run setup turns in the same session before the final
                          prompt.
                        </FieldDescription>
                        {conversation.setupTurns.map(
                          (turn: any, index: number) => (
                            <FieldGroup key={turn.id}>
                              <TextField
                                label={`Setup turn ${index + 1}`}
                                value={turn.prompt}
                                multiline
                                onChange={(value: string) =>
                                  edit(turn, "prompt", value)
                                }
                              />
                              <Button
                                variant="ghost"
                                size="sm"
                                onClick={() =>
                                  mutate(() =>
                                    conversation.setupTurns.splice(index, 1),
                                  )
                                }
                              >
                                Remove turn
                              </Button>
                            </FieldGroup>
                          ),
                        )}
                        <Button
                          variant="outline"
                          size="sm"
                          disabled={conversation.setupTurns.length >= 12}
                          onClick={() =>
                            mutate(() =>
                              conversation.setupTurns.push({
                                id: crypto.randomUUID(),
                                prompt: "",
                              }),
                            )
                          }
                        >
                          <Plus data-icon="inline-start" />
                          Add setup turn
                        </Button>
                        <Choice
                          label="Session history"
                          value={conversation.historyPolicy}
                          options={[
                            ["keepAll", "Keep all history"],
                            ["resetBeforeFinal", "Reset before final prompt"],
                            [
                              "retainRecentCompleteTurns",
                              "Keep recent complete turns",
                            ],
                          ]}
                          onChange={(value: string) =>
                            edit(conversation, "historyPolicy", value)
                          }
                        />
                        {conversation.historyPolicy ===
                          "retainRecentCompleteTurns" && (
                          <Field>
                            <FieldLabel>Retained turns</FieldLabel>
                            <Input
                              aria-label="Retained turns"
                              type="number"
                              min={1}
                              max={12}
                              value={conversation.retainedTurnCount}
                              onChange={(event) =>
                                edit(
                                  conversation,
                                  "retainedTurnCount",
                                  Number(event.target.value),
                                )
                              }
                            />
                          </Field>
                        )}
                        <TextField
                          label="Restored transcript JSON"
                          value={conversation.restoredTranscriptJSON}
                          multiline
                          onChange={(value: string) =>
                            edit(
                              conversation,
                              "restoredTranscriptJSON",
                              value || undefined,
                            )
                          }
                        />
                        <Choice
                          label="Model-facing history"
                          value={projection.policy}
                          options={[
                            ["keepAll", "Keep all history"],
                            ["reset", "Hide previous turns from the model"],
                            [
                              "retainRecentCompleteTurns",
                              "Keep recent complete turns",
                            ],
                          ]}
                          onChange={(value: string) =>
                            edit(projection, "policy", value)
                          }
                        />
                        {projection.policy === "retainRecentCompleteTurns" && (
                          <Field>
                            <FieldLabel>Model-facing retained turns</FieldLabel>
                            <Input
                              aria-label="Model-facing retained turns"
                              type="number"
                              min={1}
                              max={12}
                              value={projection.retainedTurnCount}
                              onChange={(event) =>
                                edit(
                                  projection,
                                  "retainedTurnCount",
                                  Number(event.target.value),
                                )
                              }
                            />
                          </Field>
                        )}
                      </FieldGroup>
                    </AccordionContent>
                  </AccordionItem>
                </Accordion>
                </section>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
