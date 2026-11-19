#!/usr/bin/env node
'use strict';
// Checks every link in the built documentation site.
//
//   node tools/check-site.js site --site-url=/Dsc.PipelineRunner/ [--external]
//
// tools/build-site.js already fails on a relative link to something that is not in the repository.
// This checks what mdBook actually wrote: on every page, each link, image, stylesheet and script
// that points inside the site must exist, and each #fragment must be an id on the page it points
// at. Links to other sites are not fetched, so this cannot fail because someone else's server is
// down; --external lists them instead.
//
// --site-url is the path the site is served under (site-url in book.toml). A link that starts
// with it, as the links on the 404 page do, is looked up from the top of the built site.

const fs = require('node:fs');
const path = require('node:path');

// One page holding every chapter, for printing; each chapter is checked on its own.
const SKIP = new Set(['print.html']);

function htmlFiles(folder) {
  return fs.readdirSync(folder, { recursive: true, withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith('.html') && !SKIP.has(entry.name))
    .map((entry) => path.join(entry.parentPath ?? entry.path, entry.name))
    .sort();
}

function decodeEntities(value) {
  return value.replace(/&(amp|lt|gt|quot|#39|#x27);/g, (match, name) => ({ amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'", '#x27': "'" })[name]);
}

// The ids a page defines and the links it holds, outside <script> and <style>.
function parse(file) {
  const html = fs.readFileSync(file, 'utf8').replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, (match) => match.replace(/>[\s\S]*<\//, '></'));
  const ids = new Set();
  const links = [];
  for (const [, attributes] of html.matchAll(/<[a-zA-Z][\w-]*\b([^>]*)>/g)) {
    for (const [, name, value] of attributes.matchAll(/\s([a-zA-Z-]+)\s*=\s*"([^"]*)"/g)) {
      const lower = name.toLowerCase();
      if (lower === 'id' || lower === 'name') ids.add(decodeEntities(value));
      if (lower === 'href' || lower === 'src') links.push(decodeEntities(value));
    }
  }
  return { ids, links };
}

function check(site, siteUrl = '/') {
  const root = path.resolve(site);
  const base = siteUrl.replace(/^\/*|\/*$/g, '') ? `/${siteUrl.replace(/^\/*|\/*$/g, '')}/` : '/';
  if (!fs.existsSync(path.join(root, 'index.html'))) throw new Error(`${root} is not a built site: it has no index.html`);
  const pages = new Map(htmlFiles(root).map((file) => [file, parse(file)]));
  const failures = [];
  const external = new Set();
  let checked = 0;
  for (const [file, page] of [...pages]) {
    const here = path.relative(root, file);
    for (const link of page.links) {
      if (/^https?:/i.test(link)) { external.add(link); continue; }
      if (/^[a-z][a-z0-9+.-]*:/i.test(link) || link.startsWith('//')) continue; // mailto:, data:, javascript:
      checked += 1;
      const [beforeHash, fragment = ''] = link.split('#', 2);
      const linkPath = beforeHash.split('?')[0];
      let target;
      if (linkPath.startsWith('/')) {
        if (!linkPath.startsWith(base)) { failures.push(`${here}: leaves the site -> ${link}`); continue; }
        target = path.join(root, decodeURIComponent(linkPath.slice(base.length)));
      } else {
        target = linkPath ? path.resolve(path.dirname(file), decodeURIComponent(linkPath)) : file;
      }
      if (fs.existsSync(target) && fs.statSync(target).isDirectory()) target = path.join(target, 'index.html');
      if (!fs.existsSync(target)) { failures.push(`${here}: missing file -> ${link}`); continue; }
      if (!fragment || !target.endsWith('.html')) continue;
      if (!pages.has(target)) pages.set(target, parse(target));
      if (!pages.get(target).ids.has(decodeURIComponent(fragment))) failures.push(`${here}: missing anchor -> ${link}`);
    }
  }
  return { checked, pages: pages.size, failures, external: [...external].sort() };
}

if (require.main === module) {
  const args = process.argv.slice(2);
  const site = args.find((arg) => !arg.startsWith('--'));
  const siteUrl = (args.find((arg) => arg.startsWith('--site-url=')) || '--site-url=/').slice('--site-url='.length);
  if (!site) {
    console.error('usage: node tools/check-site.js <built site> [--site-url=/path/] [--external]');
    process.exit(2);
  }
  const result = check(site, siteUrl);
  if (args.includes('--external')) {
    for (const link of result.external) console.log(link);
    process.exit(0);
  }
  for (const failure of result.failures) console.error(failure);
  console.log(`checked ${result.checked} links in ${result.pages} pages, ${result.failures.length} broken; ${result.external.length} distinct external links not fetched`);
  process.exit(result.failures.length ? 1 : 0);
}

module.exports = { parse, check };
