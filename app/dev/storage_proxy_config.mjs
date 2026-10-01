// Only a loopback fixture, using the real deployment renderer unchanged.
import {render} from '../deploy/nginx/render-minio-cors.mjs';
import {writeFileSync} from 'node:fs';
const dir=process.argv[2];
const tls=process.argv[3] === '1';
if (!/^\/tmp\/anime-storage-check\.[a-zA-Z0-9]+$/.test(dir || '')) throw new Error('Invalid fixture directory');
const server=render({SITE_ORIGIN:'https://anime.example', MINIO_PUBLIC_HOST:'127.0.0.1', MINIO_UPSTREAM:'127.0.0.1:59438'})
  .replace('listen 8080;', 'listen 127.0.0.1:59440;');
writeFileSync(`${dir}/nginx.conf`, `pid ${dir}/nginx.pid;
error_log ${dir}/nginx-error.log crit;
events {}
http {
access_log off;
client_body_temp_path ${dir}/body;
proxy_temp_path ${dir}/proxy;
fastcgi_temp_path ${dir}/fastcgi;
uwsgi_temp_path ${dir}/uwsgi;
scgi_temp_path ${dir}/scgi;
${server}
${tls ? `server {
listen 127.0.0.1:59441 ssl;
server_name localhost;
ssl_certificate ${dir}/server.crt;
ssl_certificate_key ${dir}/server.key;
ssl_protocols TLSv1.2 TLSv1.3;
access_log off;
error_log /dev/null crit;
location / {
proxy_set_header Host $http_host;
proxy_http_version 1.1;
proxy_set_header Connection "";
proxy_buffering off;
proxy_request_buffering off;
proxy_pass http://127.0.0.1:59440;
}
}` : ''}
}
`, {mode:0o600});
