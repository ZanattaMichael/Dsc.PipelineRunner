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
   `site-src/SUMMARY.md` (mdBook's table of contents: each section a part, *Home* first) and the
   Resources page is generated. The README's `<picture>` header becomes the home page's hero: the logo motif as an
   inline SVG that draws itself, and the wordmark in the header artwork's colours for each scheme,
   so it follows the site's own light/dark toggle instead of the operating system.
2. `mdbook build` renders `site-src/` into `site/` with [mdBook](https://rust-lang.github.io/mdBook/),
   configured in `book.toml`: the sidebar, full-text search (press `S` or `/`), the light and dark
   themes, the favicon, and `assets/site.css` and `assets/site.js` on every page.
3. `node tools/check-site.js site --site-url=/Dsc.PipelineRunner/` checks every link, image,
   stylesheet and script in what mdBook wrote: each must exist, and each `#anchor` must be an id
   on its page. Links to other sites are not fetched (`--external` lists them).

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

A link to a page that is not there or an anchor that no heading produces fails the build, so a
broken link in any of the source files fails the pull request that introduces it, not the
deployment. An anchor is the heading in lower case, punctuation dropped, each space a hyphen
(`## [1.5.0] - 2026-11-19` is `#150---2026-11-19`), as on GitHub.

## Motion

The site moves a little, where it helps: the hero draws the logo once when the home page opens
(the three configuration layers merge into one line and the check mark completes it), the
*How it works* animation plays on the home page, sections fade in as they scroll into view
(`assets/site.js`), and sidebar entries slide under the pointer. Behind every page,
`assets/site.js` draws a faint animated sky: lines from three sources merging into one point, as
in the logo, with light travelling along them; the top bar and the sidebar frost it. All of it is
CSS and a few lines of plain JavaScript; nothing is loaded from elsewhere.

A reader whose system asks for reduced motion (`prefers-reduced-motion: reduce`) gets none of it:
the hero is shown finished, the sky is still, the *How it works* animation is replaced by a still frame
(`assets/how-it-works-still.png`, through a `<picture>` the build writes), no section is ever
hidden. Without JavaScript nothing is hidden either.

## Workflows

| Workflow | Runs | Does |
| --- | --- | --- |
| `.github/workflows/Docs-Site.yml` | every pull request and push to `main` | runs the unit tests of `tools/build-site.js` and `tools/check-site.js`, builds the site, checks its links and uploads it as the `docs-site` artifact |
| `.github/workflows/Pages.yml` | pushes to `main` that touch anything the site is built from, and on demand | builds and checks the site the same way and publishes it to GitHub Pages with `actions/configure-pages`, `actions/upload-pages-artifact` and `actions/deploy-pages` |

Both workflows install mdBook (`cargo install`, version pinned in `MDBOOK_VERSION`, cached) and
build the wiki content first (PowerShell ships on the hosted runner) so the command
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
configured for Actions. Without that check the deploy would report success and GitHub's Jekyll
build of the branch would replace the site a few minutes later. The setting is not in any file,
so it is not part of a pull request.

## Building the site locally

```powershell
cargo install --locked mdbook --version 0.5.4                      # the version the workflows pin
./scripts/Build-WikiContent.ps1 -SourcePath $PWD -OutputPath ./output/WikiContent   # optional
node tools/build-site.js --wiki-content output/WikiContent         # or without --wiki-content
mdbook serve                                                       # http://localhost:3000/
mdbook build                                                       # what CI runs, then:
node tools/check-site.js site --site-url=/Dsc.PipelineRunner/
node --test tools/build-site.test.js                               # the unit tests
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
