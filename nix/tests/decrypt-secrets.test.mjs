import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(
	new URL("../decrypt-secrets.mjs", import.meta.url),
);

function fixture(t) {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ageism-generation-test-"));
	t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
	const root = path.join(dir, "generations");
	const dest = path.join(dir, "destinations");
	const last = path.join(dir, "state", "last.json");
	const log = path.join(dir, "age.log");
	const manifest = path.join(dir, "manifest.json");
	const preload = path.join(dir, "preload.mjs");
	const age = path.join(dir, "age");
	fs.mkdirSync(dest);
	fs.writeFileSync(path.join(dir, "identity.12345678"), "test identity");

	// The production checks require every ancestor to have the caller's UID
	// and prohibit /tmp. Mock ONLY the ancestors outside this fixture so these
	// tests also run unprivileged and in Nix's build sandbox. All checks inside
	// the fixture (including writable-directory rejection) remain real.
	const ancestors = [];
	for (let ancestor = path.dirname(dir); ; ancestor = path.dirname(ancestor)) {
		ancestors.push(ancestor);
		if (ancestor === path.dirname(ancestor)) break;
	}
	fs.writeFileSync(
		preload,
		`
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
const ancestors = new Set(${JSON.stringify(ancestors)});
const lstat = fs.lstatSync;
fs.lstatSync = (file, ...rest) => {
  const st = lstat(file, ...rest);
  if (ancestors.has(path.resolve(file)) && st.isDirectory()) {
    st.uid = process.getuid(); st.mode &= ~0o022;
  }
  return st;
};
const rename = fs.renameSync;
fs.renameSync = (from, to) => {
  if (process.env.AGEISM_KILL_BEFORE_ALIAS && path.basename(from) === 'next')
    process.kill(process.pid, 'SIGKILL');
  if (to === process.env.AGEISM_CURRENT) {
    const expected = JSON.parse(process.env.AGEISM_EXPECT || '{}');
    for (const [file, value] of Object.entries(expected)) {
      assert.equal(fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null, value);
    }
    if (process.env.AGEISM_FAIL_PUBLISH) throw new Error('simulated publish failure');
  }
  return rename(from, to);
};
`,
	);
	fs.writeFileSync(
		age,
		`#!${process.execPath}
const assert = require('node:assert/strict');
const fs = require('node:fs');
const args = process.argv.slice(2);
for (const [file, value] of Object.entries(JSON.parse(process.env.AGEISM_EXPECT || '{}'))) {
  assert.equal(fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null, value);
}
assert.ok(fs.existsSync(args[args.indexOf('-i') + 1]), 'identity must exist');
const source = args.at(-1);
fs.appendFileSync(process.env.AGEISM_LOG, source + '\\n');
const data = fs.readFileSync(source);
fs.writeFileSync(args[args.indexOf('-o') + 1], data);
if (data.toString() === 'FAIL') { console.error('simulated decryption failure'); process.exit(1); }
if (data.toString() === 'KILL') { process.kill(process.ppid, 'SIGKILL'); process.exit(0); }
`,
		{ mode: 0o700 },
	);

	function entry(name, content, options = {}) {
		const sum = createHash("sha256").update(content).digest("hex");
		const source = path.join(dir, `sha256-${sum}.12345678.age`);
		fs.writeFileSync(source, content);
		return {
			source,
			path: path.join(dest, name),
			owner: String(process.getuid()),
			mode: "0400",
			...options,
		};
	}
	function run(entries, options = {}) {
		fs.writeFileSync(manifest, JSON.stringify(entries));
		const selectedRoot = options.root || root;
		const result = spawnSync(
			process.execPath,
			[
				"--import",
				preload,
				script,
				manifest,
				"--generation-dir",
				selectedRoot,
				...(options.cache === false
					? []
					: ["--last-manifest", options.last || last]),
				...(options.prune === false ? [] : ["--prune", dest]),
			],
			{
				encoding: "utf8",
				env: {
					...process.env,
					AGE_BIN: age,
					AGEISM_LOG: log,
					AGEISM_CURRENT: path.join(selectedRoot, "current"),
					AGEISM_EXPECT: JSON.stringify(options.expect || {}),
					...(options.env || {}),
				},
			},
		);
		if (options.fail) assert.notEqual(result.status, 0, result.stdout);
		else assert.equal(result.status, 0, result.stderr);
		return result;
	}
	const current = (selectedRoot = root) =>
		fs.readlinkSync(path.join(selectedRoot, "current"));
	const read = (entry) => fs.readFileSync(entry.path, "utf8");
	const calls = () =>
		fs.existsSync(log)
			? fs.readFileSync(log, "utf8").trim().split("\n").length
			: 0;
	const generations = () =>
		fs.readdirSync(root).filter((name) => name.startsWith("generation-"));
	return {
		dir,
		root,
		dest,
		last,
		entry,
		run,
		current,
		read,
		calls,
		generations,
	};
}

test("first provisioning exposes all secrets and metadata at a single switch", (t) => {
	const f = fixture(t);
	const entries = {
		a: f.entry("a", "first"),
		b: f.entry("nested/b", "second"),
	};
	f.run(entries, {
		expect: { [entries.a.path]: null, [entries.b.path]: null },
	});
	assert.equal(f.read(entries.a), "first");
	assert.equal(f.read(entries.b), "second");
	assert.ok(fs.lstatSync(entries.a.path).isSymbolicLink());
	assert.ok(fs.lstatSync(f.last).isSymbolicLink());
	assert.deepEqual(JSON.parse(fs.readFileSync(f.last)), entries);
	assert.equal(fs.statSync(entries.a.path).mode & 0o777, 0o400);
	assert.equal(
		fs.statSync(path.join(f.root, f.current(), "manifest.json")).mode & 0o777,
		0o600,
	);
});

test("replacement keeps the entire old generation visible until publication", (t) => {
	const f = fixture(t);
	const old = { a: f.entry("a", "old-a"), b: f.entry("nested/b", "old-b") };
	f.run(old);
	const previous = f.current();
	const updated = { a: f.entry("a", "new-a"), b: f.entry("nested/b", "new-b") };
	f.run(updated, { expect: { [old.a.path]: "old-a", [old.b.path]: "old-b" } });
	assert.notEqual(f.current(), previous);
	assert.equal(f.read(old.a), "new-a");
	assert.equal(f.read(old.b), "new-b");
	assert.deepEqual(JSON.parse(fs.readFileSync(f.last)), updated);
});

test("partial decryption failure preserves nested secrets and cache; rollback is safe", (t) => {
	const f = fixture(t);
	const old = { a: f.entry("a", "old-a"), b: f.entry("nested/b", "old-b") };
	f.run(old);
	const previous = f.current();
	const updated = { a: f.entry("a", "new-a"), b: f.entry("nested/b", "FAIL") };
	f.run(updated, {
		fail: true,
		expect: { [old.a.path]: "old-a", [old.b.path]: "old-b" },
	});
	assert.equal(f.current(), previous);
	assert.equal(f.read(old.a), "old-a");
	assert.equal(f.read(old.b), "old-b");
	assert.deepEqual(JSON.parse(fs.readFileSync(f.last)), old);
	assert.deepEqual(f.generations(), [previous]);
	const calls = f.calls();
	f.run(old);
	assert.equal(
		f.calls(),
		calls,
		"unchanged secrets are copied from the committed generation",
	);
	assert.equal(f.read(old.a), "old-a");
});

test("first-run decryption failure publishes nothing and removes plaintext staging", (t) => {
	const f = fixture(t);
	const entries = { a: f.entry("a", "secret"), b: f.entry("b", "FAIL") };
	f.run(entries, { fail: true });
	assert.equal(fs.existsSync(entries.a.path), false);
	assert.equal(fs.existsSync(f.last), false);
	assert.deepEqual(f.generations(), []);
});

test("a killed worker preserves the old generation and releases its advisory lock", (t) => {
	const f = fixture(t);
	const a = f.entry("a", "old");
	f.run({ a });
	const previous = f.current();
	f.run({ a: f.entry("a", "KILL") }, { fail: true });
	assert.equal(f.current(), previous);
	assert.equal(f.read(a), "old");
	assert.deepEqual(JSON.parse(fs.readFileSync(f.last)), { a });
	f.run({ a });
	assert.equal(f.read(a), "old");
	assert.equal(
		f.generations().length,
		2,
		"orphaned staging generation was collected",
	);
});

test("chmod/chown failure also preserves the current generation", (t) => {
	const f = fixture(t);
	const original = { a: f.entry("a", "old") };
	f.run(original);
	const previous = f.current();
	f.run(
		{
			a: f.entry("a", "new", { owner: "ageism-test-nonexistent-user-999999" }),
		},
		{ fail: true },
	);
	assert.equal(f.current(), previous);
	assert.equal(f.read(original.a), "old");
});

test("legacy regular files are imported without changing their contents before commit", (t) => {
	const f = fixture(t);
	const entries = { a: f.entry("a", "new-a"), b: f.entry("b", "new-b") };
	for (const [name, entry] of Object.entries(entries))
		fs.writeFileSync(entry.path, `legacy-${name}`, { mode: 0o600 });
	f.run(entries, {
		expect: { [entries.a.path]: "legacy-a", [entries.b.path]: "legacy-b" },
	});
	assert.equal(f.read(entries.a), "new-a");
	assert.equal(f.read(entries.b), "new-b");
	assert.ok(fs.lstatSync(entries.a.path).isSymbolicLink());
});

test("a killed legacy migration can be retried without stale seeds blocking it", (t) => {
	const f = fixture(t);
	const a = f.entry("a", "old-a");
	f.run({ a });
	const previous = f.current();
	const b = f.entry("b", "new-b");
	fs.writeFileSync(b.path, "legacy-b", { mode: 0o600 });
	f.run({ a, b }, { fail: true, env: { AGEISM_KILL_BEFORE_ALIAS: "1" } });
	assert.equal(f.current(), previous);
	assert.equal(f.read(a), "old-a");
	assert.equal(f.read(b), "legacy-b");
	f.run({ a, b }, { expect: { [a.path]: "old-a", [b.path]: "legacy-b" } });
	assert.equal(f.read(b), "new-b");
});

test("legacy cache metadata is unchanged until the generation switch", (t) => {
	const f = fixture(t);
	const a = f.entry("a", "new");
	fs.writeFileSync(a.path, "legacy", { mode: 0o600 });
	fs.mkdirSync(path.dirname(f.last));
	fs.writeFileSync(f.last, '{"legacy":true}', { mode: 0o600 });
	f.run({ a }, { expect: { [a.path]: "legacy", [f.last]: '{"legacy":true}' } });
	assert.deepEqual(JSON.parse(fs.readFileSync(f.last)), { a });
});

test("legacy symlink targets are not overwritten during migration", (t) => {
	const f = fixture(t);
	const original = path.join(f.dir, "original");
	fs.writeFileSync(original, "original", { mode: 0o600 });
	const entry = f.entry("a", "new");
	fs.symlinkSync(original, entry.path);
	f.run({ a: entry }, { expect: { [entry.path]: "original" } });
	assert.equal(f.read(entry), "new");
	assert.equal(fs.readFileSync(original, "utf8"), "original");
});

test("alias setup failure restores legacy files and removes unpublished generations", (t) => {
	const f = fixture(t);
	const a = f.entry("a", "new");
	fs.writeFileSync(a.path, "legacy", { mode: 0o640 });
	fs.mkdirSync(f.last, { recursive: true }); // Cannot replace a directory with a symlink.
	f.run({ a }, { fail: true });
	assert.ok(fs.lstatSync(a.path).isFile());
	assert.equal(f.read(a), "legacy");
	assert.equal(fs.statSync(a.path).mode & 0o777, 0o640);
	assert.equal(fs.existsSync(path.join(f.root, "current")), false);
	assert.deepEqual(f.generations(), []);
});

test("failure of the publication rename rolls back aliases and keeps committed state", (t) => {
	const f = fixture(t);
	const a = f.entry("a", "old-a");
	f.run({ a });
	const previous = f.current();
	const added = f.entry("b", "new-b");
	f.run(
		{ a: f.entry("a", "new-a"), b: added },
		{
			fail: true,
			env: { AGEISM_FAIL_PUBLISH: "1" },
			expect: { [a.path]: "old-a", [added.path]: null },
		},
	);
	assert.equal(f.current(), previous);
	assert.equal(f.read(a), "old-a");
	assert.equal(fs.existsSync(added.path), false);
	assert.equal(fs.lstatSync(f.last).isSymbolicLink(), true);
	assert.deepEqual(JSON.parse(fs.readFileSync(f.last)), { a });
	assert.deepEqual(f.generations(), [previous]);
});

test("a failed legacy baseline publication cleans up and allows retry", (t) => {
	const f = fixture(t);
	const a = f.entry("a", "new");
	fs.writeFileSync(a.path, "legacy");
	f.run({ a }, { fail: true, env: { AGEISM_FAIL_PUBLISH: "1" } });
	assert.equal(f.read(a), "legacy");
	assert.deepEqual(f.generations(), []);
	f.run({ a });
	assert.equal(f.read(a), "new");
});

test("cached files are copied, not hard-linked, and requested modes are reapplied", (t) => {
	const f = fixture(t);
	const a = f.entry("a", Buffer.from([0, 1, 255, 10]), { mode: "0640" });
	f.run({ a });
	const oldFile = fs.realpathSync(a.path);
	const calls = f.calls();
	f.run({ a });
	assert.equal(f.calls(), calls);
	assert.deepEqual(fs.readFileSync(a.path), Buffer.from([0, 1, 255, 10]));
	assert.notEqual(fs.statSync(oldFile).ino, fs.statSync(a.path).ino);
	assert.equal(fs.statSync(a.path).mode & 0o777, 0o640);
});

test("missing cached files are decrypted again", (t) => {
	const f = fixture(t);
	const a = f.entry("a", "secret");
	f.run({ a });
	fs.unlinkSync(fs.realpathSync(a.path));
	f.run({ a });
	assert.equal(f.calls(), 2);
	assert.equal(f.read(a), "secret");
});

test("without caching each generation is decrypted afresh", (t) => {
	const f = fixture(t);
	const a = f.entry("a", "secret");
	f.run({ a }, { cache: false });
	f.run({ a }, { cache: false });
	assert.equal(f.calls(), 2);
	assert.equal(fs.existsSync(f.last), false);
});

test("pruning retains current and previous generations, not arbitrary directories", (t) => {
	const f = fixture(t);
	const unrelated = path.join(f.dest, "unrelated");
	fs.mkdirSync(unrelated);
	fs.writeFileSync(path.join(unrelated, "keep"), "keep");
	f.run({ a: f.entry("nested/a", "one") });
	const first = f.current();
	f.run({ a: f.entry("nested/a", "two") });
	const second = f.current();
	f.run({ a: f.entry("nested/a", "three") });
	assert.deepEqual(new Set(f.generations()), new Set([second, f.current()]));
	assert.equal(fs.existsSync(path.join(f.root, first)), false);
	assert.equal(fs.readFileSync(path.join(unrelated, "keep"), "utf8"), "keep");
});

test("an empty generation removes obsolete managed aliases after commit", (t) => {
	const f = fixture(t);
	const a = f.entry("nested/a", "secret");
	f.run({ a });
	f.run({}, { expect: { [a.path]: "secret" } });
	assert.equal(fs.existsSync(a.path), false);
	assert.equal(fs.existsSync(path.dirname(a.path)), true);
	assert.deepEqual(JSON.parse(fs.readFileSync(f.last)), {});
});

test("early and regular phases have independent pointers and pruning", (t) => {
	const f = fixture(t);
	const earlyRoot = `${f.root}.for-users`;
	const earlyLast = `${f.last}.for-users`;
	const password = f.entry("password", "password");
	f.run({ password }, { root: earlyRoot, last: earlyLast });
	const early = f.current(earlyRoot);
	const a = f.entry("a", "regular");
	f.run({ a });
	f.run({ a: f.entry("a", "new-regular") });
	assert.equal(f.current(earlyRoot), early);
	assert.equal(f.read(password), "password");
	f.run({ a: f.entry("a", "FAIL") }, { fail: true });
	assert.equal(f.read(password), "password");
	assert.equal(f.read(a), "new-regular");
});

test("a secret can migrate between provisioning phases", (t) => {
	const f = fixture(t);
	const a = f.entry("a", "old");
	f.run({ a }, { root: `${f.root}.for-users`, last: `${f.last}.for-users` });
	f.run({ a: f.entry("a", "new") }, { expect: { [a.path]: "old" } });
	assert.equal(f.read(a), "new");
});

test("writable destination directories are rejected before publication", (t) => {
	const f = fixture(t);
	fs.chmodSync(f.dest, 0o777);
	const a = f.entry("a", "secret");
	const result = f.run({ a }, { fail: true });
	assert.match(result.stderr, /writable by group or others/);
	assert.equal(fs.existsSync(a.path), false);
});

test("duplicate canonical destinations and storage overlap are rejected", (t) => {
	const f = fixture(t);
	const a = f.entry("a", "secret");
	const alias = path.join(f.dir, "alias");
	fs.symlinkSync(f.dest, alias);
	assert.match(
		f.run({ a, b: { ...a, path: path.join(alias, "a") } }, { fail: true })
			.stderr,
		/duplicate destination/,
	);
	assert.match(
		f.run({ a: { ...a, path: path.join(f.root, "secret") } }, { fail: true })
			.stderr,
		/overlaps generation/,
	);
	assert.match(
		f.run({ a: { ...a, mode: "888" } }, { fail: true }).stderr,
		/invalid manifest entry/,
	);
	assert.equal(f.calls(), 0);
});

test("a held lock fails closed without changing the active generation", async (t) => {
	const f = fixture(t);
	const a = f.entry("a", "old");
	f.run({ a });
	const previous = f.current();
	const holder = spawn("flock", [
		path.join(f.root, "lock"),
		process.execPath,
		"-e",
		"process.stdout.write('locked'); process.stdin.resume()",
	]);
	t.after(() => holder.stdin.end());
	await once(holder.stdout, "data");
	assert.match(
		f.run({ a: f.entry("a", "new") }, { fail: true }).stderr,
		/another provisioning process/,
	);
	assert.equal(f.current(), previous);
	assert.equal(f.read(a), "old");
	const exited = once(holder, "exit");
	holder.stdin.end();
	await exited;
});
