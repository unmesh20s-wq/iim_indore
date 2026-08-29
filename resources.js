const resourceGrid = document.querySelector('[data-resource-grid]');

if (resourceGrid) {
  const library = Array.isArray(window.RESOURCE_LIBRARY) ? window.RESOURCE_LIBRARY : [];
  const categories = Array.isArray(window.RESOURCE_CATEGORIES) ? window.RESOURCE_CATEGORIES : ['All'];
  const filterList = document.querySelector('[data-resource-filters]');
  const searchInput = document.querySelector('[data-resource-search]');
  const status = document.querySelector('[data-resource-status]');
  const emptyState = document.querySelector('[data-resource-empty]');
  const emptyTitle = emptyState.querySelector('[data-empty-title]');
  const emptyCopy = emptyState.querySelector('[data-empty-copy]');
  const resetButton = emptyState.querySelector('[data-resource-reset]');
  let activeCategory = 'All';

  const normalize = (value) => String(value || '').trim().toLowerCase();

  const matchesCategory = (resource) => {
    if (activeCategory === 'All') return true;
    if (activeCategory === '180DC Originals') return resource.original === true;
    return resource.category === activeCategory;
  };

  const matchesSearch = (resource, query) => {
    if (!query) return true;

    const searchableText = [
      resource.title,
      resource.category,
      resource.description,
      resource.type,
      resource.source,
      ...(resource.tags || []),
    ].map(normalize).join(' ');

    return query.split(/\s+/).every((term) => searchableText.includes(term));
  };

  const createMeta = (label, value) => {
    const wrapper = document.createElement('div');
    const term = document.createElement('dt');
    const detail = document.createElement('dd');

    term.textContent = label;
    detail.textContent = value;
    wrapper.append(term, detail);
    return wrapper;
  };

  const createResourceCard = (resource) => {
    const card = document.createElement('article');
    const labels = document.createElement('div');
    const category = document.createElement('p');
    const type = document.createElement('span');
    const title = document.createElement('h2');
    const description = document.createElement('p');
    const metadata = document.createElement('dl');
    const action = document.createElement('a');

    card.className = 'resource-card';
    if (resource.featured) card.classList.add('resource-card--featured');

    labels.className = 'resource-card__labels';
    category.className = 'resource-card__category';
    category.textContent = resource.category;
    type.className = 'resource-card__type';
    type.textContent = resource.type;
    labels.append(category, type);

    title.textContent = resource.title;
    description.className = 'resource-card__description';
    description.textContent = resource.description;

    metadata.className = 'resource-card__meta';
    metadata.append(
      createMeta('Source', resource.source),
      createMeta('Access', resource.access === 'internal-hosted' ? 'Hosted by 180DC' : 'Official source'),
    );

    action.className = 'resource-card__action';
    action.href = resource.url;
    action.textContent = resource.access === 'internal-hosted' ? 'Read guide' : 'View official source';

    if (resource.access === 'external-link') {
      action.target = '_blank';
      action.rel = 'noreferrer';
      action.setAttribute('aria-label', `${action.textContent}: ${resource.title} (opens in a new tab)`);
    } else {
      action.setAttribute('aria-label', `${action.textContent}: ${resource.title}`);
    }

    card.append(labels, title, description, metadata, action);
    return card;
  };

  const renderResources = () => {
    const query = normalize(searchInput.value);
    const results = library
      .filter((resource) => matchesCategory(resource) && matchesSearch(resource, query))
      .sort((a, b) => Number(b.featured) - Number(a.featured));

    resourceGrid.replaceChildren(...results.map(createResourceCard));
    emptyState.hidden = results.length !== 0;
    resourceGrid.hidden = results.length === 0;

    const resourceLabel = results.length === 1 ? 'resource' : 'resources';
    status.textContent = `Showing ${results.length} ${resourceLabel} of ${library.length}.`;

    if (results.length === 0) {
      if (query) {
        emptyTitle.textContent = 'No matching resources.';
        emptyCopy.textContent = 'Try a broader search or choose another category.';
      } else {
        emptyTitle.textContent = 'Resources coming soon.';
        emptyCopy.textContent = 'We are currently curating high-quality material for this section.';
      }
    }
  };

  categories.forEach((categoryName) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'resource-filter';
    button.textContent = categoryName;
    button.setAttribute('aria-pressed', String(categoryName === activeCategory));

    button.addEventListener('click', () => {
      activeCategory = categoryName;
      filterList.querySelectorAll('button').forEach((filterButton) => {
        filterButton.setAttribute('aria-pressed', String(filterButton === button));
      });
      renderResources();
    });

    filterList.append(button);
  });

  searchInput.addEventListener('input', renderResources);
  resetButton.addEventListener('click', () => {
    activeCategory = 'All';
    searchInput.value = '';
    filterList.querySelectorAll('button').forEach((button) => {
      button.setAttribute('aria-pressed', String(button.textContent === 'All'));
    });
    renderResources();
    searchInput.focus();
  });

  renderResources();
}
