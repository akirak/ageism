#!/usr/bin/env node
// Decrypt secrets listed in a JSON manifest using age.
//
// Manifest entries look like:
//   {
//     "source": "/var/lib/ageism/sha256-<sha256>.<ID>.age",
//     "path":   "/run/ageism/foo",
//     "owner":  "user",
//     "mode":   "600"
//   }
//
// Each entry is decrypted with:
//   age --decrypt -i <source-dir>/identity.<ID> -o TMPFILE <source>
// and installed at `path` with the given owner and mode.
//
// The script runs as root, so the parent directory of `path` and all of its
// ancestors (after resolving symlinks) must be owned by the current user and
// must not be writable by group or others. Otherwise another user could
// redirect the write elsewhere. The plaintext gets its owner and mode in a
// private temporary directory, then is renamed into place.
//
// Usage: decrypt-secrets.mjs MANIFEST.json

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const manifestPath = process.argv[2];
if (!manifestPath) {
	console.error("usage: decrypt-secrets.mjs MANIFEST.json");
	process.exit(64);
}

const ageBin = process.env.AGE_BIN || "age";

const secrets = JSON.parse(fs.readFileSync(manifestPath, "utf8"));

const uid = process.getuid();

// Extract the identity ID from a deployed secret filename such as
// "sha256-<sha256>.<ID>.age" -> "<ID>"
function identityId(source) {
	const parts = path.basename(source).split(".");
	if (parts.length < 3 || !parts[0].startsWith("sha256-")) return null;
	return parts[parts.length - 2];
}

function assertTrusted(dir) {
	const st = fs.lstatSync(dir);
	if (!st.isDirectory()) throw new Error(`${dir} is not a directory`);
	if (st.uid !== uid) throw new Error(`${dir} is not owned by uid ${uid}`);
	if (st.mode & 0o022) throw new Error(`${dir} is writable by group or others`);
}

// Resolve `dir` to a canonical path whose every component is a trusted
// directory, creating missing components.
function trustedDirectory(dir) {
	const missing = [];
	let existing = path.resolve(dir);
	while (!fs.existsSync(existing)) {
		missing.unshift(path.basename(existing));
		existing = path.dirname(existing);
	}
	let current = fs.realpathSync(existing);
	let ancestor = current;
	for (;;) {
		assertTrusted(ancestor);
		const parent = path.dirname(ancestor);
		if (parent === ancestor) break;
		ancestor = parent;
	}
	for (const name of missing) {
		current = path.join(current, name);
		fs.mkdirSync(current, { mode: 0o755 });
		// The service runs with UMask=0077, so set the mode explicitly to let
		// secret owners traverse the directory.
		fs.chmodSync(current, 0o755);
		assertTrusted(current);
	}
	return current;
}

let failed = 0;

for (const [_, { source, path: target, owner, mode }] of Object.entries(
	secrets,
)) {
	const id = identityId(source);
	if (!id) {
		console.error(`error: cannot determine identity ID from source: ${source}`);
		failed++;
		continue;
	}
	const identity = path.join(path.dirname(source), `identity.${id}`);

	let tmpDir;
	try {
		if (!/^[0-7]{3,4}$/.test(mode))
			throw new Error(`invalid mode ${JSON.stringify(mode)}`);
		const dir = trustedDirectory(path.dirname(target));
		const dest = path.join(dir, path.basename(target));

		const existing = fs.lstatSync(dest, { throwIfNoEntry: false });
		if (existing?.isFile()) {
			console.log(`skip ${target} (already exists)`);
			continue;
		}
		if (existing) throw new Error(`${dest} exists and is not a regular file`);

		// Decrypt into a private directory on the same filesystem as the
		// destination, so the rename below is atomic.
		tmpDir = fs.mkdtempSync(path.join(dir, ".ageism-"));
		const tmpFile = path.join(tmpDir, "secret");

		execFileSync(ageBin, ["--decrypt", "-i", identity, "-o", tmpFile, source], {
			stdio: ["pipe", "pipe", "pipe"],
		});
		execFileSync("chown", ["--", owner, tmpFile]);
		execFileSync("chmod", ["--", mode, tmpFile]);
		fs.renameSync(tmpFile, dest);
		console.log(`installed ${target}`);
	} catch (err) {
		failed++;
		console.error(
			`error: ${source} -> ${target}: ${err.stderr || err.message}`,
		);
	} finally {
		if (tmpDir) fs.rmSync(tmpDir, { recursive: true, force: true });
	}
}

if (failed > 0) {
	console.error(`${failed} secret(s) failed to install`);
	process.exit(1);
}
