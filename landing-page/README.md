# Unpeel: Ali's fork showcase

A standalone landing page focused on additions in https://github.com/alimazid/unpeel. It credits the original Unpeel project and UX Themes AS. No build dependencies.

## Preview

```sh
python3 -m http.server 4173 --directory dist --bind 127.0.0.1
```

Open http://127.0.0.1:4173. Deploy `dist/` to a static host; Sites identity is in `.openai/hosting.json`.

## Verified feature sources

- Explorer operations and sorting: `clients/native/UnpeelNative/Sources/UnpeelExplorer/`.
- Git history and nested repository selection: `clients/native/UnpeelNative/Sources/UnpeelGit/`.
- Markdown previews: `Sources/UnpeelMarkdownPreview/` and `docs/agents/clients/panes.md`.
- Completion snippets: commit `fed07b9`.
- Modified-date sorting: commit `c261dea`.
- Nested repository following: commit `f1062f7`.

All site images are unchanged test-repository captures from `docs/superpowers/verification/`. CSS provides detail crops; the screenshot viewer opens the full original. `explorer.png` predates the date column. The Git history image shows synthetic commits, not customer activity.

Design methods: Unslop by Damir Sokolovsky (CC BY 4.0) and Anti Slop by Miqdad Badjuber. See DESIGN.md. Fonts load from Google Fonts with system fallbacks. The original project's MIT license and trademark policy remain authoritative.
