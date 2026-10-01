# Сторонние ресурсы

## Alpine.js

Версия 3.15.0, `assets/vendor/alpine.esm.js`. Исходник из публичного npm-пакета `alpinejs`;
проект: https://github.com/alpinejs/alpine . MIT, текст в `assets/vendor/ALPINE-LICENSE.txt`.
SHA-256: `5ea325715a3e9616a6dd4dbdbdc5f2db273763a8607a2f16379715dbb9ad61c2`.
Собирается локально через esbuild, CDN в приложении не используется.

## Список частых паролей

`priv/passwords/top10000.txt` — SecLists, файл
https://github.com/danielmiessler/SecLists/blob/master/Passwords/Common-Credentials/10k-most-common.txt .
MIT, текст в `priv/passwords/LICENSE.txt`. Получен 28 сентября 2026.
SHA-256: `68782d6a4a19a4768d5f15dd66bd534e7a33055cc755411e33f16d18c50fdcce`.
Исходник фактически содержит 10001 строку; сохранён целиком, имя upstream не является
утверждением о точном числе строк. Приложение не загружает его по сети во время работы.

## Шрифты

Локальные WOFF2 Google Sans Flex и Roboto — SIL OFL 1.1; подмножество Material Symbols
Rounded — Apache 2.0. Лицензии, источники, параметры подмножеств и SHA-256 находятся
в [assets/fonts/README.md](assets/fonts/README.md). Файлы собирает esbuild,
браузер обращается только к самому сайту. Кириллица заголовков использует Roboto.

Остальные зависимости закреплены `mix.lock`; лицензии находятся в соответствующих Hex-пакетах.
