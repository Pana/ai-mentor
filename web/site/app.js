// 小熊伴学官网：手机菜单、导航阴影、滚动出现。没有 JS 时页面照常显示。
(() => {
  const nav = document.getElementById('nav');
  const menuBtn = document.getElementById('menu-btn');
  const links = document.getElementById('nav-links');

  const setMenu = (open) => {
    links.classList.toggle('open', open);
    menuBtn.setAttribute('aria-expanded', String(open));
    menuBtn.setAttribute('aria-label', open ? '关闭菜单' : '打开菜单');
  };
  menuBtn.addEventListener('click', () => setMenu(!links.classList.contains('open')));
  links.addEventListener('click', (e) => { if (e.target.closest('a')) setMenu(false); });

  const onScroll = () => nav.classList.toggle('scrolled', window.scrollY > 8);
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  if (!('IntersectionObserver' in window)) return;
  document.documentElement.classList.add('js');
  const targets = document.querySelectorAll('.feature, .assistant-demo, .soon-card, .trust, .device-list li, .cta-inner');
  const io = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add('in');
      io.unobserve(entry.target);
    }
  }, { rootMargin: '0px 0px -8% 0px' });
  targets.forEach((el) => { el.classList.add('reveal'); io.observe(el); });
})();
