const header = document.querySelector('[data-header]');
const menu = document.querySelector('[data-menu]');
const menuToggle = document.querySelector('[data-menu-toggle]');
const main = document.querySelector('main');
const footer = document.querySelector('footer');
const navGroups = Array.from(menu.querySelectorAll('[data-nav-group]'));

const closeNavGroups = () => {
  navGroups.forEach((group) => {
    group.removeAttribute('open');
    group.querySelector('summary').setAttribute('aria-expanded', 'false');
  });
};

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
  closeNavGroups();
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

navGroups.forEach((group) => {
  const summary = group.querySelector('summary');
  summary.setAttribute('aria-expanded', 'false');

  group.addEventListener('toggle', () => {
    summary.setAttribute('aria-expanded', String(group.open));
    if (!group.open) return;

    navGroups.forEach((otherGroup) => {
      if (otherGroup !== group) otherGroup.removeAttribute('open');
    });
  });
});

document.addEventListener('click', (event) => {
  if (!menu.contains(event.target)) closeNavGroups();
});

document.addEventListener('keydown', (event) => {
  if (event.key !== 'Escape') return;

  if (menuToggle.getAttribute('aria-expanded') === 'true') {
    closeMenu();
    menuToggle.focus();
    return;
  }

  const openGroup = navGroups.find((group) => group.open);
  if (!openGroup) return;

  openGroup.removeAttribute('open');
  openGroup.querySelector('summary').focus();
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

const carouselDelay = 5000;

document.querySelectorAll('[data-carousel]').forEach((carousel) => {
  const slides = Array.from(carousel.querySelectorAll('[data-carousel-slide]'));
  let activeIndex = 0;
  let rotationTimer = null;
  let carouselIsVisible = false;

  const clearRotation = () => {
    window.clearTimeout(rotationTimer);
    rotationTimer = null;
  };

  const preloadNextSlide = () => {
    const nextImage = slides[(activeIndex + 1) % slides.length].querySelector('img');
    if (nextImage) nextImage.loading = 'eager';
  };

  const showSlide = (requestedIndex) => {
    activeIndex = (requestedIndex + slides.length) % slides.length;

    slides.forEach((slide, index) => {
      const isActive = index === activeIndex;
      slide.classList.toggle('is-active', isActive);
      slide.setAttribute('aria-hidden', String(!isActive));
      slide.inert = !isActive;
    });

    preloadNextSlide();
  };

  const scheduleRotation = () => {
    clearRotation();
    if (!carouselIsVisible || document.hidden) return;

    rotationTimer = window.setTimeout(() => {
      showSlide(activeIndex + 1);
      scheduleRotation();
    }, carouselDelay);
  };

  const visibilityObserver = 'IntersectionObserver' in window
    ? new IntersectionObserver((entries) => {
      carouselIsVisible = entries[0].isIntersecting;
      scheduleRotation();
    }, { threshold: 0.1 })
    : null;

  if (visibilityObserver) {
    visibilityObserver.observe(carousel);
  } else {
    carouselIsVisible = true;
  }

  document.addEventListener('visibilitychange', scheduleRotation);

  showSlide(0);
  carousel.classList.add('is-ready');
  scheduleRotation();
});

const year = document.querySelector('[data-year]');
if (year) year.textContent = new Date().getFullYear();
