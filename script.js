const header = document.querySelector('[data-header]');
const menu = document.querySelector('[data-menu]');
const menuToggle = document.querySelector('[data-menu-toggle]');
const main = document.querySelector('main');
const footer = document.querySelector('footer');

const setHeaderState = () => {
  header.classList.toggle('is-scrolled', window.scrollY > 24);
};

const closeMenu = () => {
  menu.classList.remove('is-open');
  header.classList.remove('is-open');
  menuToggle.setAttribute('aria-expanded', 'false');
  menuToggle.setAttribute('aria-label', 'Open menu');
  document.body.classList.remove('menu-open');
  main.removeAttribute('inert');
  footer.removeAttribute('inert');
};

menuToggle.addEventListener('click', () => {
  const isOpen = menuToggle.getAttribute('aria-expanded') === 'true';

  if (isOpen) {
    closeMenu();
    return;
  }

  menu.classList.add('is-open');
  header.classList.add('is-open');
  menuToggle.setAttribute('aria-expanded', 'true');
  menuToggle.setAttribute('aria-label', 'Close menu');
  document.body.classList.add('menu-open');
  main.setAttribute('inert', '');
  footer.setAttribute('inert', '');
  menu.querySelector('a').focus();
});

menu.querySelectorAll('a').forEach((link) => {
  link.addEventListener('click', closeMenu);
});

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    closeMenu();
    menuToggle.focus();
  }
});

const desktopNavigation = window.matchMedia('(min-width: 821px)');
desktopNavigation.addEventListener('change', (event) => {
  if (event.matches) closeMenu();
});

window.addEventListener('scroll', setHeaderState, { passive: true });
setHeaderState();

const revealItems = document.querySelectorAll('[data-reveal]');

if ('IntersectionObserver' in window) {
  const revealObserver = new IntersectionObserver((entries, observer) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;

      entry.target.classList.add('is-visible');
      observer.unobserve(entry.target);
    });
  }, {
    rootMargin: '0px 0px -10% 0px',
    threshold: 0.08,
  });

  revealItems.forEach((item) => revealObserver.observe(item));
} else {
  revealItems.forEach((item) => item.classList.add('is-visible'));
}

const year = document.querySelector('[data-year]');
if (year) year.textContent = new Date().getFullYear();
