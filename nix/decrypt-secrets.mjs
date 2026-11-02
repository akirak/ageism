#!/usr/bin/env node
// Stage a complete generation inside each destination directory's generation
// store, then publish that directory with a single atomic rename of the
// store's `current` symlink. Nothing is published in any directory until
// decryption and permission setup have succeeded for every directory; a
// failure rolls back directories already published in the same run.
//
// Configured destinations are *relative* symlinks that never leave their own
// directory, so bind-mounting a destination directory (or any of its
// ancestors) cannot produce dead links. Cache metadata lives inside the
// generation, so it is committed together with the secrets.
//
// Layout for a secret installed at DIR/NAME:
//   DIR/NAME -> .ageism/current/NAME          (relative symlink)
//   DIR/.ageism/current -> generation-XXXX    (relative symlink)
//   DIR/.ageism/generation-XXXX/NAME          (plaintext)
//   DIR/.ageism/generation-XXXX/state.json    (cache metadata)
//   DIR/.ageism/lock                          (advisory lock file)
//
// With --for-users, the store is named .ageism.for-users instead, so the
// user-creation phase and the regular phase never share a store.
//
// Usage: decrypt-secrets.mjs MANIFEST.json [--for-users] [--prune DIR]
//        [--last-manifest FILE]

import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

function usage() {
	console.error(
		"usage: decrypt-secrets.mjs MANIFEST.json [--for-users] [--prune DIR] [--last-manifest FILE]",
	);
	process.exit(64);
}

let manifestPath = null;
let pruneDir = null;
let lastManifestPath = null;
let forUsers = false;
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i++) {
	const arg = args[i];
	if (arg === "--prune" || arg === "--last-manifest") {
		const value = args[++i];
		if (value === undefined) usage();
		if (arg === "--prune") pruneDir = value;
		else lastManifestPath = value;
	} else if (arg === "--for-users") {
		forUsers = true;
	} else if (!arg.startsWith("-") && manifestPath === null) {
		manifestPath = arg;
	} else {
		usage();
	}
}
if (!manifestPath) usage();

const ageBin = process.env.AGE_BIN || "age";
const uid = process.getuid();
const storeName = `.ageism${forUsers ? ".for-users" : ""}`;
const stateFile = "state.json";

// Open file descriptors of lock files. The kernel releases the locks when
// this process exits or is killed, however it terminates.
const heldLocks = [];

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

function isGenerationName(name) {
	return /^generation-[A-Za-z0-9]+$/.test(name);
}

function storeOf(dir) {
	return path.join(dir, storeName);
}

// The relative symlink installed at a destination, resolved by any process
// that can traverse the destination's own directory.
function managedLink(name) {
	return path.join(storeName, "current", name);
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

function currentGeneration(store) {
	const current = path.join(store, "current");
	const st = lstat(current);
	if (!st) return null;
	if (!st.isSymbolicLink()) throw new Error(`${current} is not a symlink`);
	const name = fs.readlinkSync(current);
	if (!isGenerationName(name))
		throw new Error(`${current} does not point to a managed generation`);
	const dir = path.join(store, name);
	assertTrusted(dir);
	return dir;
}

function newGeneration(store) {
	// Private while staging; made traversable right before publication.
	return fs.mkdtempSync(path.join(store, "generation-"));
}

function publish(store, dir) {
	const temporary = path.join(store, `.current-${path.basename(dir)}`);
	fs.symlinkSync(path.basename(dir), temporary);
	try {
		fs.renameSync(temporary, path.join(store, "current"));
	} catch (err) {
		fs.rmSync(temporary, { force: true });
		throw err;
	}
}

// Take the advisory lock of a store. The flock child locks the descriptor
// inherited through stdio and exits immediately; the lock is held by the open
// file description, i.e. until this process closes the descriptor, even if it
// is killed. Never unlink the lock file: another caller may already have
// opened the same inode.
function acquireLock(store) {
	const lockPath = path.join(store, "lock");
	const fd = fs.openSync(lockPath, "a");
	const worker = spawnSync(
		"flock",
		["--exclusive", "--nonblock", "--conflict-exit-code", "75", "3"],
		{ stdio: ["ignore", "inherit", "inherit", fd] },
	);
	if (worker.status === 75) {
		fs.closeSync(fd);
		throw new Error(`another provisioning process holds ${lockPath}`);
	}
	if (worker.error || worker.status !== 0) {
		fs.closeSync(fd);
		throw (
			worker.error ||
			new Error(`cannot lock ${lockPath} (flock exited ${worker.status})`)
		);
	}
	heldLocks.push(fd);
}

// Find generation stores of this phase below the prune directory whose
// directories no longer have any secrets, so their plaintexts can be
// retired. Symlinks are never followed, so the scan cannot escape the tree.
function scanStores(prune) {
	const found = [];
	const walk = (dir) => {
		let list;
		try {
			list = fs.readdirSync(dir, { withFileTypes: true });
		} catch (err) {
			console.error(`warning: cannot scan ${dir}: ${err.message}`);
			return;
		}
		for (const ent of list) {
			if (!ent.isDirectory()) continue;
			if (ent.name === storeName) {
				const current = path.join(dir, ent.name, "current");
				if (
					lstat(current)?.isSymbolicLink() &&
					isGenerationName(fs.readlinkSync(current))
				)
					found.push(path.join(dir, ent.name));
			} else walk(path.join(dir, ent.name));
		}
	};
	walk(prune);
	return found;
}

// Prepare the public destination symlinks. Backups are kept in memory rather
// than leaving plaintext copies beside destinations after a crash. Before the
// switch, the symlinks resolve to the old generation (or dangle for new
// secrets).
function installAlias(target, name, changes) {
	const link = managedLink(name);
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

// Remove managed symlinks of this phase that the new manifest no longer
// uses. Other files, directories and the other phase's symlinks are left
// alone; nothing is ever removed recursively.
function pruneAliases(prune, byDir) {
	const keepByDir = new Map(
		[...byDir].map(([dir, entries]) => [dir, new Set(entries.keys())]),
	);
	const walk = (dir) => {
		let list;
		try {
			list = fs.readdirSync(dir, { withFileTypes: true });
		} catch (err) {
			console.error(`warning: cannot scan ${dir}: ${err.message}`);
			return;
		}
		const keep = keepByDir.get(dir);
		for (const ent of list) {
			const file = path.join(dir, ent.name);
			if (ent.isSymbolicLink()) {
				if (
					fs.readlinkSync(file) === managedLink(ent.name) &&
					!keep?.has(ent.name)
				)
					fs.unlinkSync(file);
			} else if (ent.isDirectory() && ent.name !== storeName) walk(file);
		}
	};
	walk(prune);
}

function provision() {
	const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
	if (!manifest || typeof manifest !== "object" || Array.isArray(manifest))
		throw new Error("manifest must be an object");

	// Validate the entries and group them by canonical destination directory.
	const byDir = new Map(); // canonical directory -> Map(basename -> entry)
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
		if (path.basename(target) === stateFile)
			throw new Error(`destination name is reserved: ${entry.path}`);
		if (lstat(target)?.isDirectory())
			throw new Error(`destination is a directory: ${entry.path}`);
		if (targets.has(target))
			throw new Error(`duplicate destination: ${entry.path}`);
		targets.add(target);
		if (!byDir.has(path.dirname(target)))
			byDir.set(path.dirname(target), new Map());
		byDir.get(path.dirname(target)).set(path.basename(target), {
			...entry,
			target,
		});
	}
	for (const target of targets)
		for (const component of target.split(path.sep))
			if (component === storeName)
				throw new Error(`destination overlaps a generation store: ${target}`);

	const last = lastManifestPath ? destination(lastManifestPath) : null;
	if (last) {
		if (targets.has(last))
			throw new Error("last manifest overlaps a secret destination");
		for (const component of last.split(path.sep))
			if (component === storeName)
				throw new Error(
					`last manifest overlaps a generation store: ${lastManifestPath}`,
				);
	}
	const prune = pruneDir ? trustedDirectory(pruneDir) : null;

	// Directories that no longer have secrets of this phase keep their store;
	// with pruning they are switched to an empty generation and collected.
	const stores = new Map(); // store directory -> { dir, entries, orphan }
	for (const [dir, entries] of byDir)
		stores.set(storeOf(dir), { dir, entries, orphan: false });
	if (prune)
		for (const store of scanStores(prune))
			if (!stores.has(store))
				stores.set(store, {
					dir: path.dirname(store),
					entries: new Map(),
					orphan: true,
				});

	// Create the stores and take every lock in sorted order, so concurrent
	// runs cannot deadlock and always fail closed instead of interleaving.
	for (const store of [...stores.keys()].sort()) {
		const info = stores.get(store);
		try {
			trustedDirectory(path.dirname(store));
			if (!fs.existsSync(store)) {
				fs.mkdirSync(store, { mode: 0o755 });
				fs.chmodSync(store, 0o755); // Override the service's UMask=0077.
			}
			assertTrusted(store);
		} catch (err) {
			if (info.orphan) {
				stores.delete(store);
				console.error(
					`warning: skipping generation store ${store}: ${err.message}`,
				);
				continue;
			}
			throw err;
		}
		acquireLock(store);
	}

	let committed = false;
	const changes = [];
	const seeded = [];
	const contexts = new Map();
	try {
		// Stage every directory first: nothing is published until every
		// plaintext and permission change has succeeded.
		for (const [store, info] of stores) {
			const original = currentGeneration(store);
			let old = {};
			if (original)
				try {
					old = JSON.parse(
						fs.readFileSync(path.join(original, stateFile), "utf8"),
					);
				} catch (err) {
					if (!info.orphan) throw err;
					console.error(
						`warning: ignoring cache state in ${original}: ${err.message}`,
					);
				}
			if (!old || typeof old !== "object" || Array.isArray(old))
				throw new Error(`invalid cache state in ${original ?? store}`);
			const oldTargets = new Set(
				Object.values(old).map((entry) => entry.target),
			);
			const staged = newGeneration(store);
			const context = {
				store,
				info,
				original,
				previous: original,
				old,
				oldTargets,
				staged,
				baseline: null,
				switched: false,
			};
			contexts.set(store, context);
			for (const [name, entry] of info.entries) {
				const file = path.join(staged, name);
				const cached = original && path.join(original, name);
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
			fs.writeFileSync(
				path.join(staged, stateFile),
				JSON.stringify(Object.fromEntries(info.entries)),
				{ mode: 0o600 },
			);
		}

		// Import existing regular files and foreign symlinks into a baseline
		// generation, so they stay readable until the switch, then publish each
		// directory with one atomic rename of its store's current pointer.
		for (const context of contexts.values()) {
			const { store, info, oldTargets, staged } = context;
			for (const [name, entry] of info.entries) {
				const st = lstat(entry.target);
				if (
					!st ||
					(st.isSymbolicLink() &&
						fs.readlinkSync(entry.target) === managedLink(name))
				)
					continue;
				if (st.isSymbolicLink() && !fs.existsSync(entry.target)) continue;
				if (!st.isFile() && !st.isSymbolicLink())
					throw new Error(`${entry.path} is not a file or symlink`);
				if (!context.previous) {
					context.baseline = newGeneration(store);
					fs.writeFileSync(path.join(context.baseline, stateFile), "{}", {
						mode: 0o600,
					});
					context.previous = context.baseline;
				}
				const originalFile = path.join(context.previous, name);
				if (lstat(originalFile) && oldTargets.has(entry.target))
					throw new Error(`managed destination was replaced: ${entry.path}`);
				seeded.push(originalFile);
				// A killed migration may have left an unrecorded seed in the
				// previous generation. It is not a committed secret and can be
				// recreated.
				fs.rmSync(originalFile, { force: true });
				copyOriginal(entry.target, originalFile);
			}
			if (context.baseline) {
				fs.chmodSync(context.baseline, 0o755);
				publish(store, context.baseline);
				context.switched = true;
			}
			for (const [name, entry] of info.entries)
				installAlias(entry.target, name, changes);
			fs.chmodSync(staged, 0o755);
			publish(store, staged);
			context.switched = true;
			console.log(`published ${staged}`);
		}
		committed = true;

		// The file is a record for the operator; reuse decisions read the
		// cache state committed inside each store, so a failed write cannot
		// make the cache describe a different set of secrets.
		if (last)
			try {
				const temporary = `${last}.${process.pid}.tmp`;
				fs.copyFileSync(manifestPath, temporary);
				fs.chmodSync(temporary, 0o600);
				fs.renameSync(temporary, last);
			} catch (err) {
				console.error(
					`warning: cannot save last manifest to ${last}: ${err.message}`,
				);
			}

		// Only remove aliases owned by this phase, and only after publication.
		// Never recursively delete arbitrary destination trees.
		if (prune)
			try {
				pruneAliases(prune, byDir);
				for (const context of contexts.values()) {
					const keep = new Set(
						[context.staged, context.previous]
							.filter(Boolean)
							.map((dir) => path.basename(dir)),
					);
					for (const name of fs.readdirSync(context.store))
						if (isGenerationName(name) && !keep.has(name))
							fs.rmSync(path.join(context.store, name), {
								recursive: true,
								force: true,
							});
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
			for (const context of contexts.values()) {
				// A directory published before a later one failed is switched
				// back to its previous generation.
				if (context.switched) {
					if (context.original) publish(context.store, context.original);
					else fs.rmSync(path.join(context.store, "current"), { force: true });
				}
				if (context.baseline)
					fs.rmSync(context.baseline, { recursive: true, force: true });
				fs.rmSync(context.staged, { recursive: true, force: true });
			}
		}
	}
}

try {
	provision();
} catch (err) {
	console.error(`error: ${err.stderr || err.message}`);
	process.exitCode = 1;
}
