# Aquamarine Pixman Software Renderer — Design Spec

**Date:** 2026-08-27  
**Status:** Approved  
**Target repos:** hyprwm/aquamarine (primary), hyprwm/Hyprland (secondary)  
**Local backport:** PKGBUILD patch in this repo while PRs are reviewed upstream

---

## Problem

On Hyper-V VMs running Hyprland, the `hyperv_drm` kernel driver exposes only a KMS
display node (`/dev/dri/card1`) with no DRM render node. Aquamarine's DRM backend
tries to initialise a `CDRMRenderer` (EGL/GBM based) on every frame commit via
`updateSecondaryRendererState()` → `initMgpu()`. Because no render node exists,
`drmGetDevice()` fails inside `CDRMRenderer::attempt()`. The function returns
`nullptr`, `rendererState.renderer` stays null, and the exact same probe fires again
on the next frame — roughly 5–39 times per second, producing continuous log spam,
burning CPU, and bloating the in-RAM `hyprland.log` without bound.

Mesa already falls back to llvmpipe (software GL) for the compositor itself, so
Hyprland runs, but clankily, and nothing is documented as "software mode."

There is an existing precedent in aquamarine: the EVDI (DisplayLink) driver is
detected in `registerGPU()` and given `rendererRequired = false` with the comment
"KMS without a usable EGL renderer." hyperv_drm needs the same treatment, but EVDI
works because a real primary GPU handles rendering behind it. For hyperv_drm as the
sole GPU, we need an actual software fallback renderer, not just a skip flag.

---

## Goals

1. Eliminate the per-frame retry loop entirely — `drmGetDevice failed` fires at most
   once (the initial startup probe), never again.
2. Introduce `CPixmanRenderer`: a CPU-backed renderer using pixman compositing and
   drm_dumb buffer allocation, usable on any KMS driver including hyperv_drm.
3. Expose `IRenderer::isSoftware() → bool` so Hyprland can detect software mode and
   force `LIBGL_ALWAYS_SOFTWARE=1` for its own EGL context, giving a clean, logged,
   documented "software mode" at the compositor level.
4. Zero regression on normal GPU systems (Intel/AMD/Nvidia/Nouveau).
5. Zero change to the EVDI path.

---

## Architecture

```
aquamarine (DRM backend)
├── CDRMBackend          ← adds rendererInitFailed flag  [Part 1]
├── CDRMRenderer         ← unchanged (existing GPU path)
├── CPixmanRenderer      ← NEW: pixman + drm_dumb        [Part 2]
└── IRenderer            ← adds isSoftware() → bool      [Part 2]

Hyprland (compositor)
└── renderer init path  ← reads isSoftware(), sets LIBGL_ALWAYS_SOFTWARE=1
```

Two PRs:
- **PR 1 (aquamarine):** all aquamarine changes (Parts 1 + 2 combined or split)
- **PR 2 (Hyprland):** read `isSoftware()`, force software GL when true

Local backport ships as a `.patch` file applied by the custom PKGBUILD in this repo.

---

## Components

### Part 1 — `rendererInitFailed` flag (~50 lines)

**`CDRMBackend`** (`src/backend/drm/DRM.cpp` / `DRM.hpp`):
- Add `bool rendererInitFailed = false` member.
- `updateSecondaryRendererState()`: if `rendererInitFailed` is set, return true
  immediately without calling `initMgpu()`.
- `initMgpu()`: on `CDRMRenderer` failure, set `rendererInitFailed = true`, log
  `"drm: GPU has no render node and EGL init failed — switching to software (pixman)
  mode"`, then immediately attempt `CPixmanRenderer::attempt()`.
  - If pixman succeeds: store in `rendererState.renderer`, clear `rendererInitFailed`.
  - If pixman fails: leave `rendererInitFailed = true`, log
    `"drm: pixman fallback also failed — no renderer available"`, return false.
    All future `updateSecondaryRendererState()` calls short-circuit via the flag.

### Part 2 — `CPixmanRenderer` (~350 lines)

**New files:** `src/backend/drm/PixmanRenderer.cpp`, `src/backend/drm/PixmanRenderer.hpp`

```cpp
class CPixmanRenderer : public IRenderer {
  public:
    static SP<CPixmanRenderer> attempt(SP<CBackend> backend, int drmFD);
    bool isSoftware() override { return true; }
    // ... same surface/blit interface as CDRMRenderer
  private:
    int                    drmFD   = -1;
    pixman_image_t*        surface = nullptr;
    uint32_t               dumbHandle, pitch, size;
    void*                  map     = nullptr;
};
```

Key implementation details:
- `attempt()` calls `DRM_IOCTL_MODE_CREATE_DUMB` (supported by all KMS drivers,
  including hyperv_drm) to allocate a CPU-accessible dumb buffer.
- Maps the buffer with `DRM_IOCTL_MODE_MAP_DUMB` + `mmap()`.
- Creates a `pixman_image_t` over the mapped memory for CPU compositing.
- Exports the buffer handle to KMS for scanout via standard DRM plane APIs.
- Supports ARGB8888 / XRGB8888 (the formats all KMS drivers guarantee).

**`IRenderer` interface (new — `include/aquamarine/backend/DRM.hpp`):**

`IRenderer` does not currently exist in aquamarine. `rendererState.renderer` is
typed `SP<CDRMRenderer>` in the public header. Part 2 introduces `IRenderer` as a
new abstract base and changes that field's type — this is a **semver-minor public
API change** (additive, but callers that stored `SP<CDRMRenderer>` directly will
need to update):

```cpp
// include/aquamarine/backend/DRM.hpp  (new)
class IRenderer {
  public:
    virtual ~IRenderer() = default;
    virtual bool isSoftware() { return false; }
    // minimal shared interface used by DRM.cpp (blit, formats)
};
```

```cpp
// rendererState struct (changed)
SP<IRenderer> renderer;   // was SP<CDRMRenderer>
```

`CDRMRenderer` gains `: public IRenderer` with default `isSoftware()`.  
`CPixmanRenderer` gains `: public IRenderer` with `isSoftware()` returning true.

### Hyprland side (~20 lines)

In the renderer initialisation path, after the aquamarine backend is ready:
```cpp
if (g_pCompositor->m_pAqBackend->getRenderer()->isSoftware()) {
    Debug::log(WARN, "No GPU render node — running in software (llvmpipe) mode");
    setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
}
// EGL context creation follows here
```

---

## Data Flow

### Startup (runs once)

```
CBackend::start()
  └── CDRMBackend::onReady()
        ├── CDRMRenderer::attempt(card1 fd)        → fails [logged ONCE]
        └── updateSecondaryRendererState()
              └── initMgpu()
                    ├── CDRMRenderer::attempt()    → fails
                    ├── rendererInitFailed = true
                    └── CPixmanRenderer::attempt(card1 fd)
                          ├── DRM_IOCTL_MODE_CREATE_DUMB  → succeeds
                          ├── mmap() dumb buffer
                          ├── pixman_image_create_bits()
                          └── stored in rendererState.renderer
                                rendererInitFailed = false

Hyprland: getRenderer()->isSoftware() == true
  └── setenv LIBGL_ALWAYS_SOFTWARE=1
  └── EGL context created via Mesa llvmpipe
```

### Per-frame (every commit, ~60/sec)

```
CDRMOutput::applyCommit()
  └── updateSecondaryRendererState()
        ├── rendererInitFailed? → false
        └── rendererState.renderer != null → return true  [no work done]

  └── shouldBlit()? → false (single GPU, no primary set)
        └── normal KMS scanout, no blit needed
```

`drmGetDevice failed` never appears again after the single startup probe.

---

## Error Handling & Edge Cases

| Scenario | Behaviour |
|---|---|
| `CPixmanRenderer::attempt()` fails (e.g., not DRM master) | `rendererInitFailed = true`, logged once, all future calls short-circuit via flag. Hyprland's existing pure-software Mesa path unchanged. |
| Hot-plug of a real GPU after startup | `updateSecondaryRendererState()` short-circuits (pixman already running). GPU promotion is out of scope; no regression. |
| Normal GPU system (Intel/AMD/Nvidia) | `CDRMRenderer::attempt()` succeeds → flag never set, pixman never called, `isSoftware()` returns false. Zero behaviour change. |
| EVDI (DisplayLink) | Returns true from `if (!rendererRequired)` guard before new code is reached. Zero change. |
| Multi-GPU system, one GPU has no render node | The GPU-without-render-node gets pixman; the GPU-with-render-node gets CDRMRenderer. Each backend's flag is independent. |

---

## Testing Plan

### aquamarine unit tests
- `CPixmanRenderer::attempt()` with a real `/dev/dri/card1` fd: dumb buffer creation
  succeeds, pixman surface initialises, `isSoftware()` returns true.
- `updateSecondaryRendererState()` with a pre-set `rendererInitFailed`: confirm it
  returns true immediately without calling `initMgpu()`.

### Integration (Hyper-V VM)
- Full Hyprland session: confirm zero `drmGetDevice failed` lines after the single
  startup probe.
- Confirm `isSoftware() == true` is logged by Hyprland.
- Confirm `LIBGL_ALWAYS_SOFTWARE=1` is in Hyprland's environment via `/proc/<pid>/environ`.
- Run the hypr-enhanced-session bridge and confirm RDP session connects and renders.

### Regression (native Intel/AMD desktop)
- Confirm `isSoftware() == false` logged.
- Confirm no new log noise, no behaviour change.
- Run aquamarine CI test suite; all existing tests pass.

---

## Delivery

| Item | Where |
|---|---|
| Part 1 patch file | `patches/aquamarine-rendererInitFailed.patch` |
| Part 2 patch file | `patches/aquamarine-pixman-renderer.patch` |
| Hyprland patch file | `patches/hyprland-software-mode.patch` |
| Custom PKGBUILD (aquamarine) | `pkgbuilds/aquamarine/PKGBUILD` |
| Custom PKGBUILD (hyprland) | `pkgbuilds/hyprland/PKGBUILD` |
| Upstream PR (aquamarine) | hyprwm/aquamarine — to be opened after local validation |
| Upstream PR (Hyprland) | hyprwm/Hyprland — to be opened after aquamarine PR merges |
