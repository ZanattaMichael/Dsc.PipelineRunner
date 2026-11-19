#!/usr/bin/env node
'use strict';
// Assembles the source of the documentation site (GitHub Pages) from the files in this repository.
//
//   node tools/build-site.js [--out site-src] [--wiki-content output/WikiContent]
//
// Everything on the site is discovered from the repository, so a new document gets onto the site
// by adding the file: README.md is the home page; every docs/*.md is a guide; every WikiSource/*.md
// is a wiki page, in the order WikiSource/.pageorder declares; every root folder whose name starts
// with "Example" is an example (its files are copied onto the site, its README.md or a generated
// listing is its page); every other README.md in the repository is a page too; CONTRIBUTING.md,
// SECURITY.md and CHANGELOG.md are project pages; assets/ is copied. From all of that the build
// writes the navigation (<out>/SUMMARY.md, mdBook's table of contents) and a Resources page that
// also lists the Pipeline Rules and Actions scripts with their synopses, the releases recorded in
// the changelog, the PowerShell Gallery listing, the Dsc.PipelineRunnerActions integrations and
// the GitHub wiki. The unit tests fail when a documentation file exists that the site does not
// carry.
//
// Links are rewritten so they work from inside the site: a link to another page stays a page
// link (a wiki-style `[x](Page-Name)` link included), a link to a file that is not on the site
// (source, scripts, workflows) becomes a link to the file on GitHub, and a relative link to
// something that does not exist in the repository fails the build. mdBook (book.toml at the root)
// then builds the site from the output folder, and tools/check-site.js checks every link in what
// it wrote.
//
// --wiki-content names the folder scripts/Build-WikiContent.ps1 wrote: its generated command
// reference (Command-Reference.md and Command-*.md) is copied onto the site. Without it, the
// command reference page is a stub that points at the GitHub wiki, so the site still builds on a
// machine without PowerShell.
//
// Run by the Pages workflow and by CI. Nothing here is committed; the output folders are ignored
// by git.

const fs = require('node:fs');
const path = require('node:path');

const DEFAULT_REPOSITORY = path.resolve(__dirname, '..');
const GITHUB_REPOSITORY = 'https://github.com/ZanattaMichael/Dsc.PipelineRunner';
const GITHUB = `${GITHUB_REPOSITORY}/blob/main/`;
const GITHUB_TREE = `${GITHUB_REPOSITORY}/tree/main/`;
const GITHUB_WIKI = `${GITHUB_REPOSITORY}/wiki/`;
// Documentation that lives outside this repository.
const ELSEWHERE = {
  gallery: 'https://www.powershellgallery.com/packages/Dsc.PipelineRunner',
  releases: `${GITHUB_REPOSITORY}/releases`,
  attestations: `${GITHUB_REPOSITORY}/attestations`,
  issues: `${GITHUB_REPOSITORY}/issues`,
  wiki: `${GITHUB_REPOSITORY}/wiki`,
  actionsRepository: 'https://github.com/ZanattaMichael/Dsc.PipelineRunnerActions',
  actionsSite: 'https://zanattamichael.github.io/Dsc.PipelineRunnerActions/',
};
// Markdown files at the repository root that are pages of the site: the page each becomes and
// its name in the navigation.
const ROOT_PAGES = {
  'README.md': { page: 'index.md', title: 'Home' },
  'CONTRIBUTING.md': { page: 'contributing.md', title: 'Contributing' },
  'SECURITY.md': { page: 'security.md', title: 'Security policy' },
  'CHANGELOG.md': { page: 'changelog.md', title: 'Changelog' },
};
const RESOURCES_PAGE = 'resources.md';
const NAV_FILE = 'SUMMARY.md';
// The site's favicon, written where book.toml's `theme` folder points (inside the output folder).
const FAVICONS = { 'theme/favicon.png': 'assets/logo-512.png', 'theme/favicon.svg': 'assets/logo.svg' };
// Folders whose contents are copied onto the site as they are.
const COPIED = ['assets'];
// Folders whose README.md files are not documentation of the project.
const IGNORED_FOLDERS = new Set(['.git', '.github', '.build', '.devcontainer', '.vscode', 'Tests', 'output', 'node_modules', 'site', 'site-src']);
// Script folders listed on the Resources page: <folder>/<group>/<Name>.ps1.
const SCRIPT_FOLDERS = ['Pipeline Rules', 'Actions'];

// How pages are grouped in the navigation, by title.
const GETTING_STARTED = /\bgetting started\b|\bquick ?start\b|\bset-?up\b/i;
const PLAN = /\b(plan|design)\b/i;
const PROJECT = /\bcontributing\b|\bdocumentation site\b/i;

function argument(name, fallback) {
  const at = process.argv.indexOf(`--${name}`);
  return at > 0 ? process.argv[at + 1] : fallback;
}

function slug(name) {
  return name.toLowerCase().replace(/[^a-z0-9/]+/g, '-').replace(/(^|\/)-|-($|\/)/g, '$1$2');
}

function read(repository, relative) {
  return fs.readFileSync(path.join(repository, relative), 'utf8');
}

function existsIn(repository, relative) {
  return fs.existsSync(path.join(repository, relative));
}

function isDirectoryIn(repository, relative) {
  const absolute = path.join(repository, relative);
  return fs.existsSync(absolute) && fs.statSync(absolute).isDirectory();
}

function listDirectory(repository, relative) {
  return isDirectoryIn(repository, relative) ? fs.readdirSync(path.join(repository, relative)).sort() : [];
}

// Every file under a folder, as paths relative to the repository, sorted.
function filesUnder(repository, folder) {
  const files = [];
  (function walk(relative) {
    for (const entry of listDirectory(repository, relative)) {
      const child = `${relative}/${entry}`;
      if (isDirectoryIn(repository, child)) walk(child); else files.push(child);
    }
  })(folder);
  return files;
}

// Everything the site is built from, discovered once per build.
function createContext({ repository = DEFAULT_REPOSITORY, wikiContent = null } = {}) {
  const context = { repository, wikiContent, copied: { assets: 'assets' } };
  context.examples = listDirectory(repository, '.')
    .filter((entry) => /^Example\b/i.test(entry) && isDirectoryIn(repository, entry))
    .map((folder) => {
      const folderSlug = slug(folder);
      context.copied[folder] = `examples/${folderSlug}`;
      return { folder, page: `examples/${folderSlug}/index.md`, readme: existsIn(repository, `${folder}/README.md`) ? `${folder}/README.md` : null };
    });
  context.folderPages = [];
  (function walk(relative) {
    for (const entry of listDirectory(repository, relative)) {
      const child = relative ? `${relative}/${entry}` : entry;
      if (!isDirectoryIn(repository, child) || IGNORED_FOLDERS.has(entry) || context.copied[child]) continue;
      if (existsIn(repository, `${child}/README.md`)) context.folderPages.push({ folder: child, file: `${child}/README.md`, page: `${slug(child)}/index.md` });
      walk(child);
    }
  })('');
  // The generated command pages, without their index (Command-Reference.md), which is written apart.
  context.commandPages = wikiContent ? fs.readdirSync(wikiContent).filter((entry) => /^Command-(?!Reference\.md$).*\.md$/.test(entry)).sort() : [];
  context.wikiNames = new Set(context.commandPages.map((file) => file.replace(/\.md$/, '')));
  for (const entry of listDirectory(repository, 'WikiSource')) if (entry.endsWith('.md')) context.wikiNames.add(entry.slice(0, -3));
  context.wikiNames.add('Command-Reference');
  return context;
}

// The page (a path inside the site source) a repository file becomes, or null when the file is
// not a page of the site. `repoFile` is relative to the repository root, with forward slashes;
// generated command pages are `WikiSource/Command-<X>.md`.
function pageFor(repoFile, context) {
  if (ROOT_PAGES[repoFile]) return ROOT_PAGES[repoFile].page;
  let match = /^docs\/([^/]+\.md)$/.exec(repoFile);
  if (match) return `guides/${match[1]}`;
  match = /^WikiSource\/([^/]+)\.md$/.exec(repoFile);
  if (match) return wikiPage(match[1]);
  for (const example of context.examples) if (repoFile === `${example.folder}/README.md`) return example.page;
  for (const folderPage of context.folderPages) if (repoFile === folderPage.file) return folderPage.page;
  return null;
}

// The site page of a wiki page name (the file name without .md, which is also its wiki URL).
function wikiPage(name) {
  return name === 'Home' ? 'wiki/index.md' : `wiki/${name}.md`;
}

// A link from one site page to another, relative to the page it is on.
function relativeLink(fromPage, toPage) {
  const link = path.posix.relative(path.posix.dirname(fromPage), toPage);
  return link === '' ? path.posix.basename(toPage) : link;
}

function encodePath(relative) {
  return relative.split('/').map(encodeURIComponent).join('/');
}

// Where a link found in `fromFile` (a path relative to the repository root, forward slashes)
// should point on the site. Returns the rewritten target. Throws on a relative link to
// something that is not in the repository, so a broken link fails the build.
function rewriteTarget(target, fromFile, context = createContext()) {
  if (/^([a-z][a-z0-9+.-]*:|#|\/\/)/i.test(target)) return target;
  const [pathPart, hash] = target.split('#', 2);
  const anchor = hash ? `#${hash}` : '';
  if (pathPart === '') return target;
  const fromPage = pageFor(fromFile, context);
  if (!fromPage) throw new Error(`${fromFile} is not a page of the site`);

  // Wiki-style links: `[text](Page-Name)` with no extension, as the GitHub wiki resolves them.
  if (fromFile.startsWith('WikiSource/') && /^[A-Za-z0-9][A-Za-z0-9-]*$/.test(pathPart) && context.wikiNames.has(pathPart)) {
    return `${relativeLink(fromPage, wikiPage(pathPart))}${anchor}`;
  }

  const decoded = decodeURIComponent(pathPart);
  const resolved = path.posix.normalize(path.posix.join(path.posix.dirname(fromFile), decoded)).replace(/^\.\//, '').replace(/\/$/, '');
  if (resolved.startsWith('..')) throw new Error(`${fromFile} links outside the repository: ${target}`);
  if (!existsIn(context.repository, resolved)) throw new Error(`${fromFile} links to ${target}, which does not exist in the repository`);

  const page = pageFor(resolved, context);
  if (page) return `${relativeLink(fromPage, page)}${anchor}`;
  // An example folder has a page; any other folder is browsed on GitHub.
  const example = context.examples.find((candidate) => candidate.folder === resolved);
  if (example) return `${relativeLink(fromPage, example.page)}${anchor}`;
  if (isDirectoryIn(context.repository, resolved)) return `${GITHUB_TREE}${encodePath(resolved)}${anchor}`;
  // Files copied onto the site keep their place.
  for (const [folder, destination] of Object.entries(context.copied)) {
    if (resolved.startsWith(`${folder}/`)) return `${relativeLink(fromPage, destination + resolved.slice(folder.length))}${anchor}`;
  }
  // Anything else is on GitHub.
  return `${GITHUB}${encodePath(resolved)}${anchor}`;
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
function rewriteLinks(markdown, fromFile, context = createContext()) {
  const linkText = '(?:[^\\[\\]`]|`[^`]*`|!\\[[^\\]]*\\]\\([^)]*\\))*';
  const link = new RegExp(`(!?\\[${linkText}\\]\\(<?)([^)\\s>]+)(>?(?:\\s+"[^"]*")?\\))`, 'g');
  return splitFences(markdown).map((part) => {
    if (part.code) return part.text;
    let text = replaceOutsideCode(part.text, link, (match, open, target, close) => `${open}${rewriteTarget(target, fromFile, context)}${close}`);
    text = replaceOutsideCode(text, /((?:src|srcset|href)=")([^"]+)(")/g, (match, open, target, close) => `${open}${rewriteTarget(target, fromFile, context)}${close}`);
    return text;
  }).join('');
}

// The title of a Markdown document: its first heading, without code marks.
function titleOf(markdown, fallback) {
  const match = /^#\s+(.+?)\s*#*\s*$/m.exec(markdown);
  return match ? match[1].replace(/`/g, '').replace(/\s+/g, ' ').trim() : fallback;
}

// A one-line summary of a Markdown document: its first paragraph of plain prose after the title,
// shortened. Links become their text, so the summary needs no rewriting wherever it is shown.
function summaryOf(markdown, limit = 220) {
  const prose = splitFences(markdown).filter((part) => !part.code).map((part) => part.text).join('\n');
  const lines = prose.split('\n');
  const start = lines.findIndex((line) => /^#\s/.test(line));
  const paragraphs = lines.slice(start + 1).join('\n').split(/\n\s*\n/).map((paragraph) => paragraph.trim());
  const first = paragraphs.find((paragraph) => paragraph && !/^([#>|<!*-]|\d+\.\s|\[!\[|```|~~~|\s{4}|\t)/.test(paragraph));
  if (!first) return '';
  let text = first.replace(/\s*\n\s*/g, ' ')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/<[^>]+>/g, '')
    .replace(/\*\*([^*]+)\*\*/g, '$1').replace(/\*([^*]+)\*/g, '$1').replace(/__([^_]+)__/g, '$1')
    .replace(/\s+/g, ' ').trim();
  if (text.length > limit) text = `${text.slice(0, limit).replace(/\s+\S*$/, '')}…`;
  return text;
}

// The .SYNOPSIS of a PowerShell script's comment-based help, or an empty string.
function synopsisOf(script) {
  const match = /\.SYNOPSIS\s*\r?\n\s*(.+)/.exec(script);
  return match ? match[1].trim() : '';
}

// The anchor mdBook (and GitHub) gives a heading: lower case, punctuation dropped, each space a
// hyphen ("[1.3.1] - 2026-11-17" is "131---2026-11-17").
function headingAnchor(heading) {
  return heading.trim().toLowerCase().replace(/[^\w\s-]/g, '').replace(/\s/g, '-');
}

// The documents the site carries, each with its page, title and summary, grouped by kind.
function discover(context) {
  const { repository } = context;
  const pageOrder = existsIn(repository, 'WikiSource/.pageorder')
    ? read(repository, 'WikiSource/.pageorder').split('\n').map((line) => line.trim()).filter((line) => line && !line.startsWith('#'))
    : listDirectory(repository, 'WikiSource').filter((entry) => entry.endsWith('.md')).map((entry) => entry.slice(0, -3));
  const document = (file, fallbackTitle) => {
    const markdown = read(repository, file);
    return { file, page: pageFor(file, context), title: titleOf(markdown, fallbackTitle), summary: summaryOf(markdown) };
  };
  const guides = listDirectory(repository, 'docs').filter((entry) => entry.endsWith('.md'))
    .map((entry) => document(`docs/${entry}`, entry.slice(0, -3)))
    .sort((a, b) => a.title.localeCompare(b.title));
  const wiki = pageOrder.map((name) => ({ name, ...document(`WikiSource/${name}.md`, name) }));
  const commands = context.commandPages.map((entry) => {
    const markdown = fs.readFileSync(path.join(context.wikiContent, entry), 'utf8');
    const synopsis = /## Synopsis\s*\n+([^\n]+)/.exec(markdown);
    return { name: entry.slice(8, -3), page: `wiki/${entry}`, title: titleOf(markdown, entry.slice(8, -3)), summary: synopsis ? synopsis[1].trim() : '' };
  });
  const examples = context.examples.map((example) => ({
    ...example,
    title: example.readme ? titleOf(read(repository, example.readme), example.folder) : example.folder,
    summary: example.readme ? summaryOf(read(repository, example.readme)) : '',
    files: filesUnder(repository, example.folder).filter((file) => file !== example.readme),
  }));
  const folderPages = context.folderPages.map((folderPage) => ({ ...folderPage, ...document(folderPage.file, folderPage.folder) }));
  const rootPages = Object.entries(ROOT_PAGES).filter(([file]) => file !== 'README.md' && existsIn(repository, file))
    .map(([file, { page, title }]) => ({ file, page, title, summary: summaryOf(read(repository, file)) }));
  const scripts = {};
  for (const folder of SCRIPT_FOLDERS) {
    scripts[folder] = listDirectory(repository, folder).filter((group) => isDirectoryIn(repository, `${folder}/${group}`)).map((group) => ({
      group,
      scripts: listDirectory(repository, `${folder}/${group}`).filter((entry) => entry.endsWith('.ps1')).map((entry) => ({
        name: entry.slice(0, -4), file: `${folder}/${group}/${entry}`, summary: synopsisOf(read(repository, `${folder}/${group}/${entry}`)),
      })),
    }));
  }
  const releases = existsIn(repository, 'CHANGELOG.md')
    ? [...read(repository, 'CHANGELOG.md').matchAll(/^## (\[([^\]]+)\](?: - (\S+))?.*)$/gm)].map((match) => ({
      heading: match[1], version: match[2], date: match[3] || '', anchor: headingAnchor(match[1]),
      tag: /^\d/.test(match[2]) ? `${GITHUB_REPOSITORY}/releases/tag/v${match[2]}` : null,
    }))
    : [];
  return { guides, wiki, commands, examples, folderPages, rootPages, scripts, releases };
}

// The navigation, as nested [label, page | children] pairs, from the discovered documents.
function navigation(discovered) {
  const { guides, wiki, commands, examples, folderPages, rootPages } = discovered;
  const entry = (document) => [document.title, document.page];
  const rootTitles = new Set(Object.values(ROOT_PAGES).map(({ title }) => title));
  const wikiEntry = (document) => [rootTitles.has(document.title) ? `${document.title} (wiki)` : document.title, document.page];
  const home = wiki.find((document) => document.name === 'Home');
  const gettingStarted = [
    ...wiki.filter((document) => document !== home && GETTING_STARTED.test(document.title)).map(wikiEntry),
    ...guides.filter((document) => GETTING_STARTED.test(document.title)).map(entry),
  ];
  const plans = guides.filter((document) => !GETTING_STARTED.test(document.title) && !PROJECT.test(document.title) && PLAN.test(document.title));
  const ordinaryGuides = guides.filter((document) => !GETTING_STARTED.test(document.title) && !PROJECT.test(document.title) && !PLAN.test(document.title));
  const reference = [
    ...(home ? [['Overview', home.page]] : []),
    ...wiki.filter((document) => document !== home && !GETTING_STARTED.test(document.title) && !PROJECT.test(document.title)).map(wikiEntry),
    ['Command reference', [['Overview', 'wiki/Command-Reference.md'], ...commands.map(entry)]],
  ];
  const project = [
    ['Resources', RESOURCES_PAGE],
    ...rootPages.filter((document) => document.file !== 'CHANGELOG.md').map(entry),
    ...wiki.filter((document) => document !== home && PROJECT.test(document.title)).map(wikiEntry),
    ...guides.filter((document) => !GETTING_STARTED.test(document.title) && PROJECT.test(document.title)).map(entry),
    ...folderPages.map(entry),
    ...rootPages.filter((document) => document.file === 'CHANGELOG.md').map(entry),
  ];
  const nav = [['Home', 'index.md']];
  if (gettingStarted.length) nav.push(['Getting started', gettingStarted]);
  if (ordinaryGuides.length || plans.length) nav.push(['Guides', [...ordinaryGuides.map(entry), ...(plans.length ? [['Design notes and plans', plans.map(entry)]] : [])]]);
  if (examples.length) nav.push(['Examples', examples.map(entry)]);
  nav.push(['Reference (wiki)', reference]);
  nav.push(['Project', project]);
  return nav;
}

// The navigation as mdBook's SUMMARY.md. Home is a prefix chapter; each top-level section is a
// part title; a group inside a section is a chapter whose page is its 'Overview' entry when it has
// one, and a heading-only (draft) chapter when it does not.
function summary(nav) {
  const lines = ['# Summary', '', '<!-- GENERATED by tools/build-site.js from the files in the repository. -->', ''];
  const link = (label, page) => `[${label.replace(/([\\[\]])/g, '\\$1')}](${encodePath(page)})`;
  (function emit(items, depth) {
    for (const [label, target] of items) {
      const indent = '  '.repeat(Math.max(depth - 1, 0));
      if (depth === 0 && Array.isArray(target)) {
        lines.push('', `# ${label}`, '');
        emit(target, 1);
      } else if (depth === 0) {
        lines.push(link(label, target));
      } else if (Array.isArray(target)) {
        const [first, ...rest] = target;
        const overview = first && first[0] === 'Overview' && !Array.isArray(first[1]);
        lines.push(`${indent}- ${overview ? link(label, first[1]) : `[${label}]()`}`);
        emit(overview ? rest : target, depth + 1);
      } else {
        lines.push(`${indent}- ${link(label, target)}`);
      }
    }
  })(nav, 0);
  return `${lines.join('\n')}\n`;
}

// Every page the navigation reaches, in order.
function navPages(nav) {
  return nav.flatMap(([, target]) => (Array.isArray(target) ? navPages(target) : [target]));
}

// The Resources page: every document the site carries and everything written elsewhere.
function resourcesPage(discovered) {
  const { guides, wiki, commands, examples, folderPages, rootPages, scripts, releases } = discovered;
  const lines = [];
  const item = (title, link, summary) => lines.push(`- **[${title}](${link})**${summary ? ` — ${summary}` : ''}`);
  const section = (heading, intro) => { lines.push('', `## ${heading}`, ''); if (intro) lines.push(intro, ''); };
  lines.push('# Resources', '',
    'Everything written about Dsc.PipelineRunner, in one place. This page is generated by the site',
    'build from the files in the repository: add a guide, a wiki page, an example folder, a script or',
    'a changelog entry, and it appears here and in the navigation on the next build.');

  section('Getting started');
  item('Home', 'index.md', 'the README: overview, installation, quick start, how a run executes, the public commands.');
  for (const document of [...wiki.filter((d) => d.name !== 'Home' && GETTING_STARTED.test(d.title)), ...guides.filter((d) => GETTING_STARTED.test(d.title))]) item(document.title, document.page, document.summary);

  section('Guides', 'The guides under `docs/`.');
  for (const document of guides.filter((d) => !GETTING_STARTED.test(d.title))) item(document.title, document.page, document.summary);

  section('Reference (wiki)', `The pages under \`WikiSource/\`, which are also published to the [GitHub wiki](${ELSEWHERE.wiki}).`);
  for (const document of wiki) item(document.name === 'Home' ? 'Wiki overview' : document.title, document.page, document.summary);

  section('Command reference', 'Generated from the comment-based help of every exported command.');
  item('Command reference', 'wiki/Command-Reference.md', 'the index of the commands.');
  for (const command of commands) item(command.title, command.page, command.summary);

  if (examples.length) {
    section('Examples', 'Complete configurations to copy from. Each folder is on the site file by file, and on GitHub.');
    for (const example of examples) item(example.title, example.page, `${example.summary ? `${example.summary} ` : ''}[Browse on GitHub](${GITHUB_TREE}${encodePath(example.folder)}).`);
  }

  for (const folder of SCRIPT_FOLDERS) {
    const groups = scripts[folder].filter((group) => group.scripts.length);
    if (!groups.length) continue;
    section(folder, `The scripts under [\`${folder}/\`](${GITHUB_TREE}${encodePath(folder)}), each with the synopsis of its comment-based help.`);
    for (const group of groups) {
      lines.push(`**${group.group}**`, '');
      for (const script of group.scripts) item(script.name, `${GITHUB}${encodePath(script.file)}`, script.summary);
      lines.push('');
    }
  }

  section('Project');
  for (const document of rootPages) item(document.title, document.page, document.summary);
  for (const document of folderPages) item(document.title, document.page, document.summary);
  item('Licence', `${GITHUB}LICENSE`, 'MIT.');

  section('Releases and packages');
  item('PowerShell Gallery', ELSEWHERE.gallery, 'the published module: `Install-Module Dsc.PipelineRunner`.');
  item('GitHub releases', ELSEWHERE.releases, `every release with its notes and package; [build provenance attestations](${ELSEWHERE.attestations}) for each.`);
  if (releases.length) {
    lines.push('', 'Release notes, from the changelog:', '');
    for (const release of releases) {
      const label = release.date ? `${release.version} (${release.date})` : release.version;
      lines.push(`- [${label}](changelog.md#${release.anchor})${release.tag ? ` · [release](${release.tag})` : ''}`);
    }
  }

  section('Integrations');
  item('Dsc.PipelineRunnerActions', ELSEWHERE.actionsRepository, 'one pipeline step for Dsc.PipelineRunner on GitHub Actions, Azure DevOps, GitLab, CircleCI and Jenkins.');
  item('Dsc.PipelineRunnerActions documentation', ELSEWHERE.actionsSite, 'the integrations\' own site: requirements, settings and a guide per platform.');

  section('Elsewhere');
  item('GitHub wiki', ELSEWHERE.wiki, 'the wiki pages above, as GitHub publishes them on each release.');
  item('Source on GitHub', GITHUB_REPOSITORY, 'the module, the actions, the pipeline rules, the tests and the workflows.');
  item('Issues', ELSEWHERE.issues, 'bugs and feature requests.');
  lines.push('');
  return lines.join('\n');
}

// The home page's hero: the logo motif drawn by CSS (assets/site.css) and the wordmark, in place
// of the README's <picture> header, which follows the operating system rather than the site's
// own light/dark toggle. The animation only runs for readers who have not asked for reduced
// motion; everyone else sees the finished drawing.
function hero(alt) {
  const [name, tagline = ''] = alt.split(/:\s+/, 2);
  const wordmark = name.replace(/Runner$/, '<span>Runner</span>');
  return [
    '<div class="site-hero">',
    '  <svg class="site-hero__logo" viewBox="0 0 256 256" aria-hidden="true" focusable="false">',
    '    <defs><linearGradient id="site-hero-tile" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#0e66b5"/><stop offset="1" stop-color="#249ee2"/></linearGradient></defs>',
    '    <rect class="site-hero__tile" x="8" y="8" width="240" height="240" rx="56" fill="url(#site-hero-tile)"/>',
    '    <g fill="none" stroke="#ffffff" stroke-width="12" stroke-linecap="round" stroke-linejoin="round">',
    '      <path class="site-hero__layer" pathLength="1" d="M44 94 C 82 94, 88 128, 120 128"/>',
    '      <path class="site-hero__layer" pathLength="1" d="M44 128 L 120 128"/>',
    '      <path class="site-hero__layer" pathLength="1" d="M44 162 C 82 162, 88 128, 120 128"/>',
    '      <path class="site-hero__merge" pathLength="1" d="M120 128 L 142 128"/>',
    '    </g>',
    '    <g class="site-hero__dots" fill="#ffffff"><circle cx="44" cy="94" r="8"/><circle cx="44" cy="128" r="8"/><circle cx="44" cy="162" r="8"/></g>',
    '    <path class="site-hero__check" pathLength="1" d="M140 128 L 166 154 L 214 100" fill="none" stroke="#9ff3d0" stroke-width="19" stroke-linecap="round" stroke-linejoin="round"/>',
    '  </svg>',
    '  <div class="site-hero__text">',
    `    <h1 class="site-hero__title">${wordmark}</h1>`,
    tagline ? `    <p class="site-hero__tagline">${tagline}</p>` : '',
    '  </div>',
    '</div>',
  ].filter((line) => line !== '').join('\n');
}

function siteHeader(markdown) {
  return markdown.replace(
    /<h1>\s*<picture>\s*<source[^>]*srcset="[^"]+"[^>]*>\s*<img[^>]*alt="([^"]*)"[^>]*>\s*<\/picture>\s*<\/h1>/,
    (match, alt) => hero(alt),
  );
}

// An animated GIF gets a still for readers who asked for reduced motion, when
// assets/<name>-still.png exists beside it.
function stillImages(markdown, context) {
  return markdown.replace(/<img src="(assets\/([^"]+)\.gif)"([^>]*)>/g, (match, gif, name, rest) => {
    const still = `assets/${name}-still.png`;
    if (!existsIn(context.repository, still)) return match;
    return `<picture class="site-animation">\n  <source media="(prefers-reduced-motion: reduce)" srcset="${still}">\n  <img src="${gif}"${rest}>\n</picture>`;
  });
}

// The home page: the README with the links rewritten, the hero in place of the header, and a
// still for each animation.
function homePage(readme, context = createContext()) {
  return stillImages(siteHeader(rewriteLinks(readme, 'README.md', context)), context);
}

// The page of an example folder that has no README: the folder's files, each viewable on the site.
function exampleListing(example) {
  const lines = [`# ${example.title}`, '', `An example configuration, kept in [\`${example.folder}/\`](${GITHUB_TREE}${encodePath(example.folder)}) of the repository. Every file is on the site:`, ''];
  for (const file of example.files) lines.push(`- [\`${file.slice(example.folder.length + 1)}\`](${encodePath(file.slice(example.folder.length + 1))})`);
  lines.push('');
  return lines.join('\n');
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

function build(out, wikiContent = null, { repository = DEFAULT_REPOSITORY } = {}) {
  const context = createContext({ repository, wikiContent });
  const discovered = discover(context);
  fs.rmSync(out, { recursive: true, force: true });
  fs.mkdirSync(out, { recursive: true });
  const pages = [];
  const write = (page, markdown) => {
    fs.mkdirSync(path.join(out, path.posix.dirname(page)), { recursive: true });
    fs.writeFileSync(path.join(out, page), markdown);
    pages.push(page);
  };
  const copy = (page, file) => write(page, rewriteLinks(read(repository, file), file, context));

  write('index.md', homePage(read(repository, 'README.md'), context));
  for (const document of discovered.rootPages) copy(document.page, document.file);
  for (const document of [...discovered.guides, ...discovered.wiki, ...discovered.folderPages]) copy(document.page, document.file);
  for (const example of discovered.examples) {
    if (example.readme) copy(example.page, example.readme); else write(example.page, exampleListing(example));
  }
  if (wikiContent) {
    for (const entry of ['Command-Reference.md', ...context.commandPages]) write(`wiki/${entry}`, rewriteLinks(fs.readFileSync(path.join(wikiContent, entry), 'utf8'), `WikiSource/${entry}`, context));
  } else {
    write('wiki/Command-Reference.md', commandReferenceStub());
  }
  write(RESOURCES_PAGE, resourcesPage(discovered));
  for (const [folder, destination] of Object.entries(context.copied)) {
    if (!isDirectoryIn(repository, folder)) continue;
    // An example's README.md is its index page, so the copy leaves the file itself out.
    const readme = path.join(repository, folder, 'README.md');
    fs.cpSync(path.join(repository, folder), path.join(out, destination), { recursive: true, filter: (source) => source !== readme });
  }
  const nav = navigation(discovered);
  fs.writeFileSync(path.join(out, NAV_FILE), summary(nav));
  for (const [page, file] of Object.entries(FAVICONS)) {
    if (!existsIn(repository, file)) continue;
    fs.mkdirSync(path.join(out, path.posix.dirname(page)), { recursive: true });
    fs.copyFileSync(path.join(repository, file), path.join(out, page));
  }
  return { pages, nav, discovered };
}

if (require.main === module) {
  const out = path.resolve(argument('out', 'site-src'));
  const wikiContent = argument('wiki-content', null);
  const { pages, discovered } = build(out, wikiContent ? path.resolve(wikiContent) : null);
  console.log(`${pages.length} pages (${discovered.guides.length} guides, ${discovered.wiki.length} wiki pages, ${discovered.commands.length} command pages, ${discovered.examples.length} examples) and the navigation written to ${out}${wikiContent ? ', with the generated command reference' : ', without the generated command reference'}`);
}

module.exports = {
  GITHUB, GITHUB_TREE, GITHUB_WIKI, ELSEWHERE, ROOT_PAGES, RESOURCES_PAGE, NAV_FILE, FAVICONS, SCRIPT_FOLDERS,
  createContext, pageFor, wikiPage, rewriteTarget, rewriteLinks, splitFences, codeSpans, titleOf, summaryOf, synopsisOf, headingAnchor,
  discover, navigation, summary, navPages, resourcesPage, hero, siteHeader, stillImages, homePage, exampleListing, commandReferenceStub, build,
};
