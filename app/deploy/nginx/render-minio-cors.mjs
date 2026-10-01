import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';

export function render(env) {
  const origin = env.SITE_ORIGIN;
  const parsed = new URL(origin);
  if (!['http:', 'https:'].includes(parsed.protocol) || parsed.origin !== origin ||
      !/^https?:\/\/[a-zA-Z0-9.-]+(?::[0-9]+)?$/.test(origin)) throw new Error('Invalid SITE_ORIGIN');
  const host = env.MINIO_PUBLIC_HOST;
  const upstream = env.MINIO_UPSTREAM;
  if (!/^[a-zA-Z0-9.-]+$/.test(host || '')) throw new Error('Invalid MINIO_PUBLIC_HOST');
  if (!/^[a-zA-Z0-9.-]+:[0-9]+$/.test(upstream || '') ||
      +upstream.split(':')[1] < 1 || +upstream.split(':')[1] > 65535) throw new Error('Invalid MINIO_UPSTREAM');
  const values = {ORIGIN: origin, HOST: host, UPSTREAM: upstream};
  const buckets = ['ORIGINALS','VIDEO','PREVIEWS','POSTERS','AVATARS'];
  const names = buckets.map(key => {
    const name = env[`MINIO_BUCKET_${key}`] || `anime-${key.toLowerCase()}`;
    if (!/^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/.test(name)) throw new Error(`Invalid MINIO_BUCKET_${key}`);
    values[key] = name;
    return name;
  });
  if (new Set(names).size !== names.length) throw new Error('Bucket names must differ');
  return readFileSync(new URL('./minio-cors.conf.template', import.meta.url), 'utf8')
    .replace(/@@([A-Z]+)@@/g, (_, key) => values[key]);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try { process.stdout.write(render(process.env)); }
  catch { console.error('Invalid CORS configuration; check origin, host, upstream and bucket names.'); process.exitCode = 2; }
}
