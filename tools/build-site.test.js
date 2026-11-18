'use strict';
// Tests of the documentation site builder. Run with:  node --test tools/build-site.test.js
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  GITHUB, GITHUB_WIKI, pageFor, rewriteTarget, rewriteLinks, siteHeader, homePage, build,
} = require('./build-site.js');

const repository = path.join(__dirname, '..');
const TREE = GITHUB.replace('/blob/', '/tree/');

function temporary() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'dscpr-site-'));
}

// The generated command reference as scripts/Build-WikiContent.ps1 writes it, in miniature.
function wikiContentFixture() {
  const folder = temporary();
  fs.writeFileSync(path.join(folder, 'Command-Reference.md'), '# Command reference\n\n- [Invoke-Thing](Command-Invoke-Thing) — does a thing.\n');
  fs.writeFileSync(path.join(folder, 'Command-Invoke-Thing.md'), '# Invoke-Thing\n\nSee [Resource properties](Resource-Properties) and [the index](Command-Reference).\n');
  fs.writeFileSync(path.join(folder, 'Home.md'), '# Home\n');
  fs.writeFileSync(path.join(folder, '_Sidebar.md'), '- [Home](Home)\n');
  return folder;
}

test('each repository file becomes a page of the site, or none', () => {
  assert.equal(pageFor('README.md'), 'index.md');
  assert.equal(pageFor('CONTRIBUTING.md'), 'contributing.md');
  assert.equal(pageFor('SECURITY.md'), 'security.md');
  assert.equal(pageFor('CHANGELOG.md'), 'changelog.md');
  assert.equal(pageFor('docs/trust-model.md'), 'guides/trust-model.md');
  assert.equal(pageFor('WikiSource/Home.md'), 'wiki/index.md');
  assert.equal(pageFor('WikiSource/Function-Language.md'), 'wiki/Function-Language.md');
  assert.equal(pageFor('LICENSE'), null);
  assert.equal(pageFor('scripts/Build-WikiContent.ps1'), null);
  assert.equal(pageFor('docs/nested/x.md'), null);
});

test('links from the README to guides, wiki pages and root pages stay page links', () => {
  assert.equal(rewriteTarget('docs/trust-model.md', 'README.md'), 'guides/trust-model.md');
  assert.equal(rewriteTarget('docs/trust-model.md#scope', 'README.md'), 'guides/trust-model.md#scope');
  assert.equal(rewriteTarget('WikiSource/Reporting-and-Exit-Codes.md#dry-runs', 'README.md'), 'wiki/Reporting-and-Exit-Codes.md#dry-runs');
  assert.equal(rewriteTarget('SECURITY.md', 'README.md'), 'security.md');
  assert.equal(rewriteTarget('CONTRIBUTING.md#releasing', 'README.md'), 'contributing.md#releasing');
});

test('links from a guide are relative to the guides folder', () => {
  assert.equal(rewriteTarget('../README.md#getting-started', 'docs/azure-devops-self-hosted-agent.md'), '../index.md#getting-started');
  assert.equal(rewriteTarget('./dsc-v3-config-functions.md', 'docs/dsc-v3.md'), 'dsc-v3-config-functions.md');
  assert.equal(rewriteTarget('trust-model.md', 'docs/security-response-process.md'), 'trust-model.md');
  assert.equal(rewriteTarget('../SECURITY.md', 'docs/trust-model.md'), '../security.md');
  assert.equal(rewriteTarget('../WikiSource/Engines.md', 'docs/dsc-v3.md'), '../wiki/Engines.md');
  assert.equal(rewriteTarget('../assets/logo.svg', 'docs/dsc-v3.md'), '../assets/logo.svg');
});

test('wiki-style links between wiki pages resolve as the GitHub wiki resolves them', () => {
  assert.equal(rewriteTarget('Getting-Started', 'WikiSource/Home.md'), 'Getting-Started.md');
  assert.equal(rewriteTarget('Remote-Targets-and-Credentials#the-identity-the-runner-runs-as', 'WikiSource/Home.md'), 'Remote-Targets-and-Credentials.md#the-identity-the-runner-runs-as');
  assert.equal(rewriteTarget('Home', 'WikiSource/Getting-Started.md'), 'index.md');
  assert.equal(rewriteTarget('Command-Reference', 'WikiSource/Getting-Started.md'), 'Command-Reference.md');
  const wikiNames = new Set(['Command-Reference', 'Command-Invoke-DscRunner', 'Resource-Properties']);
  assert.equal(rewriteTarget('Command-Invoke-DscRunner', 'WikiSource/Command-Reference.md', { wikiNames }), 'Command-Invoke-DscRunner.md');
  assert.equal(rewriteTarget('Resource-Properties', 'WikiSource/Command-Invoke-DscRunner.md', { wikiNames }), 'Resource-Properties.md');
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
  assert.equal(rewriteTarget('../containers/dsc-agent/README.md', 'docs/hosted-agent-dsc-v3.md'), `${GITHUB}containers/dsc-agent/README.md`);
  assert.equal(rewriteTarget('../.github/workflows/DscV3-HostedAgent.yml', 'docs/hosted-agent-dsc-v3.md'), `${GITHUB}.github/workflows/DscV3-HostedAgent.yml`);
  assert.equal(rewriteTarget('Example%20Policy%20Configuration', 'README.md'), `${TREE}Example%20Policy%20Configuration`);
  assert.equal(rewriteTarget('../Example%20Policy%20Configuration', 'docs/capability-policy.md'), `${TREE}Example%20Policy%20Configuration`);
  assert.equal(rewriteTarget('scripts', 'README.md'), `${TREE}scripts`);
  assert.equal(rewriteTarget('scripts/', 'README.md'), `${TREE}scripts`);
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
  assert.equal(rewriteLinks('under [`containers/dsc-agent`](../containers/dsc-agent/README.md) if', 'docs/hosted-agent-dsc-v3.md'), `under [\`containers/dsc-agent\`](${GITHUB}containers/dsc-agent/README.md) if`);
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

test('the README header follows the site colour scheme instead of the operating system', () => {
  const readme = fs.readFileSync(path.join(repository, 'README.md'), 'utf8');
  assert.match(readme, /<picture>/);
  const home = homePage(readme);
  assert.doesNotMatch(home, /<picture>|<source /);
  assert.match(home, /^<h1 class="site-header">\n/, 'the header stays the page heading');
  assert.match(home, /<img src="assets\/header-light\.svg" alt="[^"]+" class="only-light" height="120">/);
  assert.match(home, /<img src="assets\/header-dark\.svg" alt="[^"]+" class="only-dark" height="120">/);
  assert.match(home, /<img src="assets\/how-it-works\.gif"/);
  assert.equal(siteHeader('# No header image\n'), '# No header image\n');
});

test('the site source holds every page and the assets, with no link into the repository left', () => {
  const out = temporary();
  const pages = build(out, null);
  assert.ok(pages.includes('index.md'));
  for (const page of ['contributing.md', 'security.md', 'changelog.md', 'wiki/index.md', 'wiki/Command-Reference.md']) assert.ok(pages.includes(page), `${page} is not on the site`);
  const guides = fs.readdirSync(path.join(repository, 'docs')).filter((entry) => entry.endsWith('.md'));
  for (const guide of guides) assert.ok(pages.includes(`guides/${guide}`), `docs/${guide} is not on the site`);
  const wikiPages = fs.readdirSync(path.join(repository, 'WikiSource')).filter((entry) => entry.endsWith('.md') && entry !== 'Home.md');
  for (const page of wikiPages) assert.ok(pages.includes(`wiki/${page}`), `WikiSource/${page} is not on the site`);
  for (const asset of ['logo.svg', 'logo-dark.svg', 'logo-512.png', 'header-light.svg', 'header-dark.svg', 'how-it-works.gif', 'site.css']) {
    assert.ok(fs.existsSync(path.join(out, 'assets', asset)), `assets/${asset} is not on the site`);
  }
  for (const page of pages) {
    const text = fs.readFileSync(path.join(out, page), 'utf8');
    assert.doesNotMatch(text, /\]\((\.\.\/)*(docs|WikiSource)\//, `${page} still links into the repository`);
    if (page.startsWith('wiki/')) {
      for (const name of wikiPages.map((entry) => entry.slice(0, -3)).concat('Home', 'Command-Reference')) {
        assert.doesNotMatch(text, new RegExp(`\\]\\(${name}[)#]`), `${page} still holds a wiki-style link to ${name}`);
      }
    }
  }
  // Without the generated wiki content, the command reference points at the GitHub wiki.
  assert.match(fs.readFileSync(path.join(out, 'wiki', 'Command-Reference.md'), 'utf8'), new RegExp(GITHUB_WIKI.replace(/[.]/g, '\\.')));
  fs.rmSync(out, { recursive: true, force: true });
});

test('the generated command reference is copied onto the site when it is given', () => {
  const wikiContent = wikiContentFixture();
  const out = temporary();
  const pages = build(out, wikiContent);
  assert.ok(pages.includes('wiki/Command-Reference.md'));
  assert.ok(pages.includes('wiki/Command-Invoke-Thing.md'));
  assert.ok(!pages.includes('wiki/Home.md') && !pages.includes('wiki/_Sidebar.md'), 'only the command pages come from the generated content');
  assert.equal(fs.readFileSync(path.join(out, 'wiki', 'Command-Reference.md'), 'utf8'), '# Command reference\n\n- [Invoke-Thing](Command-Invoke-Thing.md) — does a thing.\n');
  assert.equal(fs.readFileSync(path.join(out, 'wiki', 'Command-Invoke-Thing.md'), 'utf8'), '# Invoke-Thing\n\nSee [Resource properties](Resource-Properties.md) and [the index](Command-Reference.md).\n');
  // The wiki pages themselves come from WikiSource, not from the generated copy.
  assert.equal(fs.readFileSync(path.join(out, 'wiki', 'index.md'), 'utf8').startsWith('# Home\n\n`Dsc.PipelineRunner`'), true);
  fs.rmSync(out, { recursive: true, force: true });
  fs.rmSync(wikiContent, { recursive: true, force: true });
});

// The pages mkdocs.yml lists, in order, with the top-level section each belongs to.
function navigation() {
  const lines = fs.readFileSync(path.join(repository, 'mkdocs.yml'), 'utf8').split('\n');
  const start = lines.findIndex((line) => /^nav:/.test(line));
  assert.ok(start >= 0, 'mkdocs.yml has no nav');
  const entries = [];
  let section = null;
  for (const line of lines.slice(start + 1)) {
    if (/^\S/.test(line)) break;
    const heading = /^  - ([^:]+):\s*$/.exec(line);
    if (heading) section = heading[1];
    const page = /^\s+- (?:[^:]+: )?(\S+\.md)\s*$/.exec(line);
    if (page) entries.push({ page: page[1], section });
  }
  return entries;
}

test('the navigation lists every page of the site exactly once, and every listed page exists', () => {
  const entries = navigation();
  const listed = entries.map((entry) => entry.page);
  assert.ok(listed.length >= 30, `only ${listed.length} pages are in the navigation`);
  assert.deepEqual(listed.filter((page, at) => listed.indexOf(page) !== at), [], 'a page is listed twice');
  const out = temporary();
  const pages = build(out, null);
  for (const page of listed) assert.ok(pages.includes(page), `${page} is in the navigation but not on the site`);
  for (const page of pages) assert.ok(listed.includes(page), `${page} is on the site but not in the navigation`);
  fs.rmSync(out, { recursive: true, force: true });
});

test('the wiki pages keep the order WikiSource/.pageorder declares', () => {
  const order = fs.readFileSync(path.join(repository, 'WikiSource', '.pageorder'), 'utf8').split('\n')
    .map((line) => line.trim()).filter((line) => line && !line.startsWith('#'))
    .map((name) => (name === 'Home' ? 'wiki/index.md' : `wiki/${name}.md`));
  const entries = navigation();
  const wikiEntries = entries.filter((entry) => entry.page.startsWith('wiki/') && entry.page !== 'wiki/Command-Reference.md');
  assert.deepEqual(new Set(wikiEntries.map((entry) => entry.page)), new Set(order), 'the navigation and .pageorder list different wiki pages');
  // Within each section, the wiki pages follow .pageorder; the reference section lists most of them.
  for (const section of new Set(wikiEntries.map((entry) => entry.section))) {
    const inSection = wikiEntries.filter((entry) => entry.section === section).map((entry) => entry.page);
    assert.deepEqual(inSection, order.filter((page) => inSection.includes(page)), `the wiki pages under "${section}" are not in .pageorder order`);
  }
  const reference = wikiEntries.filter((entry) => /reference/i.test(entry.section));
  assert.ok(reference.length >= 10, 'the reference section lists the wiki pages');
  assert.equal(entries.find((entry) => entry.page === 'wiki/Command-Reference.md').section, reference[0].section, 'the command reference sits with the wiki pages');
});

test('the Pages workflow runs when anything the site is built from changes', () => {
  const workflow = fs.readFileSync(path.join(repository, '.github', 'workflows', 'Pages.yml'), 'utf8');
  for (const trigger of ['README.md', 'CONTRIBUTING.md', 'SECURITY.md', 'CHANGELOG.md', 'docs/**', 'WikiSource/**', 'assets/**', 'source/Public/**', 'scripts/Build-WikiContent.ps1', 'mkdocs.yml', 'tools/build-site.js', 'tools/site-requirements.txt', '.github/workflows/Pages.yml']) {
    assert.match(workflow, new RegExp(`^\\s+- ${trigger.replace(/[.*]/g, '\\$&')}\\s*$`, 'm'), `${trigger} does not trigger the Pages workflow`);
  }
});
