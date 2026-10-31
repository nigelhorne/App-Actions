# App::Actions website

Static pages for App::Actions. No scripts, no external fonts, no CDN: the
pages need nothing but the files here.

## Deploying on Apache

Copy this whole `website` directory into the server's document root:

    cp -r website /var/www/html/app-actions

Then browse to `http://host/app-actions/` — the `index.html` at the top of the
directory redirects to `html/index.html`. Every link is relative, so the site
also works if the document root is this directory itself, or `website/html`.

If the server does not already do so, `DirectoryIndex index.html` (the Apache
default) is all that is required. Nothing needs CGI, PHP, rewrites or modules.

## Layout

- `html/` — the pages, linked to each other by file name.
- `css/site.css` — one stylesheet, referenced as `../css/site.css`.
- `index.html` — redirect to `html/index.html`.

The pages are hand-written HTML. The version, release date and links in the
header and footer are repeated in each page, so a version bump means editing
every page's footer.
