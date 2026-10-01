#!/usr/bin/env bash
# Private, one-run CA. Never imported into OS/browser trust stores.
set -Eeuo pipefail
[[ $# == 1 && $1 =~ ^/tmp/anime-storage-check\.[a-zA-Z0-9]+$ && -d $1 ]] || exit 2
umask 077
dir=$1
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=Anime fixture CA' \
  -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -keyout "$dir/ca.key" -out "$dir/ca.crt"
openssl req -newkey rsa:2048 -nodes -subj '/CN=localhost' \
  -addext 'subjectAltName=DNS:localhost' \
  -keyout "$dir/server.key" -out "$dir/server.csr"
openssl x509 -req -in "$dir/server.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" \
  -CAcreateserial -days 1 -copy_extensions copy -out "$dir/server.crt"
openssl verify -CAfile "$dir/ca.crt" -verify_hostname localhost "$dir/server.crt"
