#!/usr/bin/env node
// Runs TypeScript 7's compiler and conformance suites through `stator-ts check` and compares
// reported diagnostics with upstream's `.errors.txt` baselines. Fetch them with sync.sh first.
//
//   node tests/ts7/run.mjs [--filter <regex>] [--limit <n>] [--jobs <n>] [--verbose] [--keep] [--update-passing]
//
// `--keep` leaves each test's project on disk and prints where, to rerun one by hand.
//
// A test passes when the set of (file, line, column, code) is the same. Messages are not compared.
// Diagnostics with no source position and those in a tsconfig are about options; they are counted
// but do not decide a test, because stator-ts does not validate options.
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { availableParallelism, tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const project = path.resolve(here, '../..');
const upstream = path.join(here, 'upstream');
const testdata = path.join(upstream, 'tsc/testdata');
const libDir = path.join(upstream, 'tsc/internal/bundled/libs');
const suites = ['compiler', 'conformance'];
const passingFile = path.join(here, 'passing.txt');
const resultsDir = path.join(here, 'results');
const timeoutMs = 60_000;

const arg = name => {
    const i = process.argv.indexOf(name);
    return i < 0 ? undefined : process.argv[i + 1];
};
const flag = name => process.argv.includes(name);

const binary = process.env.STATOR_TS ?? path.join(project, 'zig-out/bin/stator-ts');
const jobs = Number(arg('--jobs') ?? availableParallelism());
const limit = Number(arg('--limit') ?? Infinity);
const filter = arg('--filter') ? new RegExp(arg('--filter')) : undefined;
const verbose = flag('--verbose');
const updatePassing = flag('--update-passing');
const keep = flag('--keep');

if (!existsSync(path.join(upstream, 'baselines.txt'))) {
    console.error('no upstream tests: run tests/ts7/sync.sh first');
    process.exit(2);
}

// Options stator-ts or the module resolver may read. Harness-only directives such as
// `traceResolution` change nothing about diagnostics here, so they are left out.
const optionNames = new Map([
    'allowArbitraryExtensions', 'allowImportingTsExtensions', 'allowJs', 'allowSyntheticDefaultImports', 'allowUmdGlobalAccess',
    'allowUnreachableCode', 'allowUnusedLabels', 'alwaysStrict', 'baseUrl', 'checkJs', 'customConditions', 'emitDecoratorMetadata',
    'esModuleInterop', 'exactOptionalPropertyTypes', 'experimentalDecorators', 'forceConsistentCasingInFileNames', 'ignoreDeprecations',
    'importHelpers', 'isolatedDeclarations', 'isolatedModules', 'jsx', 'jsxFactory', 'jsxFragmentFactory', 'jsxImportSource', 'lib',
    'libReplacement', 'module', 'moduleDetection', 'moduleResolution', 'noCheck', 'noFallthroughCasesInSwitch', 'noImplicitAny',
    'noImplicitOverride', 'noImplicitReturns', 'noImplicitThis', 'noLib', 'noPropertyAccessFromIndexSignature', 'noResolve',
    'noUncheckedIndexedAccess', 'noUncheckedSideEffectImports', 'noUnusedLocals', 'noUnusedParameters', 'outDir', 'paths', 'preserveConstEnums', 'preserveSymlinks',
    'reactNamespace', 'resolveJsonModule', 'resolvePackageJsonExports', 'resolvePackageJsonImports', 'rewriteRelativeImportExtensions',
    'rootDir', 'rootDirs', 'skipDefaultLibCheck', 'skipLibCheck', 'strict', 'strictBindCallApply', 'strictBuiltinIteratorReturn',
    'strictFunctionTypes', 'strictNullChecks', 'strictPropertyInitialization', 'target', 'typeRoots', 'types', 'useDefineForClassFields',
    'useUnknownInCatchVariables', 'verbatimModuleSyntax',
].map(name => [name.toLowerCase(), name]));
const listOptions = new Set(['customconditions', 'lib', 'rootdirs', 'typeroots', 'types']);
const pathOptions = new Set(['baseurl', 'rootdir', 'rootdirs', 'typeroots']);

function decode(buffer) {
    if (buffer[0] === 0xff && buffer[1] === 0xfe) return buffer.toString('utf16le', 2);
    if (buffer[0] === 0xfe && buffer[1] === 0xff) return Buffer.from(buffer.subarray(2)).swap16().toString('utf16le');
    return buffer.toString('utf8').replace(/^﻿/, '');
}

// Mirrors ParseTestFilesAndSymlinks in tsc/internal/testrunner/test_case_parser.go, including that
// directive lines vanish from the content: baseline positions are counted without them.
function parseUnits(code, name) {
    const option = /^\/{2}\s*@(\w+)\s*:\s*([^\r\n]*)/;
    const link = /^\/{2}\s*@link\s*:\s*([^\r\n]*)\s*->\s*([^\r\n]*)/;
    const units = [];
    const settings = new Map();
    const links = new Map();
    let content = '';
    let current = '';
    for (const line of code.split(/\r?\n/)) {
        const linked = link.exec(line);
        if (linked) {
            links.set(linked[2].trim(), linked[1].trim());
            continue;
        }
        const meta = option.exec(line);
        if (!meta) {
            if (content.length !== 0) content += '\n';
            content += line;
            continue;
        }
        const key = meta[1].toLowerCase();
        const value = meta[2].trim();
        if (key === 'symlink' && current) {
            for (const target of value.split(',')) if (target.trim()) links.set(target.trim(), current);
        } else if (key !== 'filename') {
            settings.set(key, value.replace(/;$/, ''));
        } else {
            if (current) units.push({ name: current, content });
            content = '';
            current = value;
        }
    }
    units.push({ name: current || name, content });
    return { units, settings, links };
}

function baselineVariants() {
    const variants = new Map();
    for (const entry of readFileSync(path.join(upstream, 'baselines.txt'), 'utf8').split('\n')) {
        const match = /^(\w+)\/(?:(.+?)\((.+)\)\.[^()]+|(.+?)(?:\.errors\.txt|\.sourcemap\.txt|\.js\.map|\.[a-z]+))$/.exec(entry);
        if (!match) continue;
        const key = `${match[1]}/${match[2] ?? match[4]}`;
        if (!variants.has(key)) variants.set(key, new Set());
        variants.get(key).add(match[3] ?? '');
    }
    return variants;
}

function* walk(dir) {
    for (const name of readdirSync(dir).sort()) {
        const full = path.join(dir, name);
        if (statSync(full).isDirectory()) yield* walk(full);
        else yield full;
    }
}

function collectTests() {
    const variants = baselineVariants();
    const tests = [];
    let skipped = 0;
    for (const suite of suites) {
        for (const file of walk(path.join(testdata, 'tests/cases', suite))) {
            const base = path.basename(file).replace(/\.[^.]+$/, '');
            const found = variants.get(`${suite}/${base}`);
            // Upstream skips what it cannot run, such as `module: umd`, and then leaves no baseline.
            if (!found) {
                skipped++;
                continue;
            }
            const group = suite === 'compiler' ? suite : `${suite}/${path.relative(path.join(testdata, 'tests/cases', suite), file).split(path.sep)[0]}`;
            for (const variant of found) {
                const id = `${suite}/${base}${variant ? `(${variant})` : ''}`;
                if (!filter || filter.test(id)) tests.push({ id, suite, file, variant, group });
            }
        }
    }
    return { tests: tests.slice(0, limit), skipped };
}

function optionValue(key, raw) {
    if (listOptions.has(key)) return raw.split(',').map(x => x.trim()).filter(Boolean);
    if (raw.toLowerCase() === 'true') return true;
    if (raw.toLowerCase() === 'false') return false;
    if (key === 'paths') {
        try {
            return JSON.parse(raw);
        } catch {
            return undefined;
        }
    }
    return raw.split(',')[0].trim();
}

function compilerOptions(settings, root, cwd) {
    const options = {};
    const rooted = value => (value.startsWith('/') ? path.join(root, value) : path.resolve(cwd, value));
    for (const [key, raw] of settings) {
        const name = optionNames.get(key);
        if (!name) continue;
        const value = optionValue(key, raw);
        if (value === undefined) continue;
        if (pathOptions.has(key)) options[name] = Array.isArray(value) ? value.map(rooted) : rooted(value);
        else options[name] = value;
    }
    return options;
}

function materialize(test, root) {
    const { units, settings, links } = parseUnits(decode(readFileSync(test.file)), path.basename(test.file));
    if (test.variant) {
        for (const pair of test.variant.split(',')) {
            const at = pair.indexOf('=');
            settings.set(pair.slice(0, at), pair.slice(at + 1));
        }
    }
    const cwd = path.join(root, settings.get('currentdirectory') ?? '/.src');
    const resolve = name => (name.startsWith('/') ? path.join(root, name) : path.join(cwd, name));
    mkdirSync(cwd, { recursive: true });
    symlinkSync(path.join(testdata, 'tests/lib'), path.join(root, '.lib'));

    const written = units.map(unit => ({ ...unit, full: resolve(unit.name) }));
    for (const unit of written) {
        mkdirSync(path.dirname(unit.full), { recursive: true });
        // The harness mounts test libraries at `/.lib`, outside any real root. Only a
        // reference comment names it, so the replacement cannot move a reported position.
        writeFileSync(unit.full, unit.content.replaceAll('"/.lib/', `"${root}/.lib/`));
    }
    for (const [from, to] of links) {
        const at = resolve(from);
        mkdirSync(path.dirname(at), { recursive: true });
        if (!existsSync(at)) symlinkSync(resolve(to), at);
    }

    const options = compilerOptions(settings, root, cwd);
    // TypeScript 7's defaults, which every baseline assumes.
    options.strict ??= true;
    options.target ??= 'es2025';
    options.skipDefaultLibCheck ??= true;

    const config = written.find(unit => /^[tj]sconfig\.json$/i.test(path.basename(unit.name)));
    if (config) {
        const dir = path.dirname(config.full);
        writeFileSync(path.join(dir, 'tsconfig.stator.json'), JSON.stringify({ extends: `./${path.basename(config.full)}`, compilerOptions: options }));
        return { cwd, project: path.join(dir, 'tsconfig.stator.json') };
    }
    // Same choice of roots as newCompilerTest in compiler_runner.go.
    const last = written.at(-1);
    const onlyLast = settings.has('noimplicitreferences') || last.content.includes('require(') || /reference\spath/.test(last.content);
    const roots = (onlyLast ? [last] : written).filter(unit => !/\.(json|tsbuildinfo)$/.test(unit.name));
    const projectFile = path.join(cwd, 'tsconfig.stator.json');
    writeFileSync(projectFile, JSON.stringify({ compilerOptions: options, files: roots.map(unit => unit.full) }));
    return { cwd, project: projectFile };
}

const located = /^(.+?)\((\d+),(\d+)\): error TS(\d+):/;

function expectedDiagnostics(test, cwdVirtual) {
    const file = path.join(testdata, 'baselines/reference', `${test.id}.errors.txt`);
    const expected = new Set();
    let options = 0;
    if (!existsSync(file)) return { expected, options };
    for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) {
        if (line.startsWith('==== ')) break;
        if (/^error TS\d+:/.test(line)) options++;
        const match = located.exec(line);
        if (!match) continue;
        if (/[tj]sconfig[^/]*\.json$/.test(match[1])) {
            options++;
            continue;
        }
        expected.add(`${path.resolve(cwdVirtual, match[1])}(${match[2]},${match[3]}) TS${match[4]}`);
    }
    return { expected, options };
}

function actualDiagnostics(output, root, cwd) {
    const actual = new Set();
    for (const line of output.split('\n')) {
        const match = located.exec(line);
        if (!match || /[tj]sconfig[^/]*\.json$/.test(match[1])) continue;
        const full = path.resolve(cwd, match[1]);
        const virtual = full.startsWith(root + path.sep) ? full.slice(root.length) : full;
        actual.add(`${virtual}(${match[2]},${match[3]}) TS${match[4]}`);
    }
    return actual;
}

function check(project_, cwd) {
    return new Promise(done => {
        const child = spawn(binary, ['check', '--all-diagnostics', '-p', project_, '-j', '1'], {
            cwd,
            env: { ...process.env, STATOR_TS_LIB: libDir },
            stdio: ['ignore', 'pipe', 'pipe'],
        });
        let output = '';
        child.stdout.on('data', chunk => (output += chunk));
        child.stderr.on('data', chunk => (output += chunk));
        const timer = setTimeout(() => child.kill('SIGKILL'), timeoutMs);
        child.on('close', (code, signal) => {
            clearTimeout(timer);
            done({ code, signal, output });
        });
    });
}

async function runTest(test, base) {
    const root = mkdtempSync(path.join(base, 't'));
    try {
        let setup;
        try {
            setup = materialize(test, root);
        } catch (error) {
            return { id: test.id, group: test.group, status: 'unrunnable', detail: String(error.message) };
        }
        const started = Date.now();
        const { code, signal, output } = await check(setup.project, setup.cwd);
        const ms = Date.now() - started;
        if (signal === 'SIGKILL') return { id: test.id, group: test.group, status: 'timeout', ms };
        // 0 and 1 are the two normal outcomes; anything else means stator-ts itself failed.
        if (signal || code > 2) {
            return { id: test.id, group: test.group, status: 'crash', ms, detail: output.split('\n').find(l => /^thread \d+ panic|^panic|Segmentation fault/.test(l)) ?? `exit ${code ?? signal}` };
        }
        const { expected, options } = expectedDiagnostics(test, path.relative(root, setup.cwd) ? `/${path.relative(root, setup.cwd)}` : '/');
        const actual = actualDiagnostics(output, root, setup.cwd);
        const miss = [...expected].filter(x => !actual.has(x));
        const extra = [...actual].filter(x => !expected.has(x));
        return { id: test.id, group: test.group, status: miss.length || extra.length ? 'fail' : 'pass', ms, miss, extra, options };
    } finally {
        if (keep) console.log(`${test.id}: ${root}`);
        else rmSync(root, { recursive: true, force: true });
    }
}

const codeOf = entry => /TS\d+$/.exec(entry)[0];

function top(counter, n) {
    return [...counter].sort((a, b) => b[1] - a[1]).slice(0, n).map(([k, v]) => `${k} ${v}`).join(', ');
}

function report(results, skipped, seconds) {
    const count = status => results.filter(r => r.status === status).length;
    const groups = new Map();
    const missCodes = new Map();
    const extraCodes = new Map();
    let missTotal = 0;
    let extraTotal = 0;
    let options = 0;
    for (const r of results) {
        const g = groups.get(r.group) ?? { total: 0, pass: 0 };
        g.total++;
        if (r.status === 'pass') g.pass++;
        groups.set(r.group, g);
        options += r.options ?? 0;
        for (const x of r.miss ?? []) {
            missTotal++;
            missCodes.set(codeOf(x), (missCodes.get(codeOf(x)) ?? 0) + 1);
        }
        for (const x of r.extra ?? []) {
            extraTotal++;
            extraCodes.set(codeOf(x), (extraCodes.get(codeOf(x)) ?? 0) + 1);
        }
    }
    const lines = [
        `tests ${results.length}  pass ${count('pass')}  fail ${count('fail')}  crash ${count('crash')}  timeout ${count('timeout')}  unrunnable ${count('unrunnable')}  skipped by upstream ${skipped}`,
        `pass rate ${((100 * count('pass')) / Math.max(results.length, 1)).toFixed(1)}%  in ${seconds.toFixed(1)} s`,
        `diagnostics missed ${missTotal}  extra ${extraTotal}  option diagnostics not compared ${options}`,
        `top missed: ${top(missCodes, 12)}`,
        `top extra:  ${top(extraCodes, 12)}`,
        '',
        ...[...groups].sort((a, b) => b[1].total - a[1].total).map(([name, g]) => `${name.padEnd(36)} ${String(g.pass).padStart(6)} / ${String(g.total).padStart(6)}  ${((100 * g.pass) / g.total).toFixed(1)}%`),
    ];
    return lines.join('\n');
}

async function main() {
    const { tests, skipped } = collectTests();
    const base = mkdtempSync(path.join(tmpdir(), 'stator-ts-ts7-'));
    const results = new Array(tests.length);
    const started = Date.now();
    let next = 0;
    let finished = 0;
    await Promise.all(Array.from({ length: jobs }, async () => {
        while (next < tests.length) {
            const at = next++;
            results[at] = await runTest(tests[at], base);
            finished++;
            if (finished % 1000 === 0) console.error(`${finished} / ${tests.length}`);
        }
    }));
    if (!keep) rmSync(base, { recursive: true, force: true });

    mkdirSync(resultsDir, { recursive: true });
    writeFileSync(path.join(resultsDir, 'latest.json'), JSON.stringify(results.map(({ group, ...r }) => r), null, 1));
    const summary = report(results, skipped, (Date.now() - started) / 1000);
    writeFileSync(path.join(resultsDir, 'latest.txt'), summary + '\n');
    console.log(summary);

    if (verbose) {
        for (const r of results) {
            if (r.status === 'pass') continue;
            console.log(`\n${r.status} ${r.id}${r.detail ? `: ${r.detail}` : ''}`);
            for (const x of r.miss ?? []) console.log(`  missed ${x}`);
            for (const x of r.extra ?? []) console.log(`  extra  ${x}`);
        }
    }

    const passing = results.filter(r => r.status === 'pass').map(r => r.id).sort();
    // A filtered run sees only part of the suite, so it can neither set nor judge the whole ratchet.
    const whole = !filter && limit === Infinity;
    if (updatePassing) {
        if (!whole) {
            console.error('--update-passing needs a full run');
            process.exit(2);
        }
        writeFileSync(passingFile, passing.join('\n') + '\n');
        return;
    }
    if (!existsSync(passingFile)) return;
    const known = readFileSync(passingFile, 'utf8').split('\n').filter(Boolean);
    const ran = new Set(results.map(r => r.id));
    const now = new Set(passing);
    const lost = known.filter(id => ran.has(id) && !now.has(id));
    const gained = passing.filter(id => !known.includes(id)).length;
    console.log(`\nratchet: ${known.length} known passing, ${lost.length} lost, ${gained} gained`);
    if (lost.length > 0) {
        for (const id of lost.slice(0, 50)) console.log(`  lost ${id}`);
        process.exitCode = 1;
    }
}

await main();
