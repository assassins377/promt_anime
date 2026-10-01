# MinIO Community: CORS на nginx

Решение пользователя от 1 октября: обычный MinIO сохраняется; BucketCORS API
не используется. `storage_setup` отвечает за бакеты, приватность и lifecycle,
а CORS — отдельная конфигурация nginx. storage_setup реализован отдельно;
правила применения и границы — [STORAGE_SETUP.md](../STORAGE_SETUP.md).

## Подготовка конфигурации

`node deploy/nginx/render-minio-cors.mjs` печатает http-context include в stdout.
Параметры окружения:

- SITE_ORIGIN: точный origin сайта, например https://anime.example, без / в конце.
- MINIO_PUBLIC_HOST: публичный DNS-хост подписанных адресов, например storage.example.
- MINIO_UPSTREAM: внутренний адрес MinIO с портом, например minio:9000.
- MINIO_BUCKET_ORIGINALS/VIDEO/PREVIEWS/POSTERS/AVATARS: по умолчанию anime-*.
  Здесь поддерживаются имена из строчных латинских букв, цифр и дефисов, 3–63 символа;
  они должны различаться. Точки намеренно не принимаются (имена входят в regex).

Генератор не читает .env и не меняет службы/хранилище. Вывод сохранить в файл,
включить внутри http, выполнить nginx -t, затем отдельно согласовать reload.
Node нужен только для генерации и тестов, не для сборки Phoenix или nginx runtime.

## Граница применения

Это внутренний HTTP listener 8080 за TLS-прокси, не законченный TLS virtual host.
Прямые порты MinIO и этот listener нельзя публиковать в обход внешнего TLS-входа.
Последний должен сохранять исходный Host с портом и исходный URI: S3-подписи
выписываются на публичный адрес хранилища. Внешний вход не должен добавлять
свои CORS-заголовки. Virtual-host-style S3 не поддержан: используется /bucket/key.
MINIO_UPSTREAM обязан быть внутренним; шаблон не задаёт TLS до upstream.

POST multipart идёт от сервера; браузеру для originals разрешён только PUT.
video/previews — GET с Range; другие бакеты CORS-разрешения не получают.
Origin null, чужой origin и недопустимый preflight дают 403. Без Origin запрос
проксируется, но разрешающий Allow-Origin отсутствует. Это не авторизация:
MinIO по-прежнему проверяет подпись и приватную bucket policy.

Все разрешающие CORS-заголовки upstream скрыты, поэтому глобальные настройки
MinIO не расширяют разрешения nginx. Нет Allow-Credentials и wildcard origin.
Access log выключен, error log подавлен: подписанные query не должны попадать
в журналы. Безопасное производственное логирование без секретов ещё требует
отдельной настройки; не включать стандартный combined на этом listener.

## Повторяемая проверка

`node dev/check_minio_cors.mjs` использует уже имеющийся nginx-образ с digest,
не скачивает его и не трогает существующие контейнеры. Альтернатива без Docker:
`NGINX_BIN=/absolute/path/to/nginx node dev/check_minio_cors.mjs`.
Native режим использует случайные loopback-порты и останавливает свой процесс.
Конфигурация и result.json сохраняются в приватном /tmp/anime-cors-check.*.

1 октября: nginx 1.28.3 из распакованного Ubuntu-пакета (без установки службы),
27 сценариев прошли, `/tmp/anime-cors-check.zrN1vc`. Проверены валидация параметров,
nginx -t, OPTIONS/PUT/GET, Range, Host и неэкранированная повторно query,
запрещённые origin/методы/заголовки/бакеты, отсутствие CORS у запросов без Origin,
передача ошибки 403 upstream и подавление его wildcard/Allow-Credentials.

Docker-прогон в этой среде не принят: сначала daemon не видел bind mount,
затем отказал exec /bin/sh. Защита не ослаблялась. Проверка работает с
синтетическим upstream: реальные S3-подписи, MinIO, TLS и сетевые запреты
обхода прокси не проверяются этим stub-прогоном.

## Интеграция с настоящим MinIO

Локальная TLS-цепочка отдельно проверена: [TLS_CHECK.md](TLS_CHECK.md).
Это не публичный домен и не производственное TLS-развёртывание.

Повторный stub-прогон 1 октября: jXobpL, все 27 сценариев прошли.

`bash dev/check_storage_local.sh /absolute/path/to/minio /tmp/anime-release-check.XXXXXXXX/package /absolute/path/to/nginx`

Третий аргумент включает настоящий nginx перед новым MinIO. Используется тот же
renderer и шаблон, меняется только listener на loopback 59440. MinIO занимает
59438/59439; при занятом порте runner отказывает. Оба процесса останавливаются
при выходе; существующие службы, данные и .env не используются.

1 октября: `/tmp/anime-storage-check.sGAihAFg`, exit 0; nginx 1.28.3,
MinIO RELEASE.2025-09-07T16-13-09Z, релиз qZTQ51we. Прошли базовый storage smoke
и реальные S3-подписи через прокси: GET/Range для video/previews, ключи с кириллицей,
пробелами, плюсом и процентом; сохранение Host с портом; запрет чужого Origin,
анонимного запроса и подмены query, CORS на отказе MinIO. Multipart: создание
на сервере, OPTIONS и подписанный PUT через nginx, доступность ETag, завершение
на сервере и проверка содержимого. Приложение и БД не запускались.

Это HTTP-интеграция на loopback, не тест браузерного плеера. TLS, публичный DNS,
сетевой запрет обхода прокси, ограниченная IAM-роль и истечение сроков lifecycle
остаются открыты. Временные ключи root используются только внутри fixture.

Основания: [ограничения MinIO Community](https://github.com/minio/minio/blob/master/docs/minio-limits.md),
[proxy_pass и proxy_hide_header](https://nginx.org/en/docs/http/ngx_http_proxy_module.html),
[add_header always](https://nginx.org/en/docs/http/ngx_http_headers_module.html).
