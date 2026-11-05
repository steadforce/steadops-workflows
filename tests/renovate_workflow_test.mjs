import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const moduleRoot = process.env.RENOVATE_MODULE_ROOT;
assert.ok(moduleRoot, 'Set RENOVATE_MODULE_ROOT to the installed renovate package');
const { GlobalConfig } = await import(pathToFileURL(`${moduleRoot}/dist/config/global.js`));
const { extractPackageFile } = await import(pathToFileURL(`${moduleRoot}/dist/modules/manager/github-actions/extract.js`));
const { compile } = await import(pathToFileURL(`${moduleRoot}/dist/util/template/index.js`));
GlobalConfig.set({ localDir: root, platform: 'github' });

const guide = await readFile(new URL('../docs/renovate-rollout.md', import.meta.url), 'utf8');
const example = guide.split('## Caller Workflow')[1].split('```yaml\n')[1].split('```')[0];
const digest = 'a'.repeat(40);
const nextDigest = 'b'.repeat(40);
const packageFile = '.github/workflows/label-renovate-hydration.yaml';

for (const version of ['add-label-renovate-hydration-workflow', 'v4.4.0']) {
  const caller = example.replaceAll('<release-sha>', digest).replaceAll('<release-version>', version);
  assert.ok(!caller.includes('workflows-ref:'));
  const extracted = await extractPackageFile(caller, packageFile);
  const dependencies = extracted.deps.filter(dependency => dependency.depName === 'steadforce/steadops-workflows');
  assert.equal(dependencies.length, 1);
  const dependency = dependencies[0];
  assert.equal(dependency.currentDigest, digest);
  assert.equal(dependency.currentValue, version);
  assert.equal(dependency.skipReason, undefined);
  assert.notEqual(dependency.enabled, false);
  assert.equal(dependency.depType, 'workflow');
  assert.equal(dependency.datasource, version.startsWith('v') ? 'github-tags' : 'github-digest');
  const nextVersion = version.startsWith('v') ? 'v4.5.0' : version;
  const replacement = compile(dependency.autoReplaceStringTemplate, {
    ...dependency, newDigest: nextDigest, newValue: nextVersion,
  });
  const updated = caller.replace(dependency.replaceString, replacement);
  const updatedDependencies = (await extractPackageFile(updated, packageFile)).deps;
  const updatedDependency = updatedDependencies.find(item => item.depName === dependency.depName);
  assert.equal(updatedDependency.currentDigest, nextDigest);
  assert.equal(updatedDependency.currentValue, nextVersion);
  assert.ok(!updated.includes('workflows-ref:'));
}

const bareCaller = example.replaceAll('<release-sha>', digest).replace(' # <release-version>', '');
const bareDependency = (await extractPackageFile(bareCaller, packageFile)).deps.find(item => item.depName === 'steadforce/steadops-workflows');
assert.equal(bareDependency.skipReason, 'unversioned-reference');
console.log('Native Renovate extracts and updates the single branch/tag workflow pin; bare SHAs are rejected');