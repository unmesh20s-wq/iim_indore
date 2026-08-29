# 180 Degrees Consulting IIM Indore Demo

A responsive, self-contained website for the IIM Indore branch of 180 Degrees Consulting. It includes the main chapter site, a searchable student resource hub, and original 180DC guides.

## Preview

From this directory, run:

```powershell
python -m http.server 4173
```

Then open `http://localhost:4173`.

The resource hub is available at `http://localhost:4173/resources.html`.

## Resource Policy

Chapter-owned guides are hosted in `resources/`. Third-party resources remain on their official publisher domains and are linked from the structured catalog in `data/resources.js`.

Run `scripts/capture-sections.ps1` while the preview server is active to check the main site, resource interactions, and desktop/mobile guide layouts.

## Assets

The supplied source photographs are prepared for the web by `scripts/prepare-assets.ps1`. The source files in Downloads are not modified.
