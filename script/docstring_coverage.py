#!/usr/bin/env python3
"""Measure authored function documentation without executing application source."""

from __future__ import annotations

import argparse
import ast
from collections import Counter
from dataclasses import asdict, dataclass, replace
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = {".swift": "Swift", ".py": "Python", ".js": "JavaScript", ".mjs": "JavaScript",
             ".cjs": "JavaScript", ".ts": "TypeScript", ".tsx": "TypeScript", ".jsx": "JavaScript",
             ".sh": "Shell"}
MODIFIERS = frozenset("public private fileprivate internal open package static class final override "
                      "required convenience mutating nonmutating nonisolated isolated distributed "
                      "borrowing consuming sending prefix postfix infix dynamic optional lazy weak unowned".split())


@dataclass(frozen=True)
class Declaration:
    """Locate one authored function-like declaration and its documentation state."""

    path: str
    line: int
    name: str
    kind: str
    language: str
    documented: bool
    start_line: int | None = None
    end_line: int | None = None


@dataclass(frozen=True)
class Token:
    """Preserve Swift token positions while excluding string and comment examples."""

    value: str
    start: int
    end: int
    line: int
    kind: str = "code"


def source_language(path: str, include_tests: bool = False) -> str | None:
    """Select authored source, retaining adapted engine and published website scripts."""
    item = Path(path)
    parts = [part.lower() for part in item.parts]
    excluded = {"node_modules", ".git", ".build", ".swiftpm", "deriveddata", "build", "builds",
                "vendor", "assets", "fixtures", "__pycache__", "coverage"}
    if any(part in excluded or (not include_tests and (part in {"test", "tests", "uitests"} or part.endswith("tests")))
           for part in parts[:-1]):
        return None
    name = item.name.lower()
    if not include_tests and ((name.startswith("test_") and path != "script/test_production_evals.py") or re.search(
            r"(?:[._-](?:test|tests|spec))\.(?:swift|py|[cm]?js|[jt]sx?)$", name)):
        return None
    if (not include_tests and name.endswith("tests.swift")) or re.search(r"\.generated\.(?:swift|py|[cm]?js|[jt]sx?)$", name) or name.endswith(".min.js"):
        return None
    return "Swift" if path == "script/foundation-evals" else LANGUAGES.get(item.suffix.lower())


def git_sources(root: Path, filters: list[str], include_tests: bool = False) -> list[tuple[str, str]]:
    """Inventory tracked and nonignored untracked source, optionally within path prefixes."""
    result = subprocess.run(["git", "-C", str(root), "ls-files", "--cached", "--others",
                             "--exclude-standard", "-z"], check=True, capture_output=True)
    selected = []
    normalized = [value.removeprefix("./").rstrip("/") for value in filters]
    for path in sorted(set(result.stdout.decode("utf-8").split("\0")) - {""}):
        language = source_language(path, include_tests)
        if language and (root / path).is_file() and (not normalized or any(
                path == prefix or path.startswith(prefix + "/") for prefix in normalized)):
            selected.append((path, language))
    return selected


def swift_block_comment_end(source: str, start: int) -> int:
    """Skip nested Swift block comments and reject an unfinished comment."""
    index, depth = start + 2, 1
    while depth and index < len(source):
        if source.startswith("/*", index):
            depth += 1
            index += 2
        elif source.startswith("*/", index):
            depth -= 1
            index += 2
        else:
            index += 1
    if depth:
        raise ValueError(f"Unterminated Swift comment at offset {start}")
    return index


def swift_interpolation_end(source: str, start: int) -> int:
    """Skip balanced string interpolation, including strings and comments in its expression."""
    index, depth = start, 1
    while index < len(source):
        if source.startswith("/*", index):
            index = swift_block_comment_end(source, index)
            continue
        if source.startswith("//", index):
            newline = source.find("\n", index)
            index = len(source) if newline < 0 else newline
            continue
        if re.match(r'(#+)?("""|")', source[index:]):
            index = swift_string_end(source, index)
            continue
        if re.match(r'#+/', source[index:]):
            index = swift_regex_end(source, index)
            continue
        if source[index] == "(":
            depth += 1
        elif source[index] == ")":
            depth -= 1
            if not depth:
                return index + 1
        index += 1
    raise ValueError(f"Unterminated Swift interpolation at offset {start}")


def swift_string_end(source: str, start: int) -> int:
    """Skip a complete Swift string, preserving nested quotes inside interpolation expressions."""
    match = re.match(r'(#+)?("""|")', source[start:])
    hashes, quote = match.group(1) or "", match.group(2)
    closing, escape = quote + hashes, "\\" + hashes
    index = start + len(match.group(0))
    while index < len(source):
        if source.startswith(closing, index):
            return index + len(closing)
        if source.startswith(escape + "(", index):
            index = swift_interpolation_end(source, index + len(escape) + 1)
        elif source.startswith(escape, index):
            index += len(escape) + 1
        else:
            index += 1
    raise ValueError(f"Unterminated Swift string at offset {start}")


def swift_regex_end(source: str, start: int) -> int:
    """Skip extended Swift regex literals so their pattern text cannot invent functions."""
    match = re.match(r'(#+)/', source[start:])
    hashes = match.group(1)
    index = start + len(match.group(0))
    while index < len(source):
        if source.startswith("/" + hashes, index):
            return index + len(hashes) + 1
        if source.startswith("\\" + hashes, index):
            index += len(hashes) + 2
        else:
            index += 1
    raise ValueError(f"Unterminated Swift regex at offset {start}")


def swift_bare_regex_end(source: str, start: int, tokens: list[Token]) -> int | None:
    """Recognize slash regexes at expression starts without treating division as a literal."""
    previous = next((token.value for token in reversed(tokens) if token.kind not in {"doc", "comment"}), None)
    expression_starts = {None, "=", "(", "[", "{", ",", ":", ";", "return", "throw", "yield",
                         "case", "in", "if", "while", "guard", "try", "!", "?", "+", "-", "*",
                         "%", "&", "|", "^", "~", "<", ">"}
    if previous not in expression_starts or start + 1 >= len(source) or source[start + 1].isspace():
        return None
    index, character_class = start + 1, False
    while index < len(source) and source[index] not in "\r\n":
        char = source[index]
        if char == "\\":
            index += 2
            continue
        if char == "[":
            character_class = True
        elif char == "]":
            character_class = False
        elif char == "/" and not character_class:
            return index + 1 if not source[index - 1].isspace() else None
        index += 1
    return None


def swift_tokens(source: str) -> list[Token]:
    """Lex Swift including nested comments, escaped strings, and raw multiline literals."""
    tokens = []
    index = 0
    line = 1
    length = len(source)
    while index < length:
        start, start_line = index, line
        char = source[index]
        if char.isspace():
            line += char == "\n"
            index += 1
            continue
        if source.startswith("//", index):
            end = source.find("\n", index)
            index = length if end < 0 else end
            text = source[start:index]
            kind = "doc" if text.startswith("///") else "comment"
            tokens.append(Token(text, start, index, line, kind))
            continue
        if source.startswith("/*", index):
            index = swift_block_comment_end(source, index)
            text = source[start:index]
            line += text.count("\n")
            kind = "doc" if text.startswith("/**") else "comment"
            tokens.append(Token(text, start, index, start_line, kind))
            continue
        string = re.match(r'(#+)?("""|")', source[index:])
        regex = re.match(r'#+/', source[index:])
        if string or regex:
            index = swift_string_end(source, index) if string else swift_regex_end(source, index)
            line += source[start:index].count("\n")
            tokens.append(Token("<literal>", start, index, start_line, "string"))
            continue
        if char == "/":
            end = swift_bare_regex_end(source, index, tokens)
            if end is not None:
                index = end
                tokens.append(Token("<literal>", start, index, start_line, "string"))
                continue
        identifier = re.match(r"`[^`]+`|[A-Za-z_$][\w$]*", source[index:])
        if identifier:
            index += len(identifier.group(0))
        else:
            index += 1
        tokens.append(Token(source[start:index], start, index, start_line))
    return tokens


def matching_open(tokens: list[Token], end: int) -> int | None:
    """Find a balanced attribute or access-modifier argument list while walking backward."""
    depth = 0
    for index in range(end, -1, -1):
        if tokens[index].value == ")":
            depth += 1
        elif tokens[index].value == "(":
            depth -= 1
            if not depth:
                return index
    return None


def swift_prefix(tokens: list[Token], declaration: int) -> int:
    """Include modifiers and multiline attributes when associating preceding Swift docs."""
    cursor = declaration
    while cursor:
        previous = cursor - 1
        if tokens[previous].value in MODIFIERS:
            cursor = previous
            continue
        end = previous
        if tokens[end].value == ")":
            opening = matching_open(tokens, end)
            if opening is None or opening == 0:
                break
            end = opening - 1
            if tokens[end].value in MODIFIERS:
                cursor = end
                continue
        # An attribute name may be module-qualified, for example @SwiftUI.State.
        if re.fullmatch(r"[\w`]+", tokens[end].value):
            while end >= 2 and tokens[end - 1].value == ".":
                end -= 2
            if end and tokens[end - 1].value == "@":
                cursor = end - 1
                continue
        break
    return cursor


def swift_documented(tokens: list[Token], prefix: int) -> bool:
    """Accept a nonempty contiguous documentation run, including trailing blank doc markers."""
    cursor = prefix - 1
    documented = False
    while cursor >= 0 and tokens[cursor].kind == "doc":
        value = tokens[cursor].value
        body = value[3:] if value.startswith("///") else value[3:-2]
        documented = documented or bool(body.strip("*/ \t\r\n"))
        cursor -= 1
    return documented


def swift_declaration_end(tokens: list[Token], declaration: int) -> int:
    """Find a Swift body or bodyless requirement without consuming the next member."""
    parens = brackets = depth = 0
    previous = tokens[declaration]
    for index, token in enumerate(tokens[declaration + 1:], declaration + 1):
        if token.kind != "code":
            continue
        value = token.value
        if depth:
            depth += (value == "{") - (value == "}")
            if not depth:
                return token.line
            continue
        if not parens and not brackets:
            if value == "{":
                depth = 1
                continue
            if value in {"}", ";", "func", "init", "deinit", "subscript", "var", "let", "associatedtype", "@"}:
                prefix = swift_prefix(tokens, index)
                while prefix > declaration and tokens[prefix - 1].kind in {"doc", "comment"}:
                    prefix -= 1
                return tokens[max(declaration, prefix - 1)].line
        parens += (value == "(") - (value == ")")
        brackets += (value == "[") - (value == "]")
        previous = token
    return previous.line


def swift_declarations(path: str, source: str) -> list[Declaration]:
    """Count functions, operators, explicit lifecycle methods, and protocol requirements."""
    tokens = swift_tokens(source)
    declarations = []
    for index, token in enumerate(tokens):
        if token.kind != "code" or token.value not in {"func", "init", "deinit", "subscript"}:
            continue
        previous = index - 1
        while previous >= 0 and tokens[previous].kind in {"doc", "comment"}:
            previous -= 1
        if previous >= 0 and tokens[previous].value == ".":
            continue
        following = index + 1
        if token.value == "func":
            if following >= len(tokens) or tokens[following].value in {"(", "{", ";"}:
                continue
            name = tokens[following].value
            if not re.fullmatch(r"`[^`]+`|[A-Za-z_$][\w$]*", name):
                while following + 1 < len(tokens) and tokens[following + 1].start == tokens[following].end \
                        and tokens[following + 1].value != "(":
                    following += 1
                    name += tokens[following].value
        else:
            name = token.value
            if following < len(tokens) and tokens[following].value in {"?", "!"}:
                following += 1
            expected = {"{"} if token.value == "deinit" else {"(", "<"}
            if following >= len(tokens) or tokens[following].value not in expected:
                continue
        prefix = swift_prefix(tokens, index)
        documented = swift_documented(tokens, prefix)
        start = prefix
        while start and tokens[start - 1].kind == "doc":
            start -= 1
        declarations.append(Declaration(path, token.line, name, token.value, "Swift", documented,
                                        tokens[start].line, swift_declaration_end(tokens, index)))
    return declarations


def python_declarations(path: str, source: str) -> list[Declaration]:
    """Use Python's AST to count every sync or async function, including nested definitions."""
    tree = ast.parse(source, filename=path)
    return [Declaration(path, node.lineno, node.name, "async def" if isinstance(node, ast.AsyncFunctionDef)
                        else "def", "Python", bool((ast.get_docstring(node) or "").strip()),
                        min([node.lineno] + [item.lineno for item in node.decorator_list]), node.end_lineno)
            for node in ast.walk(tree) if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))]


def shell_code_line(text: str, quote: str | None) -> tuple[str, str | None, list[tuple[str, bool]]]:
    """Mask quoted/comment text while recognizing heredoc operators only in shell code."""
    code = list(text)
    heredocs = []
    index = 0
    while index < len(text):
        char = text[index]
        if quote:
            code[index] = " "
            if char == "\\" and quote != "'" and index + 1 < len(text):
                index += 1
                code[index] = " "
            elif char == quote:
                quote = None
        elif char == "#" and (index == 0 or text[index - 1].isspace()):
            code[index:] = " " * (len(text) - index)
            break
        elif char in "'\"`":
            quote = char
            code[index] = " "
        elif char == "\\" and index + 1 < len(text):
            code[index:index + 2] = "  "
            index += 1
        elif text.startswith("<<<", index):
            index += 2
        elif text.startswith("<<", index):
            match = re.match(r"<<(-?)\s*(['\"]?)([A-Za-z_]\w*)\2", text[index:])
            if match:
                heredocs.append((match.group(3), bool(match.group(1))))
                index += len(match.group(0)) - 1
        index += 1
    return "".join(code), quote, heredocs


def shell_function_complete(source: str) -> bool:
    """Use Bash's parse-only mode to distinguish block braces from literal shell arguments.

    No source runs, and an isolated environment prevents startup-file injection.
    Partial bodies fail syntax validation until their actual closing brace arrives.
    """
    result = subprocess.run(["bash", "--noprofile", "--norc", "-n"], input=source,
                            text=True, capture_output=True, env={"PATH": os.defpath}, check=False)
    return result.returncode == 0


def shell_declarations(path: str, source: str) -> list[Declaration]:
    """Count named shell definitions, omitting quoted examples and actual heredoc bodies."""
    declarations = []
    comments = []
    heredocs = []
    quote = None
    active = []
    lines = source.splitlines()
    for line, text in enumerate(lines, 1):
        if heredocs:
            delimiter, strip_tabs = heredocs[0]
            if (text.lstrip("\t") if strip_tabs else text) == delimiter:
                heredocs.pop(0)
            continue
        stripped = text.strip()
        if quote is None and stripped.startswith("#"):
            comments.append(stripped[1:].strip())
            continue
        code, quote, pending = shell_code_line(text, quote)
        match = re.match(r"\s*(?:function\s+([A-Za-z_]\w*)\s*(?:\(\s*\))?|([A-Za-z_]\w*)\s*\(\s*\))\s*\{", code)
        if match:
            documented = any(re.search(r"[A-Za-z]{2,}", comment) and not comment.startswith("!")
                             for comment in comments)
            declarations.append(Declaration(path, line, match.group(1) or match.group(2),
                                            "function", "Shell", documented,
                                            line - len(comments), line))
            active.append(len(declarations) - 1)
        completed = []
        for index in active:
            item = declarations[index]
            declarations[index] = replace(item, end_line=line)
            if "}" in code and shell_function_complete("\n".join(lines[item.line - 1:line])):
                completed.append(index)
        active = [index for index in active if index not in completed]
        if stripped:
            comments = []
        heredocs.extend(pending)
    if quote is not None or heredocs or active:
        raise ValueError(f"{path}: unterminated shell function, quote, or heredoc")
    return declarations


def javascript_declarations(root: Path, sources: list[str]) -> list[Declaration]:
    """Parse JS and TS in one Node subprocess using the repository-pinned Babel dependency."""
    if not sources:
        return []
    helper = ROOT / "Tools" / "DocstringCoverage" / "parse.mjs"
    result = subprocess.run(["node", str(helper)], input=json.dumps({"root": str(root), "paths": sources}),
                            text=True, capture_output=True, check=False)
    if result.returncode:
        raise ValueError(result.stderr.strip() or "JavaScript parser failed without diagnostics")
    return [Declaration(**item) for item in json.loads(result.stdout)]


def measure(root: Path, filters: list[str], include_tests: bool = False) -> list[Declaration]:
    """Collect language-specific declarations, propagating inventory, decoding, and parse failures."""
    declarations = []
    javascript = []
    for path, language in git_sources(root, filters, include_tests):
        if language in {"JavaScript", "TypeScript"}:
            javascript.append(path)
            continue
        source = (root / path).read_text(encoding="utf-8")
        try:
            parser = {"Swift": swift_declarations, "Python": python_declarations, "Shell": shell_declarations}[language]
            declarations.extend(parser(path, source))
        except (SyntaxError, ValueError) as error:
            raise ValueError(f"{path}: {error}") from error
    declarations.extend(javascript_declarations(root, javascript))
    return sorted(declarations, key=lambda item: (item.path, item.line, item.name))


def summarize(declarations: list[Declaration]) -> dict:
    """Return exact counts and unrounded percentage; zero declarations never pass a gate."""
    total = len(declarations)
    documented = sum(item.documented for item in declarations)
    languages = {}
    for language, count in sorted(Counter(item.language for item in declarations).items()):
        covered = sum(item.documented for item in declarations if item.language == language)
        languages[language] = {"total": count, "documented": covered, "coverage": 100 * covered / count}
    return {"total": total, "documented": documented, "missing": total - documented,
            "coverage": 100 * documented / total if total else 0, "languages": languages,
            "files": len({item.path for item in declarations})}


def main(argv: list[str] | None = None) -> int:
    """Print text or JSON coverage and enforce an optional minimum without rounding it upward."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", help="Restrict to repository-relative files or directory prefixes")
    parser.add_argument("--path", action="append", default=[], help="Additional file or directory prefix")
    parser.add_argument("--root", type=Path, default=ROOT, help="Git checkout to inspect")
    parser.add_argument("--json", action="store_true", help="Emit summary and declarations as JSON")
    parser.add_argument("--missing", action="store_true", help="List only undocumented declarations")
    parser.add_argument("--minimum", type=float, help="Fail if coverage is below this percentage (0 through 100)")
    args = parser.parse_args(argv)
    if args.minimum is not None and not 0 <= args.minimum <= 100:
        parser.error("--minimum must be between 0 and 100")
    try:
        declarations = measure(args.root.resolve(), args.paths + args.path)
        report = summarize(declarations)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Documentation coverage failed: {error}", file=sys.stderr)
        return 2
    selected = [item for item in declarations if not args.missing or not item.documented]
    if args.json:
        print(json.dumps({**report, "declarations": [asdict(item) for item in selected]}, indent=2))
    else:
        print(f"Function documentation: {report['documented']}/{report['total']} ({report['coverage']:.2f}%)")
        for language, counts in report["languages"].items():
            print(f"  {language}: {counts['documented']}/{counts['total']} ({counts['coverage']:.2f}%)")
        if args.missing:
            for item in selected:
                print(f"{item.path}:{item.line}: {item.kind} {item.name}")
    return int(args.minimum is not None and (not report["total"] or report["coverage"] < args.minimum))


if __name__ == "__main__":
    sys.exit(main())
