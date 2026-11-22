# SolidityBridge Docs

This static website builds from the public SolidityBridge developer guide in `content/DEVELOPERS.md`. The site uses Python 3.9+ and plain CSS and JavaScript. It has no package installation step.

Run `python3 build.py`, then open `dist/index.html`. To preview with a local HTTP server, run `python3 -m http.server 8080 --directory dist`.

When editing the integration guide in the parent SolidityBridge project, copy `../Docs/DEVELOPERS.md` into `content/DEVELOPERS.md` before rebuilding. The content directory also carries the two example sources linked by the guide. Refresh them from the package when the examples change.

## Edit the wiki

The source for this website is `content/DEVELOPERS.md`. Edit it in a text editor or use the pencil icon on GitHub. Open a pull request to review changes before merging into `master`. Git stores the history of each edit. Existing top-level headings map to the pages listed in `GROUPS` in `build.py`. To add a page, add a matching entry in both places. The build regenerates the HTML and search index together.

## Deploy automatically with GitHub Pages

1. Keep this directory in the SolidityBridge repository alongside the root `.github/workflows/pages.yml` workflow.
2. Open **Settings → Pages** and set **Source** to **GitHub Actions**.
3. Run **Publish documentation** from the **Actions** tab for the first deployment, or push a change to `master`. The workflow builds the site and publishes `dist/`. Its deployment output shows the site URL.
4. Merge further documentation changes into `master` to update the same site.

Check the site's visibility in the Pages settings before using it for private content. The wiki's build input is the developer guide in this directory.

## Deploy on your own server

Run `python3 build.py` locally or in CI. Upload the contents of `dist/` to the document root for the site's domain, or to a subdirectory such as `docs/`. Keep the `assets/` and `examples/` directories alongside `index.html`. Serve the files with HTTPS. On each update, rebuild and upload the new output. If your host accepts SSH, you can use `rsync -av dist/ user@host:/path/to/document-root/` with your actual host and document root. The site only needs static file hosting.
