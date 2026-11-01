#!/usr/bin/env node
// Stage a complete generation, then publish it with one atomic symlink rename.
// Configured destinations are stable symlinks through GENERATION_DIR/current.
// Cache metadata lives in the generation, so it is committed with the secrets.
// Usage: decrypt-secrets.mjs MANIFEST.json [--generation-dir DIR]
//        [--prune DIR] [--last-manifest FILE]

import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

function usage() {
	console.error(
		"usage: decrypt-secrets.mjs MANIFEST.json [--generation-dir DIR] [--prune DIR] [--last-manifest FILE]",
	);
	process.exit(64);
}

let manifestPath = null;
let generationDir = "/run/ageism/.generations";
let pruneDir = null;
let lastManifestPath = null;
let locked = false;
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i++) {
	const arg = args[i];
	if (["--generation-dir", "--prune", "--last-manifest"].includes(arg)) {
		const value = args[++i];
		if (value === undefined) usage();
		if (arg === "--generation-dir") generationDir = value;
		else if (arg === "--prune") pruneDir = value;
		else lastManifestPath = value;
	} else if (arg === "--locked") {
		locked = true; // Internal worker, launched under flock below.
	} else if (!arg.startsWith("-") && manifestPath === null) {
		manifestPath = arg;
	} else {
		usage();
	}
}
if (!manifestPath) usage();

const ageBin = process.env.AGE_BIN || "age";
const uid = process.getuid();

function lstat(file) {
	try {
		return fs.lstatSync(file);
	} catch (err) {
		if (err.code === "ENOENT") return null;
		throw err;
	}
}

function assertTrusted(dir) {
	const st = fs.lstatSync(dir);
	if (!st.isDirectory()) throw new Error(`${dir} is not a directory`);
	if (st.uid !== uid) throw new Error(`${dir} is not owned by uid ${uid}`);
	if (st.mode & 0o022) throw new Error(`${dir} is writable by group or others`);
}

// Canonicalize existing components before checking all their ancestors.
function trustedDirectory(dir) {
	const missing = [];
	let existing = path.resolve(dir);
	while (!fs.existsSync(existing)) {
		missing.unshift(path.basename(existing));
		existing = path.dirname(existing);
	}
	let current = fs.realpathSync(existing);
	for (let ancestor = current; ; ancestor = path.dirname(ancestor)) {
		assertTrusted(ancestor);
		if (path.dirname(ancestor) === ancestor) break;
	}
	for (const name of missing) {
		current = path.join(current, name);
		fs.mkdirSync(current, { mode: 0o755 });
		fs.chmodSync(current, 0o755); // Override the service's UMask=0077.
		assertTrusted(current);
	}
	return current;
}

function destination(target) {
	if (typeof target !== "string" || !path.isAbsolute(target))
		throw new Error(`destination must be an absolute path: ${target}`);
	return path.join(
		trustedDirectory(path.dirname(target)),
		path.basename(target),
	);
}

function inside(parent, child) {
	const relative = path.relative(parent, child);
	return (
		relative === "" ||
		(!relative.startsWith(`..${path.sep}`) &&
			relative !== ".." &&
			!path.isAbsolute(relative))
	);
}

function fileId(target) {
	return createHash("sha256").update(target).digest("hex");
}

function sameEntry(a, b) {
	if (!a || !b) return false;
	return ["source", "path", "owner", "mode", "target"].every(
		(key) => a[key] === b[key],
	);
}

function findIdentity(source) {
	const match = /^sha256-[^.]+\.([0-9a-f]{8})\.age$/.exec(
		path.basename(source),
	);
	if (!match)
		throw new Error(`cannot determine identity ID from source: ${source}`);
	let dir = path.resolve(path.dirname(source));
	for (;;) {
		const candidate = path.join(dir, `identity.${match[1]}`);
		if (fs.existsSync(candidate) || path.dirname(dir) === dir) return candidate;
		dir = path.dirname(dir);
	}
}

function setPermissions(file, entry) {
	execFileSync("chown", ["--", entry.owner, file]);
	execFileSync("chmod", ["--", entry.mode, file]);
}

function copyOriginal(source, dest) {
	const canonical = fs.realpathSync(source);
	trustedDirectory(path.dirname(canonical));
	const st = fs.lstatSync(canonical);
	if (!st.isFile()) throw new Error(`${source} is not a regular file`);
	fs.copyFileSync(canonical, dest, fs.constants.COPYFILE_EXCL);
	fs.chownSync(dest, st.uid, st.gid);
	fs.chmodSync(dest, st.mode & 0o7777);
}

function currentGeneration(root) {
	const current = path.join(root, "current");
	const st = lstat(current);
	if (!st) return null;
	if (!st.isSymbolicLink()) throw new Error(`${current} is not a symlink`);
	const name = fs.readlinkSync(current);
	if (!/^generation-[A-Za-z0-9]+$/.test(name))
		throw new Error(`${current} does not point to a managed generation`);
	const dir = path.join(root, name);
	assertTrusted(dir);
	assertTrusted(path.join(dir, "files"));
	return dir;
}

function newGeneration(root) {
	const dir = fs.mkdtempSync(path.join(root, "generation-"));
	fs.mkdirSync(path.join(dir, "files"), { mode: 0o755 });
	fs.chmodSync(path.join(dir, "files"), 0o755);
	return dir;
}

function publish(root, dir) {
	const temporary = path.join(root, `.current-${path.basename(dir)}`);
	fs.symlinkSync(path.basename(dir), temporary);
	try {
		fs.renameSync(temporary, path.join(root, "current"));
	} catch (err) {
		fs.rmSync(temporary, { force: true });
		throw err;
	}
}

// Prepare stable public aliases. Keep legacy backups in memory, rather than
// leaving additional plaintext copies beside destinations after a crash. Before
// the commit, aliases resolve to the old generation (or dangle for new secrets).
function installAlias(target, link, changes) {
	const st = lstat(target);
	if (st?.isSymbolicLink() && fs.readlinkSync(target) === link) return;
	if (st && !st.isFile() && !st.isSymbolicLink())
		throw new Error(`${target} is not a file or symlink`);
	const temporary = fs.mkdtempSync(path.join(path.dirname(target), ".ageism-"));
	try {
		const previous = st?.isSymbolicLink()
			? { link: fs.readlinkSync(target) }
			: st
				? {
						data: fs.readFileSync(target),
						uid: st.uid,
						gid: st.gid,
						mode: st.mode & 0o7777,
					}
				: null;
		const next = path.join(temporary, "next");
		fs.symlinkSync(link, next);
		fs.renameSync(next, target);
		changes.push({ target, temporary, previous });
	} catch (err) {
		fs.rmSync(temporary, { recursive: true, force: true });
		throw err;
	}
}

function provision() {
	const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
	if (!manifest || typeof manifest !== "object" || Array.isArray(manifest))
		throw new Error("manifest must be an object");
	const root = trustedDirectory(generationDir);
	let staged;
	let baseline;
	let committed = false;
	const changes = [];
	const seeded = [];
	try {
		let previous = currentGeneration(root);
		const old = previous
			? JSON.parse(fs.readFileSync(path.join(previous, "state.json"), "utf8"))
			: {};
		const oldTargets = new Set(Object.values(old).map((entry) => entry.target));
		const entries = {};
		const targets = new Set();
		for (const [name, entry] of Object.entries(manifest)) {
			if (
				!entry ||
				typeof entry.source !== "string" ||
				typeof entry.owner !== "string" ||
				typeof entry.mode !== "string" ||
				!/^[0-7]{3,4}$/.test(entry.mode)
			)
				throw new Error(`invalid manifest entry: ${name}`);
			const target = destination(entry.path);
			if (inside(root, target) || inside(target, root))
				throw new Error(
					`destination overlaps generation directory: ${entry.path}`,
				);
			if (targets.has(target))
				throw new Error(`duplicate destination: ${entry.path}`);
			targets.add(target);
			Object.defineProperty(entries, name, {
				value: { ...entry, target },
				enumerable: true,
			});
		}
		const last = lastManifestPath ? destination(lastManifestPath) : null;
		if (last && (targets.has(last) || inside(root, last) || inside(last, root)))
			throw new Error(
				"last manifest overlaps a secret or generation directory",
			);
		const prune = pruneDir ? trustedDirectory(pruneDir) : null;
		staged = newGeneration(root);
		for (const [name, entry] of Object.entries(entries)) {
			const file = path.join(staged, "files", fileId(entry.target));
			const cached =
				previous && path.join(previous, "files", fileId(entry.target));
			if (last && sameEntry(old[name], entry) && lstat(cached)?.isFile()) {
				fs.copyFileSync(cached, file, fs.constants.COPYFILE_EXCL);
				console.log(`reused ${entry.path} (unchanged)`);
			} else {
				execFileSync(
					ageBin,
					[
						"--decrypt",
						"-i",
						findIdentity(entry.source),
						"-o",
						file,
						entry.source,
					],
					{
						stdio: ["pipe", "pipe", "pipe"],
					},
				);
			}
			setPermissions(file, entry);
		}
		fs.writeFileSync(path.join(staged, "state.json"), JSON.stringify(entries), {
			mode: 0o600,
		});
		fs.writeFileSync(
			path.join(staged, "manifest.json"),
			JSON.stringify(manifest),
			{ mode: 0o600 },
		);

		// Import legacy regular files only after staging succeeds. This preserves
		// their contents while converting their paths to generation aliases.
		for (const entry of Object.values(entries)) {
			const link = path.join(root, "current", "files", fileId(entry.target));
			const st = lstat(entry.target);
			if (
				!st ||
				(st.isSymbolicLink() && fs.readlinkSync(entry.target) === link)
			)
				continue;
			if (st.isSymbolicLink() && !fs.existsSync(entry.target)) continue;
			if (!st.isFile() && !st.isSymbolicLink())
				throw new Error(`${entry.path} is not a file or symlink`);
			if (!previous) {
				baseline = newGeneration(root);
				fs.writeFileSync(path.join(baseline, "state.json"), "{}", {
					mode: 0o600,
				});
				if (last && fs.existsSync(last) && fs.statSync(last).isFile())
					fs.writeFileSync(
						path.join(baseline, "manifest.json"),
						fs.readFileSync(last),
						{
							mode: 0o600,
						},
					);
				previous = baseline;
			}
			const original = path.join(previous, "files", fileId(entry.target));
			if (lstat(original) && oldTargets.has(entry.target))
				throw new Error(`managed destination was replaced: ${entry.path}`);
			seeded.push(original);
			// A killed migration may have left an unrecorded seed in the old
			// generation. It is not a committed secret and can be recreated.
			fs.rmSync(original, { force: true });
			copyOriginal(entry.target, original);
		}
		if (baseline) {
			fs.chmodSync(baseline, 0o755);
			publish(root, baseline);
		}
		for (const entry of Object.values(entries))
			installAlias(
				entry.target,
				path.join(root, "current", "files", fileId(entry.target)),
				changes,
			);
		if (last)
			installAlias(last, path.join(root, "current", "manifest.json"), changes);

		fs.chmodSync(staged, 0o755);
		publish(root, staged);
		committed = true;
		console.log(`published ${staged}`);

		// Only remove aliases owned by this generation set, and only after
		// publication. Never recursively delete arbitrary destination trees.
		if (prune)
			try {
				for (const entry of Object.values(old)) {
					if (!targets.has(entry.target) && inside(prune, entry.target)) {
						const target = destination(entry.target);
						const link = path.join(root, "current", "files", fileId(target));
						if (
							lstat(target)?.isSymbolicLink() &&
							fs.readlinkSync(target) === link
						)
							fs.unlinkSync(target);
					}
				}
				for (const name of fs.readdirSync(root)) {
					const dir = path.join(root, name);
					if (
						/^generation-[A-Za-z0-9]+$/.test(name) &&
						dir !== staged &&
						dir !== previous
					)
						fs.rmSync(dir, { recursive: true, force: true });
				}
			} catch (err) {
				console.error(
					`warning: generation committed, but pruning failed: ${err.message}`,
				);
			}
	} finally {
		for (const change of changes.reverse()) {
			if (!committed) {
				if (change.previous) {
					const backup = path.join(change.temporary, "previous");
					if (change.previous.link !== undefined)
						fs.symlinkSync(change.previous.link, backup);
					else {
						fs.writeFileSync(backup, change.previous.data, { mode: 0o600 });
						fs.chownSync(backup, change.previous.uid, change.previous.gid);
						fs.chmodSync(backup, change.previous.mode);
					}
					fs.renameSync(backup, change.target);
				} else fs.unlinkSync(change.target);
			}
			fs.rmSync(change.temporary, { recursive: true, force: true });
		}
		if (!committed) {
			for (const file of seeded) fs.rmSync(file, { force: true });
			if (baseline) {
				fs.rmSync(path.join(root, "current"), { force: true });
				fs.rmSync(baseline, { recursive: true, force: true });
			}
			if (staged) fs.rmSync(staged, { recursive: true, force: true });
		}
	}
}

try {
	if (locked) {
		provision();
	} else {
		// An advisory lock serializes standalone callers as well as services.
		// It is released by the kernel even if the worker is killed. Never unlink
		// the lock file: another caller may already have opened the same inode.
		const root = trustedDirectory(generationDir);
		const worker = spawnSync(
			"flock",
			[
				"--exclusive",
				"--nonblock",
				"--conflict-exit-code",
				"75",
				path.join(root, "lock"),
				process.execPath,
				...process.execArgv,
				fileURLToPath(import.meta.url),
				...args,
				"--locked",
			],
			{ stdio: "inherit" },
		);
		if (worker.error) throw worker.error;
		if (worker.status === 75)
			throw new Error(`another provisioning process holds ${root}/lock`);
		process.exitCode = worker.status ?? 1;
	}
} catch (err) {
	console.error(`error: ${err.stderr || err.message}`);
	process.exitCode = 1;
}
