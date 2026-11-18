# Documentation site

The README, the guides under `docs/`, the wiki pages under `WikiSource/`, the generated command
reference, the example configurations and the rest of the repository's documentation are
published together as one searchable site:

**<https://zanattamichael.github.io/Dsc.PipelineRunner/>**

The site is a view of the files in this repository. Nothing is written for the site alone, and
nothing on it is listed by hand: **a new document gets onto the site by adding the file.** The
build discovers it, puts it in the navigation and on the [Resources](https://zanattamichael.github.io/Dsc.PipelineRunner/resources/)
page, and a unit test fails if a documentation file exists that the site does not carry.

## What is on the site, and where it comes from

| Section of the site | Discovered from |
| --- | --- |
| Home | `README.md` |
| Getting started | the guides and wiki pages whose title says *getting started*, *quick start* or *setup* |
| Guides | every other `docs/*.md`, sorted by title; a title that says *plan* or *design* goes under *Design notes and plans* |
| Examples | every root folder whose name starts with `Example`. Its `README.md` is its page, or a listing of its files is generated; every file in the folder is copied onto the site, so the YAML can be read in place |
| Reference (wiki) | every `WikiSource/*.md`, in the order `WikiSource/.pageorder` declares (`Home` first, as *Overview*), then the command reference that `scripts/Build-WikiContent.ps1` generates from each exported command's comment-based help, one page per command |
| Project | the Resources page, `CONTRIBUTING.md`, `SECURITY.md`, the wiki and guide pages whose title says *contributing* or *documentation site*, every other `README.md` in the repository (such as the hosted-agent image's), and `CHANGELOG.md` |
| Resources | generated: everything above with a one-line summary of each page, the scripts under `Pipeline Rules/` and `Actions/` with the synopsis of their comment-based help, the releases recorded in the changelog with a link to each GitHub release, the PowerShell Gallery listing, the Dsc.PipelineRunnerActions integrations and their site, and the GitHub wiki |
| Images | `assets/` |

Folders that are not documentation (`Tests/`, `.github/`, `.build/`, `output/`) are not looked at.

The wiki pages stay the source of the GitHub wiki as well. The site compiles the wiki content only
to put the command reference on the site; the wiki itself is still published by the Release
workflow and gated per pull request by the Wiki workflow, exactly as
[Contributing to the wiki](../WikiSource/Contributing.md) describes.

## How it is built

1. `tools/build-site.js` discovers the documents above and assembles the site source into
   `site-src/` (ignored by git): the pages are copied under `guides/`, `wiki/`, `examples/` and so
   on, every link is rewritten so it works from inside the site, the navigation is written to
   `site-src/.nav.yml` (which `mkdocs.yml` inherits through `INHERIT`) and the Resources page is
   generated. The README's `<picture>` header becomes the home page's hero: the logo motif as an
   inline SVG that draws itself, and the wordmark in the header artwork's colours for each scheme,
   so it follows the site's own light/dark toggle instead of the operating system.
2. `mkdocs build --strict` renders `site-src/` into `site/` with
   [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/), configured in
   `mkdocs.yml`: the logo and favicon, light and dark palettes in the logo's colours
   (`assets/site.css`), grouped navigation, search and copy buttons on code blocks.

Links are rewritten by these rules, and `tools/build-site.test.js` holds an example of each:

| A relative link to | Becomes |
| --- | --- |
| another page of the site (`README.md`, `docs/*.md`, `WikiSource/*.md`, an example's or another folder's `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`), with or without an anchor | a link to that page |
| a wiki page by name, `[Engines](Engines)`, as the GitHub wiki resolves it | a link to that page |
| an example folder | the example's page |
| a file under `assets/` or inside an example folder | the file, which is copied onto the site |
| any other folder | the folder on GitHub |
| any other file (source, scripts, workflows, the licence) | the file on GitHub |
| something that does not exist in the repository | a build error |

Absolute URLs and bare anchors are left as they are, including links to the
[Dsc.PipelineRunnerActions](https://github.com/ZanattaMichael/Dsc.PipelineRunnerActions)
repository and to the GitHub wiki. Links inside code spans and fenced code blocks are examples,
not links, and are left alone.

Strict mode means a warning fails the build: a link to a page that is not there, an anchor that
no heading produces, or a page missing from the navigation. A broken link in any of the source
files therefore fails the pull request that introduces it, not the deployment.

## Motion

The site moves a little, where it helps: the hero draws the logo once when the home page opens
(the three configuration layers merge into one line and the check mark completes it), the
*How it works* animation plays on the home page, sections fade in as they scroll into view
(`assets/site.js`), and the light/dark toggle fades between the palettes. All of it is CSS and a
few lines of plain JavaScript; there is no framework and nothing is loaded from elsewhere.

A reader whose system asks for reduced motion (`prefers-reduced-motion: reduce`) gets none of it:
the hero is shown finished, the *How it works* animation is replaced by a still frame
(`assets/how-it-works-still.png`, through a `<picture>` the build writes), no section is ever
hidden, and the palette switches at once. Without JavaScript nothing is hidden either.

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

## Adding a document

Add the file. That is the whole procedure:

- **A guide**: `docs/<name>.md`, starting with a `# Title`. The title decides the section (see the
  table above) and its first paragraph is its summary on the Resources page.
- **A wiki page**: follow [Contributing to the wiki](../WikiSource/Contributing.md); the page
  takes the place `.pageorder` gives it.
- **An example**: a root folder named `Example <something>`, with or without a `README.md`.
- **A command**: comment-based help on the function; its page is generated.
- **A pipeline rule or an action**: a `.ps1` with a `.SYNOPSIS`; it is listed on the Resources page.
- **A release**: a `## [version] - date` heading in `CHANGELOG.md`; it is listed under *Releases*.

The unit tests fail if a documentation file exists that the site does not carry, or if the
navigation and the site disagree about which pages exist.
