// The sky behind every page (assets/site.css, .site-sky): faint lines that rise from three sources
// on the left and merge into one point on the right, the way the logo merges three configuration
// layers into one, over a grid of dots and three slow glows, with light travelling along three of
// the lines. It is inline SVG so the stylesheet colours it for each palette. Readers who ask for
// reduced motion get it still (the stylesheet turns the motion off); without JavaScript the page
// keeps its plain background.
(function () {
  'use strict';
  if (document.querySelector('.site-sky')) return;
  var ns = 'http://www.w3.org/2000/svg';
  var W = 1600, H = 1000, mx = 1400, my = 110;
  var el = function (name, attrs) {
    var node = document.createElementNS(ns, name);
    for (var key in attrs) node.setAttribute(key, attrs[key]);
    return node;
  };
  // A curve from (0, y) on the left edge to the merge point.
  var line = function (y) {
    return 'M-40 ' + y + 'C' + (W * 0.45) + ' ' + y + ' ' + (W * 0.6) + ' ' + my + ' ' + mx + ' ' + my;
  };
  var svg = el('svg', { viewBox: '0 0 ' + W + ' ' + H, preserveAspectRatio: 'xMidYMid slice', 'aria-hidden': 'true', focusable: 'false' });
  var defs = el('defs', {});
  var grid = el('pattern', { id: 'site-sky-grid', width: 36, height: 36, patternUnits: 'userSpaceOnUse' });
  grid.appendChild(el('circle', { cx: 18, cy: 18, r: 1.1, 'class': 'site-sky__dot' }));
  defs.appendChild(grid);
  ['a', 'b', 'c'].forEach(function (name) {
    var glow = el('radialGradient', { id: 'site-sky-glow-' + name });
    glow.appendChild(el('stop', { offset: '0', 'class': 'site-sky__stop-' + name, 'stop-opacity': '1' }));
    glow.appendChild(el('stop', { offset: '1', 'class': 'site-sky__stop-' + name, 'stop-opacity': '0' }));
    defs.appendChild(glow);
  });
  svg.appendChild(defs);
  var world = el('g', { 'class': 'site-sky__world' });
  world.appendChild(el('rect', { width: W, height: H, fill: 'url(#site-sky-grid)' }));
  [['a', 1250, 220, 420], ['b', 380, 780, 380], ['c', 1150, 880, 360]].forEach(function (g, i) {
    world.appendChild(el('circle', { cx: g[1], cy: g[2], r: g[3], fill: 'url(#site-sky-glow-' + g[0] + ')', 'class': 'site-sky__glow site-sky__glow--' + (i + 1) }));
  });
  var lines = el('g', { 'class': 'site-sky__lines' });
  [60, 180, 300, 420, 540, 660, 780, 900, 1020].forEach(function (y) {
    lines.appendChild(el('path', { d: line(y) }));
  });
  world.appendChild(lines);
  var light = el('g', {});
  [[180, 'a'], [540, 'b'], [900, 'c']].forEach(function (pair, i) {
    var style = 'animation-delay:' + (-i * 2.6) + 's';
    light.appendChild(el('path', { d: line(pair[0]), pathLength: 100, 'class': 'site-sky__pulse site-sky__pulse--soft site-sky__pulse--' + pair[1], style: style }));
    light.appendChild(el('path', { d: line(pair[0]), pathLength: 100, 'class': 'site-sky__pulse site-sky__pulse--sharp', style: style }));
  });
  world.appendChild(light);
  world.appendChild(el('circle', { cx: mx, cy: my, r: 22, 'class': 'site-sky__halo' }));
  world.appendChild(el('circle', { cx: mx, cy: my, r: 7, 'class': 'site-sky__point' }));
  svg.appendChild(world);
  var holder = document.createElement('div');
  holder.className = 'site-sky';
  holder.setAttribute('aria-hidden', 'true');
  holder.appendChild(svg);
  document.body.insertBefore(holder, document.body.firstChild);
  document.documentElement.classList.add('has-sky');
  // The sky leans a little towards the pointer, on devices that have one.
  var still = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (still || !window.matchMedia || !window.matchMedia('(pointer: fine)').matches) return;
  var pending = false, px = 0, py = 0;
  window.addEventListener('mousemove', function (event) {
    px = (event.clientX / window.innerWidth - 0.5) * 2;
    py = (event.clientY / window.innerHeight - 0.5) * 2;
    if (pending) return;
    pending = true;
    window.requestAnimationFrame(function () {
      world.style.transform = 'translate(' + (px * -10).toFixed(1) + 'px, ' + (py * -8).toFixed(1) + 'px)';
      pending = false;
    });
  }, { passive: true });
})();

// The logo beside the title in the top bar, and the pair as a link home. mdBook sets path_to_root on
// every page.
(function () {
  'use strict';
  var title = document.querySelector('.menu-title');
  if (!title || title.querySelector('.site-mark')) return;
  var root = typeof path_to_root === 'string' ? path_to_root : '';
  var img = document.createElement('img');
  img.className = 'site-mark';
  img.alt = '';
  img.width = 28;
  img.height = 28;
  img.src = root + 'assets/logo.svg';
  var home = document.createElement('a');
  home.className = 'site-home';
  home.href = root + 'index.html';
  home.setAttribute('aria-label', 'Dsc.PipelineRunner documentation home');
  home.appendChild(img);
  while (title.firstChild) home.appendChild(title.firstChild);
  title.appendChild(home);
})();

// Reveals the blocks of a page as they scroll into view (assets/site.css, .site-reveal). Only for
// readers who have not asked for reduced motion, and only when the browser can observe
// visibility; otherwise this does nothing and every block is visible from the start.
(function () {
  'use strict';
  var motion = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: no-preference)') : null;
  if (!motion || !motion.matches || !('IntersectionObserver' in window)) return;
  var main = document.querySelector('.content main');
  if (!main) return;
  var blocks = Array.prototype.filter.call(main.children, function (element) {
    return !/^(H1|SCRIPT|STYLE)$/.test(element.tagName) && !element.classList.contains('site-hero');
  });
  if (blocks.length < 3) return;
  var observer = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (!entry.isIntersecting) return;
      entry.target.classList.add('is-visible');
      observer.unobserve(entry.target);
    });
  }, { rootMargin: '0px 0px -6% 0px', threshold: 0 });
  blocks.forEach(function (element) {
    element.classList.add('site-reveal');
    observer.observe(element);
  });
  // A print, a jump to an anchor, or reduced motion turned on while the page is open never finds
  // hidden text.
  var showAll = function () {
    observer.disconnect();
    blocks.forEach(function (element) { element.classList.add('is-visible'); });
  };
  window.addEventListener('beforeprint', showAll);
  window.addEventListener('hashchange', showAll);
  if (location.hash) showAll();
  if (motion.addEventListener) motion.addEventListener('change', function () { if (!motion.matches) showAll(); });
})();
