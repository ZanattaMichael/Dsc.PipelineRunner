// Reveals the blocks of a page as they scroll into view (assets/site.css, .reveal). Only for
// readers who have not asked for reduced motion, and only when the browser can observe
// visibility; otherwise this does nothing and every block is visible from the start.
(function () {
  'use strict';
  var motion = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: no-preference)') : null;
  if (!motion || !motion.matches || !('IntersectionObserver' in window)) return;
  var article = document.querySelector('.md-content__inner.md-typeset');
  if (!article) return;
  var blocks = Array.prototype.filter.call(article.children, function (element) {
    return /^(H2|H3|P|UL|OL|TABLE|PRE|BLOCKQUOTE|DIV|DETAILS)$/.test(element.tagName) && !element.classList.contains('site-hero');
  });
  if (!blocks.length) return;
  document.documentElement.classList.add('site-reveal');
  var observer = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (!entry.isIntersecting) return;
      entry.target.classList.add('is-visible');
      observer.unobserve(entry.target);
    });
  }, { rootMargin: '0px 0px -6% 0px', threshold: 0 });
  blocks.forEach(function (element) {
    element.classList.add('reveal');
    observer.observe(element);
  });
  // If the reader turns reduced motion on while the page is open, show everything at once.
  var stop = function () {
    if (motion.matches) return;
    observer.disconnect();
    document.documentElement.classList.remove('site-reveal');
  };
  if (motion.addEventListener) motion.addEventListener('change', stop);
})();
