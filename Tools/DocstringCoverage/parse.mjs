/** Extract named JavaScript and TypeScript functions without running repository code. */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { parse } from '@babel/parser';
import { parseFragment } from 'parse5';

/** Visit authored script elements, including scripts inside inert template fragments. */
function* inlineScripts(node) {
  if (node.tagName === 'script') yield node;
  for (const child of node.childNodes ?? []) yield* inlineScripts(child);
  if (node.content) yield* inlineScripts(node.content);
}

/** Recognize nonempty JSDoc, excluding ordinary block comments and blank markers. */
function hasDoc(node) {
  return (node?.leadingComments ?? []).some(comment => comment.type === 'CommentBlock'
    && comment.value.startsWith('*') && comment.value.slice(1).replace(/[\s*]/g, '').length > 0);
}

/** Return a readable authored identifier, including computed and private method names. */
function keyName(node, source) {
  if (!node) return '<computed>';
  if (node.type === 'PrivateName') return `#${node.id.name}`;
  return node.name ?? String(node.value ?? source.slice(node.start, node.end));
}

/** Read documentation from the function and its immediate declaration/export wrappers. */
function documented(node, ancestors) {
  if (hasDoc(node)) return true;
  const wrappers = new Set(['VariableDeclarator', 'VariableDeclaration', 'ExportNamedDeclaration',
    'ExportDefaultDeclaration', 'AssignmentExpression', 'ExpressionStatement', 'ObjectProperty',
    'ClassProperty', 'ClassPrivateProperty', 'TSAsExpression', 'TSSatisfiesExpression',
    'TSNonNullExpression', 'TypeCastExpression', 'ParenthesizedExpression']);
  for (let index = ancestors.length - 1; index >= 0; index -= 1) {
    const parent = ancestors[index];
    if (!wrappers.has(parent.type)) break;
    if (hasDoc(parent)) return true;
  }
  return false;
}

/** Find the binding for an assigned arrow or function expression, excluding anonymous callbacks. */
function assignedName(node, ancestors, source) {
  const wrappers = new Set(['TSAsExpression', 'TSSatisfiesExpression', 'TSNonNullExpression',
    'TypeCastExpression', 'ParenthesizedExpression']);
  let index = ancestors.length - 1;
  while (wrappers.has(ancestors[index]?.type)) index -= 1;
  const parent = ancestors[index];
  if (parent?.type === 'VariableDeclarator' && parent.init) return keyName(parent.id, source);
  if (parent?.type === 'AssignmentExpression' && parent.right) return keyName(parent.left, source);
  if (['ObjectProperty', 'ClassProperty', 'ClassPrivateProperty'].includes(parent?.type) && parent.value) {
    return keyName(parent.key, source);
  }
  return node.id?.name ?? null;
}

/** Map decoded template characters to source lines, including escapes and line continuations. */
function templateSourceLines(raw, firstLine, cookedLength) {
  const lines = [];
  let index = 0;
  let line = firstLine;
  while (index < raw.length) {
    const char = raw[index];
    if (char === '\\') {
      const escaped = raw[index + 1];
      if (escaped === '\r' || escaped === '\n' || escaped === '\u2028' || escaped === '\u2029') {
        index += escaped === '\r' && raw[index + 2] === '\n' ? 3 : 2;
        line += 1;
        continue;
      }
      const unicode = raw.slice(index).match(/^\\u(?:\{([0-9a-f]+)\}|([0-9a-f]{4}))/i);
      const hex = raw.slice(index).match(/^\\x[0-9a-f]{2}/i);
      const units = unicode?.[1] && Number.parseInt(unicode[1], 16) > 0xffff ? 2 : 1;
      for (let unit = 0; unit < units; unit += 1) lines.push(line);
      index += unicode?.[0].length ?? hex?.[0].length ?? 2;
      continue;
    }
    lines.push(line);
    if (char === '\r' || char === '\n' || char === '\u2028' || char === '\u2029') {
      if (char === '\r' && raw[index + 1] === '\n') index += 1;
      line += 1;
    }
    index += 1;
  }
  if (lines.length !== cookedLength) throw new Error('Could not map decoded template to source lines');
  lines.push(line);
  return lines;
}

/** Traverse Babel nodes, also parsing static script tags in authored HTML template literals. */
function declarations(path, source, sourceLines = null, embedded = false) {
  const language = /\.[cm]?tsx?$/.test(path) ? 'TypeScript' : 'JavaScript';
  const ast = parse(source, { sourceType: 'unambiguous', plugins: language === 'TypeScript'
    ? ['typescript', 'jsx', 'decorators-legacy'] : ['jsx', 'decorators-legacy'],
  allowAwaitOutsideFunction: true, allowReturnOutsideFunction: true, attachComment: true });
  const found = [];
  const methods = new Set(['ObjectMethod', 'ClassMethod', 'ClassPrivateMethod', 'TSDeclareMethod', 'TSMethodSignature']);
  /** Walk only AST children so comments and location metadata cannot become declarations. */
  function visit(node, ancestors) {
    if (!node || typeof node !== 'object' || typeof node.type !== 'string') return;
    let name = null;
    if (node.type === 'FunctionDeclaration' || node.type === 'TSDeclareFunction') {
      name = node.id?.name ?? (ancestors.at(-1)?.type === 'ExportDefaultDeclaration' ? 'default' : null);
    } else if (methods.has(node.type)) {
      name = keyName(node.key, source);
    } else if (node.type === 'FunctionExpression' || node.type === 'ArrowFunctionExpression') {
      name = assignedName(node, ancestors, source);
    }
    if (name !== null) found.push({ path, line: sourceLines?.[node.start] ?? node.loc.start.line, name,
      kind: node.kind ?? node.type, language, documented: documented(node, ancestors),
      start_line: sourceLines?.[node.start] ?? Math.min(node.loc.start.line,
        ...(node.leadingComments ?? []).map(comment => comment.loc.start.line),
        ...ancestors.slice(-3).filter(parent => ['VariableDeclarator', 'VariableDeclaration',
          'ExportNamedDeclaration', 'ExportDefaultDeclaration', 'ExpressionStatement',
          'AssignmentExpression', 'ObjectProperty', 'ClassProperty'].includes(parent.type))
          .flatMap(parent => [parent.loc.start.line,
            ...(parent.leadingComments ?? []).map(comment => comment.loc.start.line)])),
      end_line: sourceLines?.[Math.max(node.start, node.end - 1)] ?? node.loc.end.line });
    if (!embedded && node.type === 'TemplateLiteral' && node.expressions.length === 0) {
      const quasi = node.quasis[0];
      const html = quasi.value.cooked;
      if (html === null && /<script\b/i.test(quasi.value.raw)) throw new Error('Static HTML template has invalid cooked escapes');
      if (html !== null && /<script\b/i.test(html)) {
        const lines = templateSourceLines(quasi.value.raw, quasi.loc.start.line, html.length);
        const fragment = parseFragment(html, { sourceCodeLocationInfo: true });
        for (const script of inlineScripts(fragment)) {
          const location = script.sourceCodeLocation;
          const bodyStart = location.startTag.endOffset;
          const bodyEnd = location.endTag?.startOffset ?? html.length;
          found.push(...declarations(path, html.slice(bodyStart, bodyEnd), lines.slice(bodyStart, bodyEnd + 1), true));
        }
      }
    }
    const next = [...ancestors, node];
    for (const [key, child] of Object.entries(node)) {
      if (['loc', 'start', 'end', 'leadingComments', 'trailingComments', 'innerComments', 'comments', 'tokens', 'errors'].includes(key)) continue;
      if (Array.isArray(child)) child.forEach(item => visit(item, next));
      else visit(child, next);
    }
  }
  visit(ast, []);
  return found;
}

try {
  const request = JSON.parse(readFileSync(0, 'utf8'));
  const found = request.paths.flatMap(path => {
    try { return declarations(path, readFileSync(resolve(request.root, path), 'utf8')); }
    catch (error) { throw new Error(`${path}: ${error.message}`); }
  });
  process.stdout.write(JSON.stringify(found));
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 2;
}
