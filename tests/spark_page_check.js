// tests/spark_page_check.js — checks the spark generator page (index.html) against spark.sh.
//   node tests/spark_page_check.js <index.html> <spark.sh>
// Pass 1: every page pattern equals spark.sh's pattern, char for char (NAME=pattern block vs the bash regex source).
// Pass 2: JS and real bash agree on accept/reject for a fixture list (the page's regex semantics must not drift from bash's).
// Pass 3: page-only rules (no '..', port range, https shape) and command safety (hostile values throw or are quoted; `bash -n`).
// Exits 1 on the first failure class, printing every mismatch.
'use strict';
const fs = require('fs'), vm = require('vm'), cp = require('child_process');
const [pagePath, sparkPath] = process.argv.slice(2);
const page = fs.readFileSync(pagePath, 'utf8'), spark = fs.readFileSync(sparkPath, 'utf8');
const fails = [];
const check = (ok, msg) => { if (!ok) fails.push(msg); };

const blockOf = (id) => { const m = page.match(new RegExp('<script[^>]*id="' + id + '"[^>]*>([\\s\\S]*?)</script>')); return m ? m[1] : null; };
const patText = blockOf('spark-patterns'), logicText = blockOf('spark-logic');
if (patText === null || logicText === null) { console.error('page lacks the spark-patterns / spark-logic script blocks'); process.exit(1); }

const pagePat = {};
for (const line of patText.split('\n')) { const m = line.trim().match(/^([A-Z_]+)=(.+)$/); if (m) pagePat[m[1]] = m[2]; }

// spark.sh's own source of each pattern
const bashVar = (v) => { const m = spark.match(new RegExp("^_SPARK_RE_" + v + "='([^']*)'", 'm')); return m ? m[1] : null; };
const refM = spark.match(/\[\[ "\$REF" =~ (\^\[A-Za-z0-9\]\[A-Za-z0-9\._\/-\]\*\$) \]\]/);
const sparkPat = { TAG: bashVar('TAG'), REPO: bashVar('REPO'), VAULT: bashVar('VAULT'), SSH_URL: bashVar('SSH_URL'), REF: refM ? refM[1] : null };
for (const k of Object.keys(sparkPat)) {
  check(sparkPat[k] !== null, `could not extract ${k} from spark.sh`);
  check(pagePat[k] !== undefined, `page has no ${k} pattern`);
  check(sparkPat[k] === pagePat[k], `${k} drifted:\n   spark.sh: ${sparkPat[k]}\n   page:     ${pagePat[k]}`);
}
for (const k of Object.keys(pagePat)) check(k in sparkPat, `page pattern ${k} has no spark.sh counterpart in this check`);
if (fails.length) { console.error(fails.join('\n')); process.exit(1); }

// Pass 2: JS vs bash on fixtures
const longRepo = 'a'.repeat(65), okRepo = 'a'.repeat(64);
const fixtures = {
  TAG: ['v1.2.3', 'v10.20.30', 'v1x2x3', 'v1.2', 'v1.2.3.4', '1.2.3', 'v1.2.3\n', 'v1.2.3-rc1', ' v1.2.3', ''],
  REPO: ['dotFiles', 'a', okRepo, longRepo, '-x', '.x', 'a b', 'a/b', 'a..b', 'a\n', 'x;y', "x'y", ''],
  VAULT: ['Private', 'My Vault', ' lead', 'a'.repeat(65), "a'b", 'a\nb', ''],
  SSH_URL: ['ssh://host/owner', 'ssh://git@host/owner', 'ssh://git@host:2222/owner', 'ssh://-oProxy@host/o', 'ssh://host/', 'ssh://host:99999/o', 'ssh://host/o w', 'ssh://host/o\n', 'ssh://u@h@host/o', 'ssh://host', 'ssh://git@host:/o'],
  REF: ['main', 'feat/x', 'v1.2.3', '-bad', '.bad', 'a b', 'a\nb', 'a;b', 'a..b', '', 'x'.repeat(300)],
};
const bash = (re, s) => cp.spawnSync('/bin/bash', ['-c', 'LC_ALL=C; [[ "$1" =~ $2 ]]', 'x', s, re]).status === 0;
for (const k of Object.keys(fixtures)) {
  const js = new RegExp(pagePat[k]);
  for (const s of fixtures[k]) check(js.test(s) === bash(sparkPat[k], s), `${k}: JS and bash disagree on ${JSON.stringify(s)} (js=${js.test(s)})`);
}

// Pass 3: the page's logic
const ctx = {}; vm.createContext(ctx); vm.runInContext(logicText + '\nthis.SparkLogic = SparkLogic;', ctx);
const L = ctx.SparkLogic, P = L.loadPatterns(patText);
const v = (o) => L.validate(Object.assign({ base: 'https://host/owner', repo: '', ref: '', vault: '' }, o), P);
check(v({}).ok, 'a plain https base must validate');
check(v({ base: 'ssh://git@host:2222/owner' }).ok, 'an ssh base with user and port must validate');
check(!v({ base: '' }).ok, 'empty base must be refused');
for (const b of ['/abs/path', 'git@host:owner/x', 'http://host/owner', 'https://u:pw@host/owner', 'https://host', 'https://host/../x', 'https://example.com/o', 'https://host/<owner>', 'ssh://host:0/o', 'ssh://host:65536/o', 'ssh://host/a..b', 'ssh://host/a b', 'https://host/o\nx', 'ssh://a::b/o'])
  check(!v({ base: b }).ok, `base ${JSON.stringify(b)} must be refused`);
check(v({ base: 'ssh://host/owner/' }).ok, 'a trailing slash is stripped, as spark does');
check(!v({ repo: 'a..b' }).ok, 'repo with .. must be refused');
check(!v({ ref: 'a..b' }).ok, 'ref with .. must be refused');
check(v({ ref: 'v1.2.3' }).refKind === 'release', 'vX.Y.Z is a release ref');
check(v({ ref: 'feat/x' }).refKind === 'branch', 'anything else valid is a branch ref');
check(v({ vault: 'My Vault' }).ok, 'a vault with a space validates');

const rawBase = 'https://raw.githubusercontent.com/o/spark';
const build = (o) => L.buildCommand(Object.assign({ rawBase, base: 'https://host/owner', repo: '', ref: '', vault: '', noOp: false, plan: false }, o));
const hostile = ["x'; rm -rf ~ #", 'a\nb', '$(id)', '`id`', "a'b", 'a b', '-oProxyCommand=x', ';', '&&', '|'];
for (const f of ['repo', 'ref', 'vault']) for (const h of hostile) {
  let out = null; try { out = build({ [f]: h }); } catch (e) { out = null; }
  if (out === null) continue;                                    // refused: fine
  check(!/rm -rf|\$\(id\)|`id`/.test(out.replace(/'(?:[^']|'\\'')*'/g, "''")), `${f}=${JSON.stringify(h)} leaked outside quotes:\n${out}`);
}
for (const h of hostile.concat(['a\\b', '$HOME', '"q"'])) { const r = cp.spawnSync('/bin/bash', ['-c', 'printf %s ' + L.shellQuote(h)]).stdout.toString(); check(r === h, 'shellQuote round trip failed for ' + JSON.stringify(h)); }
for (const h of hostile) { let out = null; try { out = build({ base: 'https://host/' + h }); } catch (e) {} check(out === null, `hostile base path ${JSON.stringify(h)} must be refused`); }
for (const bad of [{ channel: '' }, { channel: 'dev' }, { channel: 'main/../x' }, { channel: 'next\n' }, { channel: ['main'] }, { channel: "main'; x" }, { channel: 'v6.1.0' }, { rawBase: 'http://x/y' }, { rawBase: "https://h/o'; x" }])
  { let ok = true; try { build(bad); } catch (e) { ok = false; } check(!ok, `buildCommand must throw for ${JSON.stringify(bad)}`); }

const full = build({ repo: 'dotFiles', ref: 'v6.1.0', vault: 'My Vault', noOp: true, plan: true });
check(!/SHA256SUMS|\s-O\s/.test(full), 'only spark.sh is downloaded (one -o), no SHA256SUMS: its check can pass vacuously on macOS');
check(full.includes("-o spark.sh 'https://raw.githubusercontent.com/o/spark/refs/heads/main/spark.sh'"), 'spark.sh comes from the tip of refs/heads/main by default');
check(build({ channel: 'main' }) === build({}), 'an explicit main is the default');
check(build({ channel: 'next' }).includes("-o spark.sh 'https://raw.githubusercontent.com/o/spark/refs/heads/next/spark.sh'"), 'channel next comes from refs/heads/next');
check(!/refs\/tags|sha256sum|shasum|SHA256/.test(full), 'nothing is pinned: no tag URL and no digest comparison');
// run the chain for real: a failed download must stop before `bash spark.sh`, a good one lets it run
const chain = (o, curlRc) => { const c = build(o).replace(/^curl [^\n]*(?= &&$)/m, curlRc === 0 ? 'true' : 'false').replace('bash spark.sh', 'echo RAN #'); return cp.spawnSync('/bin/bash', ['-c', c]).stdout.toString(); };
check(!chain({}, 1).includes('RAN'), 'a failed download must stop the chain');
check(chain({}, 0).includes('RAN'), 'a good download lets the chain run');
check(/&&\s*\n?\s*bash spark\.sh/.test(full), 'bash spark.sh must be chained after the check with &&');
check(/--op-vault 'My Vault'/.test(full) && /--no-op/.test(full) && /--plan/.test(full), 'optional flags appear when set');
check(cp.spawnSync('/bin/bash', ['-n'], { input: full }).status === 0, 'the generated command must pass bash -n');
// the quoted args split correctly: replace the downloads and the check, print argv of the spark line
const probe = full.replace(/^[\s\S]*?bash spark\.sh/, 'printf "%s\\n"');
const argv = cp.spawnSync('/bin/bash', ['-c', probe]).stdout.toString().split('\n').filter(Boolean);
check(JSON.stringify(argv) === JSON.stringify(['--base', 'https://host/owner', '--repo', 'dotFiles', '--ref', 'v6.1.0', '--op-vault', 'My Vault', '--no-op', '--plan']), 'argv split wrong: ' + JSON.stringify(argv));

const frag = L.buildFragment({ base: 'ssh://git@host/o', repo: 'dotFiles', ref: 'feat/x', vault: 'My Vault', channel: 'next', noOp: true });
const back = L.parseFragment('#' + frag, P);
check(back.base === 'ssh://git@host/o' && back.vault === 'My Vault' && back.ref === 'feat/x' && back.channel === 'next' && back.noOp === '1', 'fragment round trip: ' + JSON.stringify(back));
check(!L.buildFragment({ base: 'ssh://git@host/o', channel: 'main' }).includes('channel'), 'the default branch is not written to a link');
for (const bad of ['dev', '', 'main/../x', 'NEXT', 'next%0A']) check(!('channel' in L.parseFragment('#channel=' + bad, P)), 'a link cannot select the spark branch ' + JSON.stringify(bad));
check(L.parseFragment('#channel=main', P).channel === 'main', 'a link may select main');
check(Object.keys(L.parseFragment('#evil=1&base=%E0%A4%A&repo=x', P)).join() === 'repo', 'unknown keys and malformed escapes are dropped');
check(L.deriveRawBase({ hostname: 'o.github.io', pathname: '/spark/' }) === 'https://raw.githubusercontent.com/o/spark', 'derive raw base on github.io');
for (const bad of ['/index.html', '/spark.sh', '/.git/', '/-x/', '/x.htm']) check(L.deriveRawBase({ hostname: 'o.github.io', pathname: bad }) === null, 'no derive for a user-site or odd path ' + bad);
check(L.deriveRawBase({ hostname: '', pathname: '/tmp/index.html' }) === null, 'no derive on file://');
check(L.deriveRawBase({ hostname: 'evil.example', pathname: '/x/' }) === null, 'no derive on a foreign host');

check(!/spark-tag|spark-sha256|tag-inline|unstamped/.test(page), 'the page carries no pinned release: no tag or hash meta, no stamped state');
check(!/innerHTML|outerHTML|document\.write|\beval\(|\bfetch\(|XMLHttpRequest|localStorage|sendBeacon/.test(page), 'the page must not use innerHTML, eval, network or storage');
check(!/<script[^>]*\ssrc=|<link[^>]*href=|@import|url\(\s*['"]?https?:/i.test(page), 'the page must load nothing external');
if (fails.length) { console.error(fails.join('\n')); process.exit(1); }
console.log('spark page: patterns identical to spark.sh, bash/JS agree on ' + Object.values(fixtures).flat().length + ' fixtures, logic checks pass');
