import * as React from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";

import {
  Select,
  SelectTrigger,
  SelectValue,
  SelectContent,
  SelectGroup,
  SelectItem,
} from "@/components/ui/select";

import { Field, FieldLabel, FieldDescription } from "@/components/ui/field";

type Context = any;
export function invoke(ctx: Context, action: () => unknown) {
  return Promise.resolve().then(action).catch(ctx.fail);
}
export function Action({ ctx, action, children, ...props }: any) {
  const [pending, setPending] = React.useState(false);
  return (
    <Button
      {...props}
      disabled={props.disabled || pending}
      onClick={async () => {
        setPending(true);
        try {
          await action();
        } catch (error) {
          ctx.fail(error);
        } finally {
          setPending(false);
        }
      }}
    >
      {children}
    </Button>
  );
}
export function Choice({ label, value, options, onChange }: any) {
  const id = React.useId();
  return (
    <Field>
      <FieldLabel htmlFor={id}>{label}</FieldLabel>
      <Select value={value} onValueChange={onChange}>
        <SelectTrigger id={id} aria-label={label} className="w-full">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectGroup>
            {options.map(([key, text]: string[]) => (
              <SelectItem key={key} value={key}>
                {text}
              </SelectItem>
            ))}
          </SelectGroup>
        </SelectContent>
      </Select>
    </Field>
  );
}
export function TextField({
  label,
  value,
  onChange,
  multiline = false,
  description,
  rows = 3,
}: any) {
  const id = React.useId();
  return (
    <Field>
      <FieldLabel htmlFor={id}>{label}</FieldLabel>
      {multiline ? (
        <Textarea
          id={id}
          aria-label={label}
          rows={rows}
          className={rows >= 8 ? "min-h-48" : "min-h-28"}
          value={value || ""}
          onChange={(event) => onChange(event.target.value)}
        />
      ) : (
        <Input
          id={id}
          aria-label={label}
          value={value || ""}
          onChange={(event) => onChange(event.target.value)}
        />
      )}{" "}
      {description && <FieldDescription>{description}</FieldDescription>}
    </Field>
  );
}
