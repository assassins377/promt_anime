import {render} from '../deploy/nginx/render-minio-cors.mjs';
import {mkdtempSync, writeFileSync, chmodSync} from 'node:fs';
import {execFileSync, spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {request as httpRequest} from 'node:http';
import assert from 'node:assert/strict';

const image = 'nginx@sha256:7068961d45b07b2af510ac002e9daa63a1d3eba2111202d6768798690800fffd';
const env = {SITE_ORIGIN: 'https://anime.example', MINIO_PUBLIC_HOST: 'storage.example', MINIO_UPSTREAM: '127.0.0.1:8081'};
const dir = mkdtempSync('/tmp/anime-cors-check.');
chmodSync(dir, 0o700);
let id;
let child;
let nativePort;
let upstreamPort;
let checks = 0;
const docker = (...args) => execFileSync('docker', args, {encoding: 'utf8', timeout: 30000}).trim();
async function freePort() {
  const s=createServer();
  await new Promise((resolve,reject)=>{s.once('error',reject);s.listen(0,'127.0.0.1',resolve);});
  const port=s.address().port;
  await new Promise(resolve=>s.close(resolve));
  return port;
}
try {
  for (const invalid of [
    {SITE_ORIGIN:'*'}, {SITE_ORIGIN:'https://anime.example/path'},
    {SITE_ORIGIN:'https://u:p@anime.example'}, {MINIO_UPSTREAM:'host:9000;evil'},
    {MINIO_PUBLIC_HOST:'host;evil'}, {MINIO_BUCKET_VIDEO:'bad.name'},
    {MINIO_BUCKET_VIDEO:'anime-originals'}, {MINIO_UPSTREAM:'host:99999'}
  ]) { assert.throws(() => render({...env,...invalid})); checks++; }
  assert.match(render({...env, MINIO_BUCKET_VIDEO:'custom-video'}), /custom-video/); checks++;
  if (process.env.NGINX_BIN) {
    nativePort=await freePort(); upstreamPort=await freePort();
    env.MINIO_UPSTREAM=`127.0.0.1:${upstreamPort}`;
  }
  let config = `pid /tmp/nginx.pid;
error_log /dev/null crit;
events {}
http {
access_log off;
client_body_temp_path /tmp/body;
proxy_temp_path /tmp/proxy;
fastcgi_temp_path /tmp/fastcgi;
uwsgi_temp_path /tmp/uwsgi;
scgi_temp_path /tmp/scgi;
${render(env)}
server {
listen 8081;
location / {
add_header Access-Control-Allow-Origin "*" always;
add_header Access-Control-Allow-Credentials "true" always;
add_header ETag '"synthetic-etag"' always;
if ($uri ~ denied) { return 403; }
return 200 "$request_method|$request_uri|$http_host|$http_range";
}
}
}`;
  if (process.env.NGINX_BIN) config=config.replaceAll('/tmp/',dir+'/')
    .replace('listen 8080;',`listen 127.0.0.1:${nativePort};`)
    .replace('listen 8081;',`listen 127.0.0.1:${upstreamPort};`);
  writeFileSync(`${dir}/nginx.conf`, config, {mode:0o644});
  let base;
  if (process.env.NGINX_BIN) {
    const args=['-p',dir,'-c',`${dir}/nginx.conf`,'-e','stderr'];
    execFileSync(process.env.NGINX_BIN,[...args,'-t']); checks++;
    child=spawn(process.env.NGINX_BIN,[...args,'-g','daemon off;'],{stdio:'ignore'});
    base=`http://127.0.0.1:${nativePort}`;
    let ready=false;
    for(let attempt=0;attempt<30;attempt++) {
      try {await fetch(base,{signal:AbortSignal.timeout(100)});ready=true;break;} catch {await new Promise(r=>setTimeout(r,50));}
    }
    assert.ok(ready,'native nginx started');
  } else {
  const options = ['--pull=never','--user=1000:1000','--read-only','--cap-drop=ALL',
    '--security-opt=no-new-privileges','--tmpfs=/tmp:rw,noexec,nosuid,size=16m',
    '-e',`ANIME_CONF_B64=${Buffer.from(config).toString('base64')}`];
  const prepare = 'printf "%s" "$ANIME_CONF_B64" | base64 -d > /tmp/nginx.conf; ';
  docker('run','--rm',...options,'--entrypoint=sh',image,'-c',prepare+'exec nginx -c /tmp/nginx.conf -t'); checks++;
  id = docker('run','--rm','-d',...options,'-p','127.0.0.1::8080','--entrypoint=sh',image,'-c',prepare+"exec nginx -c /tmp/nginx.conf -g 'daemon off;'");
  const binding = JSON.parse(docker('inspect',id))[0].NetworkSettings.Ports['8080/tcp'][0];
  base = `http://127.0.0.1:${binding.HostPort}`;
  }
  async function request(path, method, origin, extra = {}) {
    const headers = {Host:'storage.example',...extra};
    if (origin !== undefined) headers.Origin = origin;
    return new Promise((resolve,reject)=>{
      const req=httpRequest(base+path,{method,headers,signal:AbortSignal.timeout(3000)},res=>{
        let body=''; res.setEncoding('utf8');res.on('data',chunk=>body+=chunk);
        res.on('end',()=>resolve({status:res.statusCode,headers:new Headers(res.headers),body}));
      });
      req.on('error',reject);req.end();
    });
  }
  for (const [bucket,method] of [['anime-originals','PUT'],['anime-video','GET'],['anime-previews','GET']]) {
    const pre = await request(`/${bucket}/item`,'OPTIONS',env.SITE_ORIGIN,{
      'Access-Control-Request-Method':method,'Access-Control-Request-Headers':'content-type, range'});
    assert.equal(pre.status,204); assert.equal(pre.headers.get('access-control-allow-origin'),env.SITE_ORIGIN); checks++;
    const actual = await request(`/${bucket}/item?X-Amz-Signature=synthetic%2Btoken`,method,env.SITE_ORIGIN,{Range:'bytes=0-9'});
    assert.equal(actual.status,200);
    assert.equal(actual.headers.get('access-control-allow-origin'),env.SITE_ORIGIN);
    assert.equal(actual.headers.get('access-control-allow-credentials'),null);
    assert.match(actual.body,/X-Amz-Signature=synthetic%2Btoken\|storage.example\|bytes=0-9$/); checks++;
  }
  for (const [path,method,origin,headers] of [
    ['/anime-video/item','GET','https://evil.example',{}],
    ['/anime-video/item','GET','null',{}],
    ['/anime-originals/item','OPTIONS',env.SITE_ORIGIN,{'Access-Control-Request-Method':'POST'}],
    ['/anime-video/item','OPTIONS',env.SITE_ORIGIN,{'Access-Control-Request-Method':'PUT'}],
    ['/anime-posters/item','OPTIONS',env.SITE_ORIGIN,{'Access-Control-Request-Method':'GET'}],
    ['/anime-avatars/item','OPTIONS',env.SITE_ORIGIN,{'Access-Control-Request-Method':'GET'}],
    ['/unknown/item','OPTIONS',env.SITE_ORIGIN,{'Access-Control-Request-Method':'GET'}],
    ['/anime-video/item','OPTIONS',env.SITE_ORIGIN,{'Access-Control-Request-Method':'GET','Access-Control-Request-Headers':'Authorization'}],
    ['/anime-video/item','OPTIONS',undefined,{'Access-Control-Request-Method':'GET'}]
  ]) {
    const r=await request(path,method,origin,headers);
    assert.equal(r.status,403); assert.equal(r.headers.get('access-control-allow-origin'),null); checks++;
  }
  const noOrigin=await request('/anime-posters/item','GET');
  assert.equal(noOrigin.status,200); assert.equal(noOrigin.headers.get('access-control-allow-origin'),null); checks++;
  const denied=await request('/anime-video/denied','GET',env.SITE_ORIGIN);
  assert.equal(denied.status,403); assert.equal(denied.headers.get('access-control-allow-origin'),env.SITE_ORIGIN); checks++;
  writeFileSync(`${dir}/result.json`,JSON.stringify({checks,engine:process.env.NGINX_BIN || image,result:'pass',scope:'nginx with synthetic upstream, not MinIO'},null,2));
  console.log(`${checks} checks passed; evidence: ${dir}`);
} finally {
  if (id) docker('stop',id);
  if (child && child.exitCode === null) {
    const stopped=new Promise(resolve=>child.once('exit',resolve));
    child.kill('SIGTERM');
    const timer=setTimeout(()=>child.kill('SIGKILL'),5000);
    await stopped; clearTimeout(timer);
  }
  console.log(`Evidence retained: ${dir}`);
}
