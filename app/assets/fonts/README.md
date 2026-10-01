# Local font assets

Fetched 2026-09-28 from the official Google Fonts CSS API and fonts.gstatic.com.
These are build inputs: the browser never calls Google. esbuild emits hashed WOFF2
files under `priv/static/assets/fonts/`; CSS resolves them on the same origin.

- `google-sans-flex-latin.woff2`: Google Sans Flex variable, Latin, weights 300–700.
  Google Fonts family `Google Sans Flex`, API v22. License: OFL-GoogleSansFlex.txt.
- `roboto-latin.woff2`, `roboto-cyrillic.woff2`: Roboto variable, Latin/Cyrillic,
  weights 300–700. Google Fonts family `Roboto`, API v51. License: OFL-Roboto.txt.
- `material-symbols-rounded-ui.woff2`: Material Symbols Rounded v375, five glyphs
  (`add`, `arrow_forward`, `contrast`, `expand_more`, `logout`), opsz=24, wght=400,
  FILL=0, GRAD=0. Apache 2.0: LICENSE-MaterialSymbols.txt from the official
  https://github.com/google/material-design-icons repository.

Google Sans Flex does not provide Cyrillic. The approved heading stack falls back
to local Roboto for Russian; the same Roboto files serve body text. Arial/sans-serif
remain emergency fallbacks when a font fails to load. Icons reserve 24px and stay
hidden until their font loads; their controls keep independent accessible names.
This subset does not yet contain the future rating star (U+E838).

Reproducible source queries (modern Chrome user-agent to request WOFF2):

```
https://fonts.googleapis.com/css2?family=Google+Sans+Flex:wght@300;500&family=Roboto:wght@400;500&display=swap&subset=cyrillic,latin
https://fonts.googleapis.com/css2?family=Material+Symbols+Rounded:opsz,wght,FILL,GRAD@24,400,0,0&icon_names=add,arrow_forward,contrast,expand_more,logout&display=block&subset=latin
```

Pinned file SHA-256 (changing the query later can return another upstream version):

```
4f2ce47af77a0bb9ec3dbd2e81bab7eb97fbcfcd94e47fa63510bb4271b09113  google-sans-flex-latin.woff2
481dd0c01e6bbb129fd147eb5d8571016193cba141c4627ca60ceabdb5a46ea8  roboto-cyrillic.woff2
1404ca348bd75ef836f4dd8b6f2cc719458642d1237c368296b2fc652dca47dc  roboto-latin.woff2
2e17ac42258eede34b7558013da12c33fd8a792a0c5883f0d82b81a704c4a8cc  material-symbols-rounded-ui.woff2
```

Keep license notices when distributing these fonts. No extra JS dependency,
package.json, font tooling or external runtime connection is needed to build.
