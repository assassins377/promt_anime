// This tool ONLY configures users in the newly launched local fixture.
import {policies} from '../deploy/minio/iam-policies.mjs';
import {writeFileSync, mkdirSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import assert from 'node:assert/strict';
const [dir, mc] = process.argv.slice(2);
assert.match(dir, /^\/tmp\/anime-storage-check\.[a-zA-Z0-9]+$/);
assert.ok(mc?.startsWith('/'));
assert.throws(() => policies({MINIO_BUCKET_VIDEO:'bad/name'}));
assert.throws(() => policies({MINIO_BUCKET_VIDEO:'anime-originals'}));
assert.match(JSON.stringify(policies({MINIO_BUCKET_VIDEO:'custom-video'}).reader), /custom-video/);
mkdirSync(`${dir}/mc`, {mode:0o700});
const env = {PATH:'/usr/bin:/bin', MC_HOST_fixture:`http://${process.env.MINIO_ACCESS_KEY_ID}:${process.env.MINIO_SECRET_ACCESS_KEY}@127.0.0.1:59438`};
const invoke = (...args) => {
  try {return execFileSync(mc, ['--config-dir',`${dir}/mc`,...args], {env, stdio:'pipe', timeout:15000});}
  catch {throw new Error(`Fixture mc failed: ${args.slice(0,3).join(' ')}`);}
};
const credentials = {};
for (const [role, policy] of Object.entries(policies())) {
  const path = `${dir}/${role}.json`;
  writeFileSync(path, JSON.stringify(policy), {mode:0o600});
  const key = `probe${role}${randomBytes(4).toString('hex')}`;
  const secret = randomBytes(32).toString('hex');
  invoke('admin','user','add','fixture',key,secret);
  invoke('admin','policy','create','fixture',`probe-${role}`,path);
  invoke('admin','policy','attach','fixture',`probe-${role}`,'--user',key);
  credentials[role] = {key,secret};
}
writeFileSync(`${dir}/credentials.json`, JSON.stringify(credentials), {mode:0o600});
// Root only creates a sentinel outside the application's five buckets.
invoke('mb','fixture/foreign-fixture');
const marker=`${dir}/marker.txt`;
writeFileSync(marker,'foreign-sentinel',{mode:0o600});
invoke('cp',marker,'fixture/foreign-fixture/sentinel.txt');
console.log('Created three isolated restricted identities and a foreign sentinel.');
