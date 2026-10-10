# tinyfly (vendored)

`tinyfly.iife.js` is the unmodified `cdn/tinyfly.iife.js` from
[algorisys-oss/tinyfly](https://github.com/algorisys-oss/tinyfly) at tag
`v0.62.0`, MIT licensed (see `LICENSE`). It animates the festive petals and is
only requested while a festival in `web/src/festivals.ts` is active.

Committed rather than fetched at build time, so the site adds no third-party
origin. To move to a new release, from `web/`:

```bash
V=v0.62.0
curl -fsSL -o public/vendor/tinyfly/tinyfly.iife.js https://cdn.jsdelivr.net/gh/algorisys-oss/tinyfly@$V/cdn/tinyfly.iife.js
curl -fsSL -o public/vendor/tinyfly/LICENSE https://cdn.jsdelivr.net/gh/algorisys-oss/tinyfly@$V/LICENSE
```

Then update the tag above and run `npm run build && npm run e2e`.
