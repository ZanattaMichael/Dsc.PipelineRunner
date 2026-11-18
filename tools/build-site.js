#!/usr/bin/env node
'use strict';
// Assembles the source of the documentation site (GitHub Pages) from the files in this repository.
//
//   node tools/build-site.js [--out site-src] [--wiki-content output/WikiContent]
//
// The site is the README (as the home page), docs/ (the guides), WikiSource/ (the wiki pages),
// CONTRIBUTING.md, SECURITY.md, CHANGELOG.md and assets/, with the links rewritten so they work
// from inside the site: a link to another page stays a page link (a wiki-style `[x](Page-Name)`
// link included), a link to a file that is not on the site (source, scripts, workflows, examples)
// becomes a link to the file on GitHub, and a relative link to something that does not exist in
// the repository fails the build. mkdocs.yml at the root then builds the site from the output.
//
// --wiki-content names the folder scripts/Build-WikiContent.ps1 wrote: its generated command
// reference (Command-Reference.md and Command-*.md) is copied onto the site. Without it, the
// command reference page is a stub that points at the GitHub wiki, so the site still builds on a
// machine without PowerShell.
//
// Run by the Pages workflow and by CI (which builds the site in strict mode, so a broken link
// fails the build). Nothing here is committed; the output folders are ignored by git.

const fs = require('node:fs');
const path = require('node:path');

const repository = path.resolve(__dirname, '..');
const GITHUB = 'https://github.com/ZanattaMichael/Dsc.PipelineRunner/blob/main/';
const GITHUB_WIKI = 'https://github.com/ZanattaMichael/Dsc.PipelineRunner/wiki/';
// What is copied onto the site as it is, besides the pages.
const COPIED = ['assets'];
// Markdown files at the repository root that are pages of the site, and the page each becomes.
const ROOT_PAGES = {
  'README.md': 'index.md',
  'CONTRIBUTING.md': 'contributing.md',
  'SECURITY.md': 'security.md',
  'CHANGELOG.md': 'changelog.md',
};

function argument(name, fallback) {
  const at = process.argv.indexOf(`--${name}`);
  return at > 0 ? process.argv[at + 1] : fallback;
}

// The page (a path inside the site source) a repository file becomes, or null when the file is
// not a page of the site. `repoFile` is relative to the repository root, with forward slashes.
function pageFor(repoFile) {
  if (ROOT_PAGES[repoFile]) return ROOT_PAGES[repoFile];
  let match = /^docs\/([^/]+\.md)$/.exec(repoFile);
  if (match) return `guides/${match[1]}`;
  match = /^WikiSource\/([^/]+)\.md$/.exec(repoFile);
  if (match) return wikiPage(match[1]);
  return null;
}

// The site page of a wiki page name (the file name without .md, which is also its wiki URL).
function wikiPage(name) {
  return name === 'Home' ? 'wiki/index.md' : `wiki/${name}.md`;
}

function isWikiPageName(name, wikiNames) {
  return /^[A-Za-z0-9][A-Za-z0-9-]*$/.test(name) && wikiNames.has(name);
}

// The names of the wiki pages that exist: those in WikiSource/ and the generated command pages.
function wikiPageNames(commandPages = []) {
  const names = new Set(commandPages.map((file) => file.replace(/\.md$/, '')));
  for (const entry of fs.readdirSync(path.join(repository, 'WikiSource'))) {
    if (entry.endsWith('.md')) names.add(entry.slice(0, -3));
  }
  names.add('Command-Reference');
  return names;
}

function exists(relative) {
  return fs.existsSync(path.join(repository, relative));
}

function isDirectory(relative) {
  const absolute = path.join(repository, relative);
  return fs.existsSync(absolute) && fs.statSync(absolute).isDirectory();
}

// A link from one site page to another, relative to the page it is on.
function relativeLink(fromPage, toPage) {
  const link = path.posix.relative(path.posix.dirname(fromPage), toPage);
  return link === '' ? path.posix.basename(toPage) : link;
}

// Where a link found in `fromFile` (a path relative to the repository root, forward slashes;
// wiki pages are `WikiSource/<Name>.md`, generated command pages `WikiSource/Command-<X>.md`)
// should point on the site. Returns the rewritten target. Throws on a relative link to
// something that is not in the repository, so a broken link fails the build.
function rewriteTarget(target, fromFile, options = {}) {
  const wikiNames = options.wikiNames || wikiPageNames();
  if (/^([a-z][a-z0-9+.-]*:|#|\/\/)/i.test(target)) return target;
  const [pathPart, hash] = target.split('#', 2);
  const anchor = hash ? `#${hash}` : '';
  if (pathPart === '') return target;
  const fromPage = pageFor(fromFile);
  if (!fromPage) throw new Error(`${fromFile} is not a page of the site`);

  // Wiki-style links: `[text](Page-Name)` with no extension, as the GitHub wiki resolves them.
  if (fromFile.startsWith('WikiSource/') && isWikiPageName(pathPart, wikiNames)) {
    return `${relativeLink(fromPage, wikiPage(pathPart))}${anchor}`;
  }

  const fromDirectory = path.posix.dirname(fromFile);
  const decoded = decodeURIComponent(pathPart);
  const resolved = path.posix.normalize(path.posix.join(fromDirectory, decoded)).replace(/^\.\//, '').replace(/\/$/, '');
  if (resolved.startsWith('..')) throw new Error(`${fromFile} links outside the repository: ${target}`);

  if (!exists(resolved)) throw new Error(`${fromFile} links to ${target}, which does not exist in the repository`);
  const page = pageFor(resolved);
  if (page) return `${relativeLink(fromPage, page)}${anchor}`;
  // A folder has no page on the site: it is browsed on GitHub.
  const encoded = resolved.split('/').map(encodeURIComponent).join('/');
  if (isDirectory(resolved)) return `${GITHUB.replace('/blob/', '/tree/')}${encoded}${anchor}`;
  // Files copied onto the site keep their place.
  if (COPIED.some((folder) => resolved.startsWith(`${folder}/`))) return `${relativeLink(fromPage, resolved)}${anchor}`;
  // Anything else is on GitHub.
  return `${GITHUB}${encoded}${anchor}`;
}

// Splits Markdown into fenced code blocks and the prose between them.
function splitFences(markdown) {
  const parts = [];
  const pattern = /^(`{3,}|~{3,})[^\n]*\n[\s\S]*?^\1[ \t]*$/gm;
  let last = 0;
  for (const match of markdown.matchAll(pattern)) {
    if (match.index > last) parts.push({ code: false, text: markdown.slice(last, match.index) });
    parts.push({ code: true, text: match[0] });
    last = match.index + match[0].length;
  }
  if (last < markdown.length) parts.push({ code: false, text: markdown.slice(last) });
  return parts;
}

// The [start, end) ranges of the inline code spans of a piece of prose.
function codeSpans(text) {
  return [...text.matchAll(/(`+)(?!`)([\s\S]*?[^`])\1(?!`)/g)].map((match) => [match.index, match.index + match[0].length]);
}

// Replaces every match of `pattern` in `text` except the ones that start inside inline code:
// `[Text](My-Page)` inside backticks is an example, not a link. A link whose text holds a code
// span (`[`file`](path)`) starts outside the span, so it is rewritten.
function replaceOutsideCode(text, pattern, replacer) {
  const spans = codeSpans(text);
  return text.replace(pattern, (...args) => {
    const index = args[args.length - 2];
    return spans.some(([from, to]) => index > from && index < to) ? args[0] : replacer(...args);
  });
}

// Rewrites the links of one Markdown file: [text](target) (the text may hold code spans and
// images, as a badge does), <img src="target">, <source srcset="target"> and <a href="target">,
// outside code.
function rewriteLinks(markdown, fromFile, options = {}) {
  const linkText = '(?:[^\\[\\]`]|`[^`]*`|!\\[[^\\]]*\\]\\([^)]*\\))*';
  const link = new RegExp(`(!?\\[${linkText}\\]\\(<?)([^)\\s>]+)(>?(?:\\s+"[^"]*")?\\))`, 'g');
  return splitFences(markdown).map((part) => {
    if (part.code) return part.text;
    let text = replaceOutsideCode(part.text, link, (match, open, target, close) => `${open}${rewriteTarget(target, fromFile, options)}${close}`);
    text = replaceOutsideCode(text, /((?:src|srcset|href)=")([^"]+)(")/g, (match, open, target, close) => `${open}${rewriteTarget(target, fromFile, options)}${close}`);
    return text;
  }).join('');
}

// The README's header is a <picture> that follows the operating system's colour scheme. The
// site has its own light/dark toggle, so the header becomes two images that assets/site.css
// shows and hides with the site's scheme.
function siteHeader(markdown) {
  return markdown.replace(
    /<h1>\s*<picture>\s*<source[^>]*srcset="([^"]+)"[^>]*>\s*<img[^>]*src="([^"]+)"[^>]*alt="([^"]*)"[^>]*>\s*<\/picture>\s*<\/h1>/,
    (match, dark, light, alt) => [
      // Still an <h1>, so the page has a heading and the theme does not add a "Home" one above it.
      '<h1 class="site-header">',
      `  <img src="${light}" alt="${alt}" class="only-light" height="120">`,
      `  <img src="${dark}" alt="${alt}" class="only-dark" height="120">`,
      '</h1>',
    ].join('\n'),
  );
}

// The home page: the README with the header adapted and the links rewritten.
function homePage(readme, options = {}) {
  return siteHeader(rewriteLinks(readme, 'README.md', options));
}

// The command reference page when the generated wiki content is not available.
function commandReferenceStub() {
  return [
    '# Command reference',
    '',
    'The command reference is generated from the comment-based help of every exported command by',
    '`scripts/Build-WikiContent.ps1`, and this site was built without it. Read it on the',
    `[GitHub wiki](${GITHUB_WIKI}Command-Reference), or build the site with the wiki content:`,
    '',
    '```powershell',
    './scripts/Build-WikiContent.ps1 -SourcePath $PWD -OutputPath ./output/WikiContent',
    'node tools/build-site.js --wiki-content output/WikiContent',
    '```',
    '',
  ].join('\n');
}

function build(out, wikiContent) {
  fs.rmSync(out, { recursive: true, force: true });
  fs.mkdirSync(out, { recursive: true });
  const commandPages = wikiContent
    ? fs.readdirSync(wikiContent).filter((entry) => /^Command-.*\.md$/.test(entry)).sort()
    : [];
  const options = { wikiNames: wikiPageNames(commandPages) };
  const pages = [];
  const write = (page, markdown) => {
    fs.mkdirSync(path.join(out, path.posix.dirname(page)), { recursive: true });
    fs.writeFileSync(path.join(out, page), markdown);
    pages.push(page);
  };

  write('index.md', homePage(fs.readFileSync(path.join(repository, 'README.md'), 'utf8'), options));
  for (const [file, page] of Object.entries(ROOT_PAGES)) {
    if (file === 'README.md') continue;
    write(page, rewriteLinks(fs.readFileSync(path.join(repository, file), 'utf8'), file, options));
  }
  for (const folder of ['docs', 'WikiSource']) {
    for (const entry of fs.readdirSync(path.join(repository, folder)).sort()) {
      if (!entry.endsWith('.md')) continue;
      const file = `${folder}/${entry}`;
      write(pageFor(file), rewriteLinks(fs.readFileSync(path.join(repository, file), 'utf8'), file, options));
    }
  }
  if (wikiContent) {
    for (const entry of commandPages) {
      const markdown = fs.readFileSync(path.join(wikiContent, entry), 'utf8');
      write(`wiki/${entry}`, rewriteLinks(markdown, `WikiSource/${entry}`, options));
    }
  } else {
    write('wiki/Command-Reference.md', commandReferenceStub());
  }
  for (const folder of COPIED) fs.cpSync(path.join(repository, folder), path.join(out, folder), { recursive: true });
  return pages;
}

if (require.main === module) {
  const out = path.resolve(argument('out', 'site-src'));
  const wikiContent = argument('wiki-content', null);
  const pages = build(out, wikiContent ? path.resolve(wikiContent) : null);
  console.log(`${pages.length} pages and ${COPIED.join(', ')} written to ${out}${wikiContent ? ', with the generated command reference' : ', without the generated command reference'}`);
}

module.exports = { GITHUB, GITHUB_WIKI, COPIED, ROOT_PAGES, pageFor, wikiPage, wikiPageNames, rewriteTarget, rewriteLinks, splitFences, codeSpans, siteHeader, homePage, commandReferenceStub, build };
