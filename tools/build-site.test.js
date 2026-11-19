'use strict';
// Tests of the documentation site builder. Run with:  node --test tools/build-site.test.js
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  GITHUB, GITHUB_TREE, GITHUB_WIKI, ROOT_PAGES, RESOURCES_PAGE, NAV_FILE, FAVICONS,
  createContext, pageFor, rewriteTarget, rewriteLinks, titleOf, summaryOf, synopsisOf, headingAnchor,
  navPages, summary, homePage, build,
} = require('./build-site.js');
const { check } = require('./check-site.js');

const repository = path.join(__dirname, '..');

function temporary() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'dscpr-site-'));
}

function writeFiles(root, files) {
  for (const [relative, content] of Object.entries(files)) {
    fs.mkdirSync(path.join(root, path.dirname(relative)), { recursive: true });
    fs.writeFileSync(path.join(root, relative), content);
  }
}

// The generated command reference as scripts/Build-WikiContent.ps1 writes it, in miniature.
function wikiContentFixture() {
  const folder = temporary();
  writeFiles(folder, {
    'Command-Reference.md': '# Command reference\n\n- [Invoke-Thing](Command-Invoke-Thing) — does a thing.\n',
    'Command-Invoke-Thing.md': '# Invoke-Thing\n\n## Synopsis\n\nDoes a thing.\n\nSee [Resource properties](Resource-Properties) and [the index](Command-Reference).\n',
    'Home.md': '# Home\n',
    '_Sidebar.md': '- [Home](Home)\n',
  });
  return folder;
}

// A small repository with one of everything the site discovers.
function repositoryFixture() {
  const root = temporary();
  writeFiles(root, {
    'README.md': '<h1>\n  <picture>\n    <source media="(prefers-color-scheme: dark)" srcset="assets/header-dark.svg">\n    <img src="assets/header-light.svg" alt="Thing: Does things in any pipeline" height="120">\n  </picture>\n</h1>\n\n## How it works\n\n<img src="assets/flow.gif" alt="flow" width="800">\n\nRead [the guide](docs/new-guide.md), [the example](Example%20Other) and [the rules](Pipeline%20Rules).\n',
    'CONTRIBUTING.md': '# Contributing to Thing\n\nHow to help.\n',
    'SECURITY.md': '# Security\n\nReport privately.\n',
    'CHANGELOG.md': '# Changelog\n\n## [Unreleased]\n\n## [0.2.0] - 2026-02-02\n\n### Added\n\n- Things.\n\n## [0.1.0] - 2026-01-01\n',
    'assets/header-light.svg': '<svg/>', 'assets/header-dark.svg': '<svg/>', 'assets/flow.gif': 'GIF', 'assets/flow-still.png': 'PNG',
    'docs/new-guide.md': '# New guide\n\n> A note first.\n\nThe **first** paragraph, with [a link](../README.md) and `code`.\nIt continues here.\n\nMore.\n',
    'docs/thing-plan.md': '# Thing — plan\n\nA plan.\n',
    'docs/quick-start.md': '# Quick start\n\nStart quickly.\n',
    'WikiSource/.pageorder': '# order\nHome\nBeta\nAlpha\n',
    'WikiSource/Home.md': '# Home\n\nThe wiki. See [Alpha](Alpha) and [Command-Reference](Command-Reference).\n',
    'WikiSource/Alpha.md': '# Alpha\n\nSee [Beta](Beta#part) and [the guide](../docs/new-guide.md).\n',
    'WikiSource/Beta.md': '# Beta\n\n## Part\n',
    'Example Thing/Datum.yml': 'a: 1\n', 'Example Thing/Sub/Node.yml': 'b: 2\n',
    'Example Other/README.md': '# Other example\n\nSee [the guide](../docs/new-guide.md) and [Datum.yml](Datum.yml).\n', 'Example Other/Datum.yml': 'c: 3\n',
    'Pipeline Rules/PreParse/Test-Foo.ps1': '<#\n.SYNOPSIS\nChecks foo.\n#>\n', 'Pipeline Rules/Format/empty.txt': '',
    'Actions/Source/Local.ps1': '<#\n.SYNOPSIS\nReads the configuration from a folder.\n#>\n',
    'containers/img/README.md': '# Agent image\n\nA base image. See [the guide](../../docs/new-guide.md).\n', 'containers/img/Dockerfile': 'FROM scratch\n',
    'Tests/README.md': '# Not documentation\n',
    'source/Public/Do-Thing.ps1': 'function Do-Thing {}\n',
  });
  return root;
}

test('each repository file becomes a page of the site, or none', () => {
  const context = createContext();
  assert.equal(pageFor('README.md', context), 'index.md');
  assert.equal(pageFor('CONTRIBUTING.md', context), 'contributing.md');
  assert.equal(pageFor('SECURITY.md', context), 'security.md');
  assert.equal(pageFor('CHANGELOG.md', context), 'changelog.md');
  assert.equal(pageFor('docs/trust-model.md', context), 'guides/trust-model.md');
  assert.equal(pageFor('WikiSource/Home.md', context), 'wiki/index.md');
  assert.equal(pageFor('WikiSource/Function-Language.md', context), 'wiki/Function-Language.md');
  assert.equal(pageFor('Example Policy Configuration/README.md', context), 'examples/example-policy-configuration/index.md');
  assert.equal(pageFor('containers/dsc-agent/README.md', context), 'containers/dsc-agent/index.md');
  assert.equal(pageFor('LICENSE', context), null);
  assert.equal(pageFor('scripts/Build-WikiContent.ps1', context), null);
  assert.equal(pageFor('Tests/README.md', context), null);
  assert.equal(pageFor('docs/nested/x.md', context), null);
});

test('links from the README to guides, wiki pages, examples and root pages stay page links', () => {
  assert.equal(rewriteTarget('docs/trust-model.md', 'README.md'), 'guides/trust-model.md');
  assert.equal(rewriteTarget('docs/trust-model.md#scope', 'README.md'), 'guides/trust-model.md#scope');
  assert.equal(rewriteTarget('WikiSource/Reporting-and-Exit-Codes.md#dry-runs', 'README.md'), 'wiki/Reporting-and-Exit-Codes.md#dry-runs');
  assert.equal(rewriteTarget('SECURITY.md', 'README.md'), 'security.md');
  assert.equal(rewriteTarget('CONTRIBUTING.md#releasing', 'README.md'), 'contributing.md#releasing');
  assert.equal(rewriteTarget('Example%20Policy%20Configuration', 'README.md'), 'examples/example-policy-configuration/index.md');
  assert.equal(rewriteTarget('Example%20Configuration/Datum.yml', 'README.md'), 'examples/example-configuration/Datum.yml');
});

test('links from a guide, an example and a folder page are relative to their folders', () => {
  assert.equal(rewriteTarget('../README.md#getting-started', 'docs/azure-devops-self-hosted-agent.md'), '../index.md#getting-started');
  assert.equal(rewriteTarget('./dsc-v3-config-functions.md', 'docs/dsc-v3.md'), 'dsc-v3-config-functions.md');
  assert.equal(rewriteTarget('trust-model.md', 'docs/security-response-process.md'), 'trust-model.md');
  assert.equal(rewriteTarget('../SECURITY.md', 'docs/trust-model.md'), '../security.md');
  assert.equal(rewriteTarget('../WikiSource/Engines.md', 'docs/dsc-v3.md'), '../wiki/Engines.md');
  assert.equal(rewriteTarget('../assets/logo.svg', 'docs/dsc-v3.md'), '../assets/logo.svg');
  assert.equal(rewriteTarget('../Example%20Policy%20Configuration', 'docs/capability-policy.md'), '../examples/example-policy-configuration/index.md');
  assert.equal(rewriteTarget('../docs/capability-policy.md', 'Example Policy Configuration/README.md'), '../../guides/capability-policy.md');
  assert.equal(rewriteTarget('Policy.yml', 'Example Policy Configuration/README.md'), 'Policy.yml');
  assert.equal(rewriteTarget('../../docs/hosted-agent-dsc-v3.md', 'containers/dsc-agent/README.md'), '../../guides/hosted-agent-dsc-v3.md');
  assert.equal(rewriteTarget('../../scripts/Install-DscV3.ps1', 'containers/dsc-agent/README.md'), `${GITHUB}scripts/Install-DscV3.ps1`);
});

test('wiki-style links between wiki pages resolve as the GitHub wiki resolves them', () => {
  assert.equal(rewriteTarget('Getting-Started', 'WikiSource/Home.md'), 'Getting-Started.md');
  assert.equal(rewriteTarget('Remote-Targets-and-Credentials#the-identity-the-runner-runs-as', 'WikiSource/Home.md'), 'Remote-Targets-and-Credentials.md#the-identity-the-runner-runs-as');
  assert.equal(rewriteTarget('Home', 'WikiSource/Getting-Started.md'), 'index.md');
  assert.equal(rewriteTarget('Command-Reference', 'WikiSource/Getting-Started.md'), 'Command-Reference.md');
  const context = createContext({ wikiContent: wikiContentFixture() });
  assert.equal(rewriteTarget('Command-Invoke-Thing', 'WikiSource/Command-Reference.md', context), 'Command-Invoke-Thing.md');
  assert.equal(rewriteTarget('Resource-Properties', 'WikiSource/Command-Invoke-Thing.md', context), 'Resource-Properties.md');
  // A wiki page may also link to a repository file the ordinary way.
  assert.equal(rewriteTarget('../docs/trust-model.md', 'WikiSource/Home.md'), '../guides/trust-model.md');
  assert.equal(rewriteTarget('../README.md', 'WikiSource/Home.md'), '../index.md');
});

test('assets stay on the site', () => {
  assert.equal(rewriteTarget('assets/header-dark.svg', 'README.md'), 'assets/header-dark.svg');
  assert.equal(rewriteTarget('assets/how-it-works.gif', 'README.md'), 'assets/how-it-works.gif');
});

test('folders and files that are not on the site are linked on GitHub', () => {
  assert.equal(rewriteTarget('LICENSE', 'README.md'), `${GITHUB}LICENSE`);
  assert.equal(rewriteTarget('.github/dependabot.yml', 'README.md'), `${GITHUB}.github/dependabot.yml`);
  assert.equal(rewriteTarget('scripts/Install-DscV3.ps1', 'README.md'), `${GITHUB}scripts/Install-DscV3.ps1`);
  assert.equal(rewriteTarget('../source/Dsc.PipelineRunner.psd1', 'docs/azure-devops-self-hosted-agent.md'), `${GITHUB}source/Dsc.PipelineRunner.psd1`);
  assert.equal(rewriteTarget('../.github/workflows/DscV3-HostedAgent.yml', 'docs/hosted-agent-dsc-v3.md'), `${GITHUB}.github/workflows/DscV3-HostedAgent.yml`);
  assert.equal(rewriteTarget('scripts', 'README.md'), `${GITHUB_TREE}scripts`);
  assert.equal(rewriteTarget('scripts/', 'README.md'), `${GITHUB_TREE}scripts`);
  assert.equal(rewriteTarget('Pipeline%20Rules', 'README.md'), `${GITHUB_TREE}Pipeline%20Rules`);
});

test('absolute links and anchors are left alone', () => {
  for (const target of ['https://example.test/x', 'mailto:a@b.test', '#section', '//cdn.test/x', 'https://github.com/ZanattaMichael/Dsc.PipelineRunnerActions']) {
    assert.equal(rewriteTarget(target, 'README.md'), target);
    assert.equal(rewriteTarget(target, 'WikiSource/Home.md'), target);
  }
});

test('a relative link to something that is not in the repository fails the build', () => {
  assert.throws(() => rewriteTarget('docs/no-such-page.md', 'README.md'), /does not exist/);
  assert.throws(() => rewriteTarget('No-Such-Page', 'WikiSource/Home.md'), /does not exist/);
  assert.throws(() => rewriteTarget('../../elsewhere.md', 'docs/trust-model.md'), /outside the repository/);
  assert.throws(() => rewriteTarget('x.md', 'Tests/README.md'), /not a page of the site/);
});

test('Markdown links, images and HTML sources are all rewritten', () => {
  const markdown = 'See [trust](docs/trust-model.md "the model") and ![logo](assets/logo.svg).\n<img src="assets/logo.svg" alt=""> <source srcset="assets/header-dark.svg"> <a href="LICENSE">x</a>';
  assert.equal(rewriteLinks(markdown, 'README.md'), `See [trust](guides/trust-model.md "the model") and ![logo](assets/logo.svg).\n<img src="assets/logo.svg" alt=""> <source srcset="assets/header-dark.svg"> <a href="${GITHUB}LICENSE">x</a>`);
});

test('a badge (an image inside a link) and a link whose text holds code are rewritten', () => {
  assert.equal(rewriteLinks('[![License: MIT](https://img.shields.io/x)](LICENSE)', 'README.md'), `[![License: MIT](https://img.shields.io/x)](${GITHUB}LICENSE)`);
  assert.equal(rewriteLinks('[![Security policy](https://img.shields.io/y)](SECURITY.md)', 'README.md'), '[![Security policy](https://img.shields.io/y)](security.md)');
  assert.equal(rewriteLinks('under [`containers/dsc-agent`](../containers/dsc-agent/README.md) if', 'docs/hosted-agent-dsc-v3.md'), 'under [`containers/dsc-agent`](../containers/dsc-agent/index.md) if');
  assert.equal(rewriteLinks('[`notify` and `using()`](docs/notify-and-using.md)', 'README.md'), '[`notify` and `using()`](guides/notify-and-using.md)');
  assert.equal(rewriteLinks('[a](<docs/trust-model.md>)', 'README.md'), '[a](<guides/trust-model.md>)');
});

test('links inside code are examples, not links, and are left alone', () => {
  const inline = 'link with `[Text](My-Page)` — no `.md` extension, then [real](Getting-Started).';
  assert.equal(rewriteLinks(inline, 'WikiSource/Contributing.md'), 'link with `[Text](My-Page)` — no `.md` extension, then [real](Getting-Started.md).');
  const fenced = 'Before [a](Getting-Started)\n\n```markdown\n[Text](My-Page) <a href="nowhere.md">\n```\n\nAfter [b](Engines)\n\n~~~\n[c](Nope)\n~~~\n';
  assert.equal(rewriteLinks(fenced, 'WikiSource/Home.md'), 'Before [a](Getting-Started.md)\n\n```markdown\n[Text](My-Page) <a href="nowhere.md">\n```\n\nAfter [b](Engines.md)\n\n~~~\n[c](Nope)\n~~~\n');
  assert.equal(rewriteLinks('``code with ` inside and [x](Nope)``', 'WikiSource/Home.md'), '``code with ` inside and [x](Nope)``');
});

test('titles, summaries, synopses and heading anchors are read from the documents', () => {
  assert.equal(titleOf('# `notify` and `using()`\n\ntext', 'x'), 'notify and using()');
  assert.equal(titleOf('no heading', 'fallback'), 'fallback');
  assert.equal(summaryOf('# T\n\n> A note.\n\n| a | b |\n|---|---|\n\nThe **first** paragraph, with [a link](x.md) and `code`.\nIt continues.\n\nMore.'), 'The first paragraph, with a link and `code`. It continues.');
  assert.equal(summaryOf('# T\n\n```\ncode\n```\n\nAfter the code.'), 'After the code.');
  assert.equal(summaryOf('# T\n\n- a list only\n'), '');
  assert.match(summaryOf(`# T\n\n${'word '.repeat(80)}`), /^(word ){40,43}word…$/);
  assert.equal(synopsisOf('<#\n.SYNOPSIS\n  Checks foo.\n\n.DESCRIPTION\nx\n#>'), 'Checks foo.');
  assert.equal(synopsisOf('function x {}'), '');
  assert.equal(headingAnchor('[1.3.1] - 2026-11-17'), '131---2026-11-17');
  assert.equal(headingAnchor('[Unreleased]'), 'unreleased');
  assert.equal(headingAnchor('Run it from a CI/CD pipeline'), 'run-it-from-a-cicd-pipeline');
});

test('the README header becomes the animated hero and the animation gets a still for reduced motion', () => {
  const readme = fs.readFileSync(path.join(repository, 'README.md'), 'utf8');
  assert.match(readme, /<picture>/);
  const home = homePage(readme);
  assert.doesNotMatch(home, /<picture>\s*<source media="\(prefers-color-scheme/);
  assert.match(home, /^<div class="site-hero">\n  <svg class="site-hero__logo"/m);
  assert.match(home, /<path class="site-hero__check" pathLength="1"/);
  assert.match(home, /<h1 class="site-hero__title">Dsc\.Pipeline<span>Runner<\/span><\/h1>/);
  assert.match(home, /<p class="site-hero__tagline">Desired State Configuration in any CI\/CD pipeline<\/p>/);
  assert.match(home, /<picture class="site-animation">\n  <source media="\(prefers-reduced-motion: reduce\)" srcset="assets\/how-it-works-still\.png">\n  <img src="assets\/how-it-works\.gif"/);
  assert.ok(fs.existsSync(path.join(repository, 'assets', 'how-it-works-still.png')), 'the still of the animation is in assets/');
});

// Every documentation file in this repository: the site must carry each one.
function documentationFiles() {
  const files = Object.keys(ROOT_PAGES);
  for (const entry of fs.readdirSync(path.join(repository, 'docs'))) if (entry.endsWith('.md')) files.push(`docs/${entry}`);
  for (const entry of fs.readdirSync(path.join(repository, 'WikiSource'))) if (entry.endsWith('.md')) files.push(`WikiSource/${entry}`);
  const skipped = new Set(['.git', '.github', '.build', '.devcontainer', '.vscode', 'Tests', 'output', 'node_modules', 'site', 'site-src', 'docs', 'WikiSource']);
  (function walk(relative) {
    for (const entry of fs.readdirSync(path.join(repository, relative || '.'), { withFileTypes: true })) {
      if (!entry.isDirectory() || skipped.has(entry.name)) continue;
      const child = relative ? `${relative}/${entry.name}` : entry.name;
      if (fs.existsSync(path.join(repository, child, 'README.md'))) files.push(`${child}/README.md`);
      walk(child);
    }
  })('');
  const examples = fs.readdirSync(repository).filter((entry) => /^Example\b/i.test(entry) && fs.statSync(path.join(repository, entry)).isDirectory());
  return { files, examples };
}

test('the site carries every documentation file in the repository, and the navigation reaches every page exactly once', () => {
  const out = temporary();
  const { pages, nav } = build(out, null);
  const context = createContext();
  const { files, examples } = documentationFiles();
  assert.ok(files.length >= 30 && examples.length >= 2);
  for (const file of files) {
    const page = pageFor(file, context);
    assert.ok(page, `${file} is documentation but has no page on the site`);
    assert.ok(pages.includes(page), `${file} is not on the site`);
  }
  for (const folder of examples) {
    const example = context.examples.find((candidate) => candidate.folder === folder);
    assert.ok(example && pages.includes(example.page), `${folder} is not on the site`);
    for (const file of fs.readdirSync(path.join(repository, folder))) {
      if (file === 'README.md') continue; // it is the example's index page
      assert.ok(fs.existsSync(path.join(out, path.dirname(example.page), file)), `${folder}/${file} was not copied onto the site`);
    }
    assert.ok(!fs.existsSync(path.join(out, path.dirname(example.page), 'README.md')), `${folder}/README.md was copied beside its index page`);
  }
  const listed = navPages(nav);
  assert.deepEqual(listed.filter((page, at) => listed.indexOf(page) !== at), [], 'a page is listed twice in the navigation');
  assert.deepEqual(new Set(listed), new Set(pages), 'the navigation and the site do not hold the same pages');
  // SUMMARY.md, mdBook's table of contents, links every page the navigation reaches, and mdBook
  // renders only what SUMMARY.md links.
  const toc = fs.readFileSync(path.join(out, NAV_FILE), 'utf8');
  const linked = [...toc.matchAll(/\]\(([^)]+)\)/g)].map((match) => decodeURIComponent(match[1]));
  assert.deepEqual(new Set(linked), new Set(pages), 'SUMMARY.md and the site do not hold the same pages');
  for (const page of Object.keys(FAVICONS)) assert.ok(fs.existsSync(path.join(out, page)), `${page} is not written`);
  for (const asset of ['logo.svg', 'logo-dark.svg', 'logo-512.png', 'header-light.svg', 'header-dark.svg', 'how-it-works.gif', 'how-it-works-still.png', 'site.css', 'site.js']) {
    assert.ok(fs.existsSync(path.join(out, 'assets', asset)), `assets/${asset} is not on the site`);
  }
  const wikiNames = fs.readdirSync(path.join(repository, 'WikiSource')).filter((entry) => entry.endsWith('.md')).map((entry) => entry.slice(0, -3)).concat('Command-Reference');
  for (const page of pages) {
    const text = fs.readFileSync(path.join(out, page), 'utf8');
    assert.doesNotMatch(text, /\]\((\.\.\/)*(docs|WikiSource)\//, `${page} still links into the repository`);
    if (page.startsWith('wiki/')) for (const name of wikiNames) assert.doesNotMatch(text, new RegExp(`\\]\\(${name}[)#]`), `${page} still holds a wiki-style link to ${name}`);
  }
  // Without the generated wiki content, the command reference points at the GitHub wiki.
  assert.match(fs.readFileSync(path.join(out, 'wiki', 'Command-Reference.md'), 'utf8'), new RegExp(GITHUB_WIKI.replace(/[.]/g, '\\.')));
  fs.rmSync(out, { recursive: true, force: true });
});

test('the navigation follows the rules: getting started, guides with plans, examples, the wiki in .pageorder order, project', () => {
  const out = temporary();
  const { nav } = build(out, null);
  const sections = Object.fromEntries(nav.map(([label, target]) => [label, target]));
  assert.deepEqual(Object.keys(sections), ['Home', 'Getting started', 'Guides', 'Examples', 'Reference (wiki)', 'Project']);
  assert.ok(sections['Getting started'].some(([, page]) => page === 'wiki/Getting-Started.md'));
  assert.ok(sections['Getting started'].some(([, page]) => page === 'guides/hosted-agent-dsc-v3.md'));
  const plans = sections.Guides.find(([label]) => label === 'Design notes and plans');
  assert.ok(plans && plans[1].some(([, page]) => page === 'guides/DECOUPLING_PLAN.md'));
  assert.ok(sections.Examples.some(([, page]) => page === 'examples/example-policy-configuration/index.md'));
  const order = fs.readFileSync(path.join(repository, 'WikiSource', '.pageorder'), 'utf8').split('\n').map((line) => line.trim()).filter((line) => line && !line.startsWith('#')).map((name) => (name === 'Home' ? 'wiki/index.md' : `wiki/${name}.md`));
  const reference = navPages(sections['Reference (wiki)']).filter((page) => !page.startsWith('wiki/Command-'));
  assert.equal(reference[0], 'wiki/index.md', 'the wiki overview comes first');
  assert.deepEqual(reference, order.filter((page) => reference.includes(page)), 'the reference section does not keep .pageorder order');
  const everywhere = navPages(nav);
  for (const page of order) assert.ok(everywhere.includes(page), `${page} is not in the navigation`);
  assert.ok(sections['Reference (wiki)'].some(([label, target]) => label === 'Command reference' && Array.isArray(target) && target[0][1] === 'wiki/Command-Reference.md'));
  assert.equal(sections.Project[0][1], RESOURCES_PAGE);
  for (const page of ['contributing.md', 'security.md', 'changelog.md', 'wiki/Contributing.md', 'guides/documentation-site.md', 'containers/dsc-agent/index.md']) assert.ok(navPages(sections.Project).includes(page), `${page} is not under Project`);
  fs.rmSync(out, { recursive: true, force: true });
});

test('the generated command reference is copied onto the site and listed in the navigation when it is given', () => {
  const wikiContent = wikiContentFixture();
  const out = temporary();
  const { pages, nav } = build(out, wikiContent);
  assert.ok(pages.includes('wiki/Command-Reference.md'));
  assert.ok(pages.includes('wiki/Command-Invoke-Thing.md'));
  assert.ok(!pages.includes('wiki/Home.md') && !pages.includes('wiki/_Sidebar.md'), 'only the command pages come from the generated content');
  assert.equal(fs.readFileSync(path.join(out, 'wiki', 'Command-Reference.md'), 'utf8'), '# Command reference\n\n- [Invoke-Thing](Command-Invoke-Thing.md) — does a thing.\n');
  assert.match(fs.readFileSync(path.join(out, 'wiki', 'Command-Invoke-Thing.md'), 'utf8'), /See \[Resource properties\]\(Resource-Properties\.md\) and \[the index\]\(Command-Reference\.md\)\./);
  assert.equal(fs.readFileSync(path.join(out, 'wiki', 'index.md'), 'utf8').startsWith('# Home\n\n`Dsc.PipelineRunner`'), true, 'the wiki pages themselves come from WikiSource');
  const commands = navPages(nav).filter((page) => page.startsWith('wiki/Command-'));
  assert.deepEqual(commands, ['wiki/Command-Reference.md', 'wiki/Command-Invoke-Thing.md']);
  assert.match(fs.readFileSync(path.join(out, RESOURCES_PAGE), 'utf8'), /\*\*\[Invoke-Thing\]\(wiki\/Command-Invoke-Thing\.md\)\*\* — Does a thing\./);
  fs.rmSync(out, { recursive: true, force: true });
  fs.rmSync(wikiContent, { recursive: true, force: true });
});

test('a new document gets onto the site, into the navigation and onto the Resources page by adding the file', () => {
  const root = repositoryFixture();
  const out = temporary();
  const { pages, nav } = build(out, null, { repository: root });
  const sections = Object.fromEntries(nav.map(([label, target]) => [label, target]));
  // Grouped by the rules, from the titles.
  assert.deepEqual(sections['Getting started'], [['Quick start', 'guides/quick-start.md']]);
  assert.deepEqual(sections.Guides, [['New guide', 'guides/new-guide.md'], ['Design notes and plans', [['Thing — plan', 'guides/thing-plan.md']]]]);
  assert.deepEqual(sections.Examples, [['Other example', 'examples/example-other/index.md'], ['Example Thing', 'examples/example-thing/index.md']]);
  assert.deepEqual(sections['Reference (wiki)'], [['Overview', 'wiki/index.md'], ['Beta', 'wiki/Beta.md'], ['Alpha', 'wiki/Alpha.md'], ['Command reference', [['Overview', 'wiki/Command-Reference.md']]]]);
  assert.deepEqual(sections.Project, [['Resources', 'resources.md'], ['Contributing', 'contributing.md'], ['Security policy', 'security.md'], ['Agent image', 'containers/img/index.md'], ['Changelog', 'changelog.md']]);
  assert.deepEqual(new Set(navPages(nav)), new Set(pages));
  // An example without a README gets a listing; every example file is on the site.
  assert.equal(fs.readFileSync(path.join(out, 'examples', 'example-thing', 'index.md'), 'utf8'), `# Example Thing\n\nAn example configuration, kept in [\`Example Thing/\`](${GITHUB_TREE}Example%20Thing) of the repository. Every file is on the site:\n\n- [\`Datum.yml\`](Datum.yml)\n- [\`Sub/Node.yml\`](Sub/Node.yml)\n`);
  assert.ok(fs.existsSync(path.join(out, 'examples', 'example-thing', 'Sub', 'Node.yml')));
  assert.equal(fs.readFileSync(path.join(out, 'examples', 'example-other', 'index.md'), 'utf8'), '# Other example\n\nSee [the guide](../../guides/new-guide.md) and [Datum.yml](Datum.yml).\n');
  assert.equal(fs.readFileSync(path.join(out, 'containers', 'img', 'index.md'), 'utf8'), '# Agent image\n\nA base image. See [the guide](../../guides/new-guide.md).\n');
  assert.equal(fs.readFileSync(path.join(out, 'wiki', 'Alpha.md'), 'utf8'), '# Alpha\n\nSee [Beta](Beta.md#part) and [the guide](../guides/new-guide.md).\n');
  assert.ok(!pages.some((page) => page.startsWith('tests/')), 'Tests/README.md is not documentation');
  // The home page: links rewritten, the hero, the still.
  const home = fs.readFileSync(path.join(out, 'index.md'), 'utf8');
  assert.match(home, /<h1 class="site-hero__title">Thing<\/h1>\n    <p class="site-hero__tagline">Does things in any pipeline<\/p>/);
  assert.match(home, /\[the guide\]\(guides\/new-guide\.md\), \[the example\]\(examples\/example-other\/index\.md\) and \[the rules\]\(https:\/\/github\.com\/ZanattaMichael\/Dsc\.PipelineRunner\/tree\/main\/Pipeline%20Rules\)/);
  assert.match(home, /<source media="\(prefers-reduced-motion: reduce\)" srcset="assets\/flow-still\.png">/);
  // The Resources page lists everything, with summaries, synopses and the releases of the changelog.
  const resources = fs.readFileSync(path.join(out, RESOURCES_PAGE), 'utf8');
  assert.match(resources, /\*\*\[New guide\]\(guides\/new-guide\.md\)\*\* — The first paragraph, with a link and `code`\. It continues here\./);
  assert.match(resources, /\*\*\[Beta\]\(wiki\/Beta\.md\)\*\*/);
  assert.match(resources, /\*\*\[Example Thing\]\(examples\/example-thing\/index\.md\)\*\* — \[Browse on GitHub\]/);
  assert.match(resources, /## Pipeline Rules[\s\S]*\*\*PreParse\*\*\n\n- \*\*\[Test-Foo\]\(https:\/\/github\.com\/ZanattaMichael\/Dsc\.PipelineRunner\/blob\/main\/Pipeline%20Rules\/PreParse\/Test-Foo\.ps1\)\*\* — Checks foo\./);
  assert.doesNotMatch(resources, /\*\*Format\*\*/, 'a group with no scripts is not listed');
  assert.match(resources, /## Actions[\s\S]*\*\*Source\*\*\n\n- \*\*\[Local\]\([^)]+Actions\/Source\/Local\.ps1\)\*\* — Reads the configuration from a folder\./);
  assert.match(resources, /- \[Unreleased\]\(changelog\.md#unreleased\)\n- \[0\.2\.0 \(2026-02-02\)\]\(changelog\.md#020---2026-02-02\) · \[release\]\(https:\/\/github\.com\/ZanattaMichael\/Dsc\.PipelineRunner\/releases\/tag\/v0\.2\.0\)\n- \[0\.1\.0 \(2026-01-01\)\]/);
  assert.match(resources, /\*\*\[Agent image\]\(containers\/img\/index\.md\)\*\* — A base image\./);
  for (const link of ['https://www.powershellgallery.com/packages/Dsc.PipelineRunner', 'https://github.com/ZanattaMichael/Dsc.PipelineRunnerActions', 'https://zanattamichael.github.io/Dsc.PipelineRunnerActions/', 'https://github.com/ZanattaMichael/Dsc.PipelineRunner/wiki']) assert.ok(resources.includes(link), `${link} is not on the Resources page`);
  // Add a file, build again: it is there.
  writeFiles(root, { 'docs/added-later.md': '# Added later\n\nIt arrived.\n', 'WikiSource/Gamma.md': '# Gamma\n', 'Example New/x.yml': 'x: 1\n' });
  fs.appendFileSync(path.join(root, 'WikiSource', '.pageorder'), 'Gamma\n');
  const again = build(out, null, { repository: root });
  const sectionsAgain = Object.fromEntries(again.nav.map(([label, target]) => [label, target]));
  assert.ok(sectionsAgain.Guides.some(([, page]) => page === 'guides/added-later.md'));
  assert.ok(navPages(sectionsAgain['Reference (wiki)']).at(-2) === 'wiki/Gamma.md');
  assert.ok(sectionsAgain.Examples.some(([, page]) => page === 'examples/example-new/index.md'));
  assert.match(fs.readFileSync(path.join(out, RESOURCES_PAGE), 'utf8'), /\*\*\[Added later\]\(guides\/added-later\.md\)\*\* — It arrived\./);
  fs.rmSync(out, { recursive: true, force: true });
  fs.rmSync(root, { recursive: true, force: true });
});

test('the Pages workflow runs when anything the site is built from changes', () => {
  const workflow = fs.readFileSync(path.join(repository, '.github', 'workflows', 'Pages.yml'), 'utf8');
  for (const trigger of ['README.md', 'CONTRIBUTING.md', 'SECURITY.md', 'CHANGELOG.md', 'docs/**', 'WikiSource/**', 'assets/**', 'Example*/**', 'Pipeline Rules/**', 'Actions/**', 'containers/**', 'source/Public/**', 'scripts/Build-WikiContent.ps1', 'book.toml', 'tools/build-site.js', 'tools/check-site.js', '.github/workflows/Pages.yml']) {
    assert.match(workflow, new RegExp(`^\\s+- ['"]?${trigger.replace(/[.*]/g, '\\$&')}['"]?\\s*$`, 'm'), `${trigger} does not trigger the Pages workflow`);
  }
});

test('SUMMARY.md: Home is a prefix chapter, sections are parts, a group is its overview page or a draft', () => {
  const toc = summary([
    ['Home', 'index.md'],
    ['Guides', [['A [guide] \\ here', 'guides/a.md'], ['Plans', [['B', 'guides/b.md']]]]],
    ['Reference', [['Command reference', [['Overview', 'wiki/Command-Reference.md'], ['C', 'wiki/Command-C.md']]], ['Example Thing', 'examples/example thing/index.md']]],
  ]);
  assert.match(toc, /^# Summary\n/);
  assert.match(toc, /\n\[Home\]\(index\.md\)\n\n# Guides\n\n- \[A \\\[guide\\\] \\\\ here\]\(guides\/a\.md\)\n- \[Plans\]\(\)\n  - \[B\]\(guides\/b\.md\)\n/);
  assert.match(toc, /\n# Reference\n\n- \[Command reference\]\(wiki\/Command-Reference\.md\)\n  - \[C\]\(wiki\/Command-C\.md\)\n- \[Example Thing\]\(examples\/example%20thing\/index\.md\)\n/);
});

test('the link checker finds a missing page, a missing anchor and a link that leaves the site, and lists external links', () => {
  const site = temporary();
  writeFiles(site, {
    'index.html': '<h1 id="top">Home</h1><a href="guide.html#part">ok</a><a href="guide.html#nope">bad anchor</a><a href="gone.html">missing</a>'
      + '<a href="/elsewhere/x.html">leaves</a><a href="/Site/guide.html">ok</a><a href="#top">ok</a><a href="https://example.com/">external</a>'
      + '<a href="mailto:x@example.com">mail</a><img src="img.png"><script>var x = "<a href=\\"nothing.html\\">";</script>',
    'guide.html': '<h2 id="part">Part</h2><a href="index.html">home</a><a href="sub/">folder</a>',
    'sub/index.html': '<p>sub</p>',
    'img.png': 'png',
    'print.html': '<a href="never-checked.html">skipped</a>',
  });
  const result = check(site, '/Site/');
  assert.deepEqual(result.failures.sort(), [
    'index.html: leaves the site -> /elsewhere/x.html',
    'index.html: missing anchor -> guide.html#nope',
    'index.html: missing file -> gone.html',
  ]);
  assert.deepEqual(result.external, ['https://example.com/']);
  assert.throws(() => check(path.join(site, 'sub', 'none')), /not a built site/);
  fs.rmSync(site, { recursive: true, force: true });
});
