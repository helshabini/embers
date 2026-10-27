# The Embers website

A static site — HTML, one stylesheet, two small scripts, no build step and no server. It holds
what the App Store listing needs to point at: the product page, the **privacy policy**
(`privacy.html`, the listing's Privacy Policy URL), the **support page** (`support.html`, its
Support URL) and the license.

Preview it with `python3 -m http.server -d web 8000`. Host it anywhere that serves a folder:
Cloudflare Pages, Netlify, or GitHub Pages through an Actions workflow that publishes `web/`
(Pages' branch mode can only serve `/` or `/docs`, and `docs/` is the wiki).

## What is still a placeholder

| What | Where |
|---|---|
| App Store and Mac App Store links | `EMBERS_STORE` in `assets/store-links.js`. Empty, the buttons read "Soon" and go nowhere; filled, every button on every page works. Also uncomment `apple-itunes-app` in `index.html` for Safari's install banner |
| GitHub repository | `EMBERS_REPO` in `assets/store-links.js` (`"owner/name"`). It rewrites every GitHub link and turns on the star count in the header |
| The domain | `https://getembers.app` in every page's canonical and Open Graph tags, `robots.txt` and `sitemap.xml` |
| Support address | `support@getembers.app` in `privacy.html` and `support.html` |

The store buttons are drawn in the site's own style. Apple's guidelines ask for its official
"Download on the App Store" badges, from Apple's marketing resources, once the app is listed.

## The theme

Colours are the app's (`Shared/Theme.swift`, `Flame`), as custom properties at the top of
`assets/site.css`. The page opens light; the toggle stores a choice of dark in `localStorage`, and
an inline snippet in each page's `<head>` applies it before the first paint. Every screenshot
exists in both appearances and the page shows the one matching its own theme.

## Screenshots

`web/screenshots/` holds compressed copies of the originals in `/screenshots`. See
[../screenshots/README.md](../screenshots/README.md) for how they are made; after replacing them:

```bash
for f in screenshots/iphone/*/*.png; do
  sips -Z 1500 -s format jpeg -s formatOptions 80 "$f" \
    --out "web/screenshots/$(basename "$(dirname "$f")")/$(basename "$f" .png).jpg"
done
```
