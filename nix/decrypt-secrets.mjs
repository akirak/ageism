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

// Extract the identity ID from a deployed secret filename such as
// "sha256-<sha256>.<ID>.age" -> "<ID>"
function identityId(source) {
	const parts = path.basename(source).split(".");
	if (parts.length < 3 || !parts[0].startsWith("sha256-")) return null;
	return parts[parts.length - 2];
}

let failed = 0;

for (const [_, { source, path: dest, owner, mode }] of Object.entries(secrets)) {
	if (fs.existsSync(dest)) {
		console.log(`skip ${dest} (already exists)`);
		continue;
	}

	const id = identityId(source);
	if (!id) {
		console.error(`error: cannot determine identity ID from source: ${source}`);
		failed++;
		continue;
	}
	const identity = path.join(path.dirname(source), `identity.${id}`);

	// Decrypt into a temp file on the same filesystem as the destination.
	fs.mkdirSync(path.dirname(dest), { recursive: true });
	const tmpDir = fs.mkdtempSync(path.join(path.dirname(dest), ".ageism-"));
	const tmpFile = path.join(tmpDir, "secret");

	try {
		execFileSync(ageBin, ["--decrypt", "-i", identity, "-o", tmpFile, source], {
			stdio: ["pipe", "pipe", "pipe"],
		});
		fs.writeFileSync(dest, fs.readFileSync(tmpFile), {
			mode: parseInt(mode, 8),
		});
		execFileSync("chown", [owner, dest]);
		execFileSync("chmod", [mode, dest]);
		console.log(`installed ${dest}`);
	} catch (err) {
		failed++;
		console.error(`error: ${source} -> ${dest}: ${err.stderr || err.message}`);
	} finally {
		fs.rmSync(tmpDir, { recursive: true, force: true });
	}
}

if (failed > 0) {
	console.error(`${failed} secret(s) failed to install`);
	process.exit(1);
}
