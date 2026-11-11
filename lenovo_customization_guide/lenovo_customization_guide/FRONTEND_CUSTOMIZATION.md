# Frontend Customization Guide

This guide covers how to replace the NVIDIA branding with your own and make
other UI changes to the RAG Blueprint frontend.

---

## Architecture Overview

The frontend is a **React 19 + TypeScript** single-page application built with
Vite 6, TailwindCSS 4, and NVIDIA's KUI design system. It is deployed as a
container image that serves static files via a Node.js HTTP server and proxies
API calls to the backend.

Source code: `rag_blueprint_lenovo/frontend/`

### Key Directories

| Directory | Contents |
|-----------|----------|
| `src/assets/` | Static assets (logos, KUI design system package) |
| `src/components/icons/` | SVG icon components (including `NvidiaLogo.tsx`) |
| `src/components/layout/` | Header, Layout, StatusMessages |
| `src/components/chat/` | Chat interface components |
| `src/components/settings/` | Settings panel components |
| `src/pages/` | Route pages: Chat, NewCollection, SettingsPage |
| `public/` | Static public assets (favicon) |

---

## 1. Logo Replacement (Step-by-Step)

There are 4 files to change. Here is the complete procedure using a Lenovo logo
as an example — replace "Lenovo" with your brand name throughout.

### Files Changed

| # | File | Change |
|---|------|--------|
| 1 | `src/assets/your-logo.svg` | Add your logo SVG file |
| 2 | `src/components/icons/YourLogo.tsx` | New logo component |
| 3 | `src/components/layout/Header.tsx` | Switch import + update title text |
| 4 | `index.html` | Update page `<title>` |
| 5 | `public/favicon.ico` | Replace favicon (optional) |
| 6 | `src/components/layout/__tests__/Header.test.tsx` | Update test mock + assertions |

### Step 1: Add your logo SVG

Place your logo in `src/assets/`. Example:

```
src/assets/lenovo-logo.svg
```

### Step 2: Create the logo component

Create `src/components/icons/LenovoLogo.tsx`:

```tsx
import React from 'react';
import logoSrc from '../../assets/lenovo-logo.svg';

interface LenovoLogoProps {
  height?: string;
  alt?: string;
  className?: string;
}

export default function LenovoLogo({
  height = '20px',
  alt = 'Lenovo Logo',
  className = '',
}: LenovoLogoProps): React.ReactElement {
  return (
    <img
      src={logoSrc}
      alt={alt}
      height={height}
      className={className}
      style={{ display: 'block' }}
    />
  );
}
```

### Step 3: Update the Header

Edit `src/components/layout/Header.tsx`. Two changes:

**Change the import** (line 18):
```tsx
// Before:
import NvidiaLogo from "../icons/NvidiaLogo";

// After:
import LenovoLogo from "../icons/LenovoLogo";
```

**Change the logo usage** (line 65):
```tsx
// Before:
<NvidiaLogo height="20px" />

// After:
<LenovoLogo height="20px" />
```

**Change the title text** (line 68):
```tsx
// Before:
  RAG Blueprint

// After:
  Lenovo RAG Assistant
```

### Step 4: Update the page title

Edit `index.html`:

```html
<!-- Before: -->
<title>RAG Blueprint</title>

<!-- After: -->
<title>Lenovo RAG Assistant</title>
```

### Step 5: Replace the favicon (optional)

Replace `public/favicon.ico` with your brand's favicon (16x16, 32x32, 48x48).

### Step 6: Update the Header test

The test at `src/components/layout/__tests__/Header.test.tsx` mocks
`NvidiaLogo` and asserts on the text "RAG Blueprint". Both need updating:

**Update the mock** (line 23-26):
```tsx
// Before:
vi.mock('../../icons/NvidiaLogo', () => ({
  default: () => <svg data-testid="nv-logo-element">Logo</svg>
}));

// After:
vi.mock('../../icons/LenovoLogo', () => ({
  default: () => <img data-testid="logo-element" alt="Lenovo Logo" />
}));
```

**Update assertions** — find every `getByTestId('nv-logo-element')` and change
to `getByTestId('logo-element')`. Find every `getByText('RAG Blueprint')` and
change to `getByText('Lenovo RAG Assistant')`:

```tsx
// Before (appears 3 times):
expect(screen.getByTestId('nv-logo-element')).toBeInTheDocument();

// After:
expect(screen.getByTestId('logo-element')).toBeInTheDocument();

// Before (appears 2 times):
expect(screen.getByText('RAG Blueprint')).toBeInTheDocument();

// After:
expect(screen.getByText('Lenovo RAG Assistant')).toBeInTheDocument();
```

### Verify

```bash
cd frontend
pnpm install
pnpm run build          # TypeScript + Vite production build
pnpm run test:run       # All 656 tests should pass
```

### Notes

- `src/assets/logo.svg` exists in the upstream repo but is **not imported
  anywhere** — you can ignore or replace it for consistency.
- The original `NvidiaLogo.tsx` can be left in place (it becomes dead code)
  or deleted.
- Vite inlines small SVGs into the JavaScript bundle automatically, so the
  logo does not appear as a separate file in `dist/assets/`.

---

## 2. General Frontend Customization

### 2a. Color Theming

Colors come from three sources:

1. **KUI theme tokens** — NVIDIA's Kaizen UI design system (`@kui/react`).
   Provides the base palette, typography, and component styles. Override via
   CSS custom properties at `:root` in `src/index.css`.

2. **TailwindCSS utilities** — TailwindCSS 4 uses CSS-based config in
   `src/index.css`. Modify Tailwind's color palette there.

3. **Inline styles** — Some components use `style={{...}}` objects directly.

### 2b. Adding New Pages

Routing is defined in `src/App.tsx` using React Router:

```tsx
import NewPage from './pages/NewPage';

// Inside the router configuration:
<Route path="/new-page" element={<NewPage />} />
```

Add a navigation link in `Header.tsx` to make it accessible.

### 2c. Modifying the Chat Interface

Chat components are in `src/components/chat/`:

| Component | Purpose |
|-----------|---------|
| `ChatMessageBubble.tsx` | Individual message display |
| `MessageContent.tsx` | Message text rendering (markdown) |
| `MessageInput.tsx` | User input area |
| `MessageTextarea.tsx` | Text input field |
| `Citations.tsx` | Citation display below messages |
| `StreamingIndicator.tsx` | "Typing..." animation |

### 2d. Modifying the Settings Panel

Settings components are in `src/components/settings/`:

| Component | Purpose |
|-----------|---------|
| `SettingsContent.tsx` | Main settings layout |
| `RagConfigSection.tsx` | RAG pipeline settings (top_k, reranker, etc.) |
| `ModelsSection.tsx` | Model selection |
| `FeatureTogglesSection.tsx` | Feature on/off toggles |
| `EndpointsSection.tsx` | Backend endpoint configuration |
| `AdvancedSection.tsx` | Advanced settings |

To hide settings from end-users, comment out or conditionally render sections
in `SettingsContent.tsx`.

### 2e. State Management

Zustand stores in `src/store/`:

| Store | Purpose |
|-------|---------|
| `useSettingsStore` | RAG configuration (models, top_k, etc.) |
| `useChatStore` | Chat messages and conversation state |
| `useCollectionStore` | Document collection management |
| `useNotificationStore` | Toast/notification state |

---

## 3. Building and Deploying the Custom Frontend

### Local Development

```bash
cd frontend
pnpm install
pnpm run dev    # Starts Vite dev server on port 3000
```

### Building the Container Image

```bash
cd frontend

# Build with buildah (daemonless, recommended for Lenovo server)
buildah bud -t lenovo/rag-frontend:2.5.0-custom -f Dockerfile .

# Export and import to containerd
buildah push lenovo/rag-frontend:2.5.0-custom \
  docker-archive:/tmp/rag-frontend.tar
sudo ctr --namespace k8s.io images import /tmp/rag-frontend.tar
```

The `VITE_API_CHAT_URL` and `VITE_API_VDB_URL` variables have sensible
defaults in the Dockerfile (`http://rag-server:8081/v1` and
`http://ingestor-server:8082/v1`). Override with `--build-arg` only if your
service names or ports differ.

### Updating Helm to Use the Custom Frontend Image

In `deploy/helm/nvidia-blueprint-rag/values.yaml`:

```yaml
frontend:
  enabled: true
  image:
    repository: lenovo/rag-frontend
    tag: "2.5.0-custom"
    pullPolicy: IfNotPresent
```

Then upgrade the Helm release:

```bash
sudo k8s helm upgrade rag-server deploy/helm/nvidia-blueprint-rag/ \
  -f deploy/helm/nvidia-blueprint-rag/values.yaml \
  --namespace rag
```

---

## 4. Important Notes

- **The frontend does NOT contain any business logic.** It is a pure UI client
  that calls the RAG server and ingestor server via HTTP APIs. All RAG pipeline
  behavior is controlled by the backend.

- **The KUI design system is bundled as a .tgz archive** at
  `src/assets/kui-foundations-react-external-0.504.1.tgz`. If you replace KUI
  with your own design system, remove this dependency from `package.json`.

- **`VITE_` prefixed environment variables are baked in at build time** (Vite
  convention). The Node.js server in the Dockerfile also reads
  `VITE_API_CHAT_URL` and `VITE_API_VDB_URL` at runtime for proxying.

- **The Node.js server** routes `/api/generate`, `/api/summary`, and
  `/api/configuration` to the RAG server. All other `/api/*` routes go to the
  ingestor server. Update the CMD in the Dockerfile if you add new backend
  endpoints.
