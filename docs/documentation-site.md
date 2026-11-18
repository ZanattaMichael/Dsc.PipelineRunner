# Documentation site

The README, the guides under `docs/`, the wiki pages under `WikiSource/` and the generated command
reference are published together as one searchable site:

**<https://zanattamichael.github.io/Dsc.PipelineRunner/>**

The site is a view of the files in this repository. Nothing is written for the site alone: edit
the README, a guide or a wiki page, and the site follows on the next push to `main`.

## What is on the site

| Section of the site | Built from |
| --- | --- |
| Home | `README.md` |
| Getting started, Guides | `docs/*.md`, plus the first two wiki pages |
| Reference (wiki) | `WikiSource/*.md`, in the order `WikiSource/.pageorder` declares, and the command reference that `scripts/Build-WikiContent.ps1` generates from each exported command's comment-based help |
| Project | `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md` and this page |
| Images | `assets/` |

The wiki pages stay the source of the GitHub wiki as well. The site compiles the wiki content
only to put the command reference on the site; the wiki itself is still published by the Release
workflow and gated per pull request by the Wiki workflow, exactly as
[Contributing to the wiki](../WikiSource/Contributing.md) describes.

## How it is built

1. `tools/build-site.js` assembles the site source into `site-src/` (ignored by git): the pages
   are copied under `guides/` and `wiki/`, every link is rewritten so it works from inside the
   site, and the README's `<picture>` header becomes one image per colour scheme, so the header
   follows the site's own light/dark toggle instead of the operating system.
2. `mkdocs build --strict` renders `site-src/` into `site/` with
   [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/), configured in
   `mkdocs.yml`: the logo and favicon, light and dark palettes in the logo's colours
   (`assets/site.css`), grouped navigation, search and copy buttons on code blocks.

Links are rewritten by these rules, and `tools/build-site.test.js` holds an example of each:

| A relative link to | Becomes |
| --- | --- |
| another page of the site (`README.md`, `docs/*.md`, `WikiSource/*.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`), with or without an anchor | a link to that page |
| a wiki page by name, `[Engines](Engines)`, as the GitHub wiki resolves it | a link to that page |
| a file under `assets/` | the file, which is copied onto the site |
| a folder | the folder on GitHub |
| any other file (source, scripts, workflows, examples, the licence) | the file on GitHub |
| something that does not exist in the repository | a build error |

Absolute URLs and bare anchors are left as they are, including links to the
[Dsc.PipelineRunnerActions](https://github.com/ZanattaMichael/Dsc.PipelineRunnerActions)
repository and to the GitHub wiki.

Strict mode means a warning fails the build: a link to a page that is not there, an anchor that
no heading produces, or a page missing from the navigation. A broken link in any of the source
files therefore fails the pull request that introduces it, not the deployment.

## Workflows

| Workflow | Runs | Does |
| --- | --- | --- |
| `.github/workflows/Docs-Site.yml` | every pull request and push to `main` | runs the unit tests of `tools/build-site.js`, builds the site in strict mode and uploads it as the `docs-site` artifact |
| `.github/workflows/Pages.yml` | pushes to `main` that touch anything the site is built from, and on demand | builds the site the same way and publishes it to GitHub Pages with `actions/configure-pages`, `actions/upload-pages-artifact` and `actions/deploy-pages` |

Both workflows build the wiki content first (PowerShell ships on the hosted runner) so the command
reference is on the site. Without it, `tools/build-site.js` writes a command reference page that
points at the GitHub wiki instead, so the site still builds on a machine without PowerShell.

## One-time setting: publish from GitHub Actions

GitHub Pages has two sources. **Deploy from a branch** has GitHub render the branch itself with
Jekyll: the README becomes the only real page, with the raw GitHub theme, no navigation, wiki-style
links that go nowhere, and a header that switches to the dark artwork on a light page whenever the
reader's operating system prefers dark mode. **GitHub Actions** publishes whatever the Pages
workflow uploads, which is this site.

A repository administrator sets it once:

1. Open the repository's **Settings > Pages**.
2. Under **Build and deployment**, set **Source** to **GitHub Actions**.

Until that is done, the Pages workflow's deploy job fails with a message saying the site is not
configured for Actions, and the branch rendering stays as it was. The setting is not in any file,
so it is not part of a pull request.

## Building the site locally

```powershell
pip install --requirement tools/site-requirements.txt            # Material for MkDocs, pinned
./scripts/Build-WikiContent.ps1 -SourcePath $PWD -OutputPath ./output/WikiContent   # optional
node tools/build-site.js --wiki-content output/WikiContent         # or without --wiki-content
mkdocs serve                                                       # http://127.0.0.1:8000/Dsc.PipelineRunner/
mkdocs build --strict                                              # what CI runs
node --test tools/build-site.test.js                               # the builder's unit tests
```

## Adding a page

- **A guide**: add `docs/<name>.md` and list it under the right section of `nav:` in
  `mkdocs.yml`. The unit tests fail if a page is on the site but not in the navigation, or in the
  navigation but not on the site.
- **A wiki page**: follow [Contributing to the wiki](../WikiSource/Contributing.md), then list the
  page in `mkdocs.yml` as well. The unit tests check that every wiki page is in the navigation once
  and that the reference section keeps the order of `WikiSource/.pageorder`.
- **A command**: nothing. Its page is generated from the comment-based help and reached from the
  command reference.
