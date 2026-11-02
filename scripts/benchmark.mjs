// node scripts/benchmark.mjs BEFORE AFTER -- check -p PROJECT --lib-dir LIBS -j 16
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { parseArgs } from 'node:util';
import path from 'node:path';

const separator = process.argv.indexOf('--', 2);
if (separator < 0 || process.platform !== 'darwin') {
    throw new Error('Usage on macOS: node scripts/benchmark.mjs BEFORE AFTER [--rounds 30] -- check [options]');
}
const { values, positionals } = parseArgs({
    args: process.argv.slice(2, separator),
    allowPositionals: true,
    options: { rounds: { type: 'string', default: '30' } },
});
const rounds = Number(values.rounds);
if (positionals.length !== 2 || !Number.isSafeInteger(rounds) || rounds < 1) {
    throw new Error('Supply two binaries and a positive integer number of rounds');
}
const binaries = positionals.map(binary => path.resolve(binary));
const args = process.argv.slice(separator + 1);
const warmups = 3;
const samples = [[], []];
let expected;
for (let round = -warmups; round < rounds; round++) {
    for (const variant of (round % 2 === 0 ? [0, 1] : [1, 0])) {
        const start = performance.now();
        const run = spawnSync('/usr/bin/time', ['-l', binaries[variant], ...args], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
        const wallMs = performance.now() - start;
        if (run.error || ![0, 2].includes(run.status)) {
            throw new Error(`${binaries[variant]}: ${run.error ?? run.signal ?? run.status}\n${run.stderr}`);
        }
        const timing = run.stderr.match(/([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys/);
        if (!timing) throw new Error('No timing data from /usr/bin/time');
        const verdict = { status: run.status, stdoutSha256: createHash('sha256').update(run.stdout).digest('hex') };
        expected ??= verdict;
        if (JSON.stringify(verdict) !== JSON.stringify(expected)) throw new Error('Diagnostics or exit status changed between runs');
        const counter = name => {
            const match = run.stderr.match(new RegExp(`(\\d+)\\s+${name}`));
            if (!match) throw new Error(`Missing counter: ${name}`);
            return Number(match[1]);
        };
        if (round >= 0) samples[variant].push({
            wallMs,
            cpuMs: (Number(timing[2]) + Number(timing[3])) * 1000,
            rssBytes: counter('maximum resident set size'),
            footprintBytes: counter('peak memory footprint'),
            instructions: counter('instructions retired'),
        });
    }
}
const median = numbers => {
    const sorted = numbers.toSorted((a, b) => a - b);
    const middle = Math.floor(sorted.length / 2);
    return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
};
const medians = samples.map(rows => Object.fromEntries(Object.keys(rows[0]).map(key => [key, median(rows.map(row => row[key]))])));
const reductionPercent = Object.fromEntries(Object.keys(medians[0]).map(key => [key, medians[0][key] === 0 ? null : 100 * (1 - medians[1][key] / medians[0][key])]));
console.log(JSON.stringify({ binaries, args, rounds, warmups, expected, medians, reductionPercent, samples }, null, 2));
