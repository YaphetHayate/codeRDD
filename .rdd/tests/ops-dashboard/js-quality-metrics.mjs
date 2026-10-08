// QA quality probe (n8): function length / nesting depth / import cycles for the
// delivered dashboard sources. Quantitative rules come from docs/code-quality.md §1/§4.
// Usage: node .rdd/tmp/qa-n8-js-metrics.mjs <file-or-dir> [<file-or-dir> ...]
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative, resolve } from 'node:path'
import ts from 'typescript'

const MAX_LINES = 50
const MAX_DEPTH = 5
const NESTING = new Set([
  'IfStatement',
  'ForStatement',
  'ForInStatement',
  'ForOfStatement',
  'WhileStatement',
  'DoStatement',
])
const FUNCTION_KINDS = new Set([
  'FunctionDeclaration',
  'FunctionExpression',
  'ArrowFunction',
  'MethodDeclaration',
  'Constructor',
  'GetAccessor',
  'SetAccessor',
])

function collect(target, out = []) {
  const stats = statSync(target)
  if (stats.isDirectory()) {
    for (const entry of readdirSync(target)) collect(join(target, entry), out)
    return out
  }
  if (/\.(mjs|js)$/.test(target)) out.push(target)
  return out
}

function effectiveLines(source, node) {
  // Caliber mirrored from code-metrics.ps1 Get-CodeLineMap: lines inside the
  // function BODY extent that carry at least one non-comment token, i.e. lines
  // belonging to any non-comment token (blank and comment-only lines subtracted).
  const body = node.body ?? node
  const text = source.slice(body.getStart(), body.getEnd())
  return text
    .split(/\r?\n/)
    .filter((line) => {
      const trimmed = line.trim()
      return trimmed !== '' && !trimmed.startsWith('//') && !trimmed.startsWith('/*') && !trimmed.startsWith('*') && !trimmed.endsWith('*/')
    }).length
}

function maxNesting(sourceFile, body) {
  let depth = 0
  let max = 0
  const visit = (node) => {
    if (ts.isFunctionLike(node) && node !== body) return // separate function = separate budget
    if (NESTING.has(ts.SyntaxKind[node.kind])) {
      depth += 1
      max = Math.max(max, depth)
    }
    ts.forEachChild(node, visit)
    if (NESTING.has(ts.SyntaxKind[node.kind])) depth -= 1
  }
  if (body !== undefined) ts.forEachChild(body, visit)
  return max
}

function nameOf(node) {
  if (node.name !== undefined && ts.isIdentifier(node.name)) return node.name.text
  if (ts.isPropertyAssignment(node.parent) || ts.isVariableDeclaration(node.parent)) {
    const target = node.parent.name
    if (target !== undefined && ts.isIdentifier(target)) return target.text
  }
  return '<anonymous>'
}

const files = []
for (const arg of process.argv.slice(2)) collect(resolve(arg), files)

const violations = []
const calls = []
const importsOf = new Map()

for (const file of files) {
  const source = readFileSync(file, 'utf8')
  const sourceFile = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS)
  const deps = new Set()
  for (const statement of sourceFile.statements) {
    if (ts.isImportDeclaration(statement) && ts.isStringLiteral(statement.moduleSpecifier)) {
      const spec = statement.moduleSpecifier.text
      if (spec.startsWith('.')) deps.add(resolve(file, '..', spec))
    }
  }
  importsOf.set(file, [...deps])

  const walk = (node) => {
    if (FUNCTION_KINDS.has(ts.SyntaxKind[node.kind])) {
      const lines = effectiveLines(source, node)
      const depth = maxNesting(sourceFile, node.body ?? node)
      const where = sourceFile.getLineAndCharacterOfPosition(node.getStart())
      const record = { file, name: nameOf(node), line: where.line + 1, lines, depth }
      calls.push(record)
      if (lines > MAX_LINES) violations.push(`${record.file}:${record.line} ${record.name} — ${lines} lines > ${MAX_LINES}`)
      if (depth > MAX_DEPTH) violations.push(`${record.file}:${record.line} ${record.name} — nesting ${depth} > ${MAX_DEPTH}`)
    }
    ts.forEachChild(node, walk)
  }
  ts.forEachChild(sourceFile, walk)
}

// Import-cycle detection over the delivered modules only.
const inSet = new Set(importsOf.keys())
const cycles = []
const state = new Map()
function probe(node, stack) {
  if (state.get(node) === 'done') return
  if (state.get(node) === 'open') {
    cycles.push([...stack.slice(stack.indexOf(node)), node].map((entry) => relative(process.cwd(), entry)).join(' -> '))
    return
  }
  state.set(node, 'open')
  for (const dep of importsOf.get(node) ?? []) {
    for (const candidate of [`${dep}.mjs`, `${dep}.js`, join(dep, 'index.mjs')]) {
      if (inSet.has(candidate)) probe(candidate, [...stack, node])
    }
  }
  state.set(node, 'done')
}
for (const node of inSet) probe(node, [])

const worst = [...calls].sort((a, b) => b.lines - a.lines).slice(0, 8)
console.log(`scanned files: ${files.length}  functions: ${calls.length}`)
console.log(`thresholds: function<=${MAX_LINES} lines (comments excluded), nesting<=${MAX_DEPTH}`)
console.log('longest functions:')
for (const entry of worst) {
  console.log(`  ${entry.lines.toString().padStart(3)} lines  depth ${entry.depth}  ${relative(process.cwd(), entry.file)}:${entry.line} ${entry.name}`)
}
const deepest = [...calls].sort((a, b) => b.depth - a.depth).slice(0, 3)
console.log(`deepest nesting: ${deepest.map((entry) => `${entry.name}=${entry.depth}`).join(', ')}`)
console.log(`import cycles: ${cycles.length}`)
for (const cycle of cycles) console.log(`  ${cycle}`)
console.log(`violations: ${violations.length}`)
for (const violation of violations) console.log(`  ${violation}`)
process.exit(violations.length === 0 ? 0 : 1)
