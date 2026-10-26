# Sorty Website

Next.js marketing site for Sorty.

## Dependency security

Keep security overrides in `package.json` and `pnpm-lock.yaml` synchronized.
Preserve both `patchedDependencies` entries when updating dependencies, then
regenerate the lockfile with `pnpm install --lockfile-only --ignore-scripts`.
The GitHub Pages workflow validates and deploys website dependency updates.

Keep shadcn on a release that supports Zod 4 while the Zod security override
is present. Its stylesheet is imported by `app/globals.css`; forcing Zod 4
onto older shadcn releases breaks their declared dependency contract.

## Local Preview

```bash
pnpm install
portless
# -> https://sorty.localhost (portless.json name `sorty`; raw `pnpm dev` still works)
```

## Static Build

```bash
pnpm build
```

To preview the export with the same base path used by GitHub Pages:

```bash
pnpm build:pages
pnpm preview:pages
```

Open `http://localhost:3100/Sorty/`. Serving `out` directly from `/` will not
load its assets because the Pages build intentionally references `/Sorty`.

## Website copy

Use plain, friendly, specific language. Keep action labels consistent: Download
for Mac, Donate, and Copy prompt. Avoid absolute claims about undo or privacy;
describe the relevant feature and its data boundaries.

The homepage's “Ask your AI” section replaces the three standalone guides.
Prompts in `components/ai-prompts.tsx` point assistants to current official
website and GitHub documentation. Keep those source links current. Clipboard
failures reveal a selectable prompt so visitors can still copy it manually.
