import * as React from "react";

import { ListChecks, Plus, Play, History, ChevronRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

import { Badge } from "@/components/ui/badge";

import {
  Table,
  TableHeader,
  TableHead,
  TableBody,
  TableRow,
  TableCell,
} from "@/components/ui/table";
import {
  Card,
  CardHeader,
  CardTitle,
  CardDescription,
  CardContent,
} from "@/components/ui/card";

import {
  Empty,
  EmptyHeader,
  EmptyTitle,
  EmptyDescription,
} from "@/components/ui/empty";

import { appSuiteHealth } from "../native-overview.js";

type Context = any;
import { Action } from "./shared";
/** Renders project suite-health summaries, searchable suite actions and recent non-running reports. */
export function Overview({ ctx }: { ctx: Context }) {
  const { state } = ctx;
  const project = state.projects.find(
    (item: any) => item.id === state.projectId,
  );
  const assessments = state.suites.map((suite: any) => ({
    suite,
    ...appSuiteHealth(suite, state.runs),
  }));
  const [query, setQuery] = React.useState("");
  const [attention, setAttention] = React.useState(false);
  const visible = assessments.filter(
    (item: any) =>
      (!attention || item.kind === "attention") &&
      item.suite.name.toLowerCase().includes(query.toLowerCase()),
  );
  return (
    <div className="mx-auto flex w-full max-w-6xl flex-col gap-6 p-6 lg:p-8">
      <div className="flex items-start justify-between gap-4">
        <div className="flex flex-col gap-1">
          <h1 className="text-2xl font-semibold tracking-tight">
            {project?.name || "My evaluations"}
          </h1>
          <p className="text-sm text-muted-foreground">
            Build, run, and compare evaluations on your Mac.
          </p>
        </div>
        <Action ctx={ctx} action={ctx.createSuite} size="sm">
          <Plus data-icon="inline-start" />
          New Suite
        </Action>
      </div>
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        {[
          ["Suites", state.suites.length, "Evaluation definitions"],
          [
            "Passing",
            assessments.filter((item: any) => item.kind === "passing").length,
            "Latest responses passed",
          ],
          [
            "Needs attention",
            assessments.filter((item: any) => item.kind === "attention").length,
            "Failures or changed definitions",
          ],
          [
            "Cases",
            state.suites.reduce(
              (sum: number, suite: any) => sum + suite.cases.length,
              0,
            ),
            "Prompts ready to evaluate",
          ],
        ].map(([label, value, detail]) => (
          <Card key={label}>
            <CardHeader>
              <CardDescription>{label}</CardDescription>
              <CardTitle className="text-2xl">{value}</CardTitle>
            </CardHeader>
            <CardContent>
              <p className="text-xs text-muted-foreground">{detail}</p>
            </CardContent>
          </Card>
        ))}
      </div>
      <Card>
        <CardHeader>
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div className="flex flex-col gap-1">
              <CardTitle>Evaluation suites</CardTitle>
              <CardDescription>
                Your prompts, scoring, and model configuration.
              </CardDescription>
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <Button
                variant={attention ? "secondary" : "outline"}
                size="sm"
                aria-pressed={attention}
                onClick={() => setAttention(!attention)}
              >
                Needs attention
              </Button>
              <Input
                aria-label="Find a suite"
                placeholder="Find a suite…"
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                className="w-48"
              />
            </div>
          </div>
        </CardHeader>
        <CardContent>
          <Table aria-label="Evaluation suites">
            <TableHeader>
              <TableRow>
                <TableHead>Suite</TableHead>
                <TableHead>Cases</TableHead>
                <TableHead>Scoring</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="text-right">Run</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {visible.map((item: any) => (
                <TableRow key={item.suite.id}>
                  <TableCell>
                    <Action
                      ctx={ctx}
                      action={() => ctx.selectSuite(item.suite)}
                      variant="ghost"
                      size="sm"
                    >
                      <ListChecks data-icon="inline-start" />
                      {item.suite.name}
                    </Action>
                  </TableCell>
                  <TableCell>{item.suite.cases.length}</TableCell>
                  <TableCell className="text-muted-foreground">
                    {ctx.scoringLabel(item.suite.scoringMode)}
                  </TableCell>
                  <TableCell>
                    <Badge
                      variant={
                        item.kind === "passing" ? "secondary" : "outline"
                      }
                    >
                      {item.title}
                    </Badge>
                  </TableCell>
                  <TableCell className="text-right">
                    <Action
                      ctx={ctx}
                      action={() => ctx.runSuite(item.suite)}
                      variant="outline"
                      size="icon-sm"
                      aria-label={`Run ${item.suite.name}`}
                      disabled={ctx.active() || state.busy}
                    >
                      <Play />
                    </Action>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          {!visible.length && (
            <Empty>
              <EmptyHeader>
                <EmptyTitle>No matching suites</EmptyTitle>
                <EmptyDescription>
                  Try another search or create a suite.
                </EmptyDescription>
              </EmptyHeader>
            </Empty>
          )}
        </CardContent>
      </Card>
      <Card>
        <CardHeader>
          <CardTitle>Recent runs</CardTitle>
          <CardDescription>
            Open a report to inspect responses and execution evidence.
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-2">
          {state.runs
            .filter((run: any) => run.status !== "running")
            .slice(0, 5)
            .map((run: any) => (
              <Action
                key={run.id}
                ctx={ctx}
                action={() => ctx.selectRun(run.id, "report")}
                variant="ghost"
                className="h-auto justify-start py-3"
              >
                <History data-icon="inline-start" />
                <span className="flex flex-1 flex-col items-start gap-1">
                  <span>{run.suiteName}</span>
                  <span className="text-xs text-muted-foreground">
                    {ctx.date(run.startedAt)}
                  </span>
                </span>
                <Badge variant="outline">
                  {run.passed} passed · {run.failed} failed
                </Badge>
                <ChevronRight />
              </Action>
            ))}
          {!state.runs.length && (
            <p className="text-sm text-muted-foreground">
              No runs yet. Run a suite to collect results.
            </p>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
