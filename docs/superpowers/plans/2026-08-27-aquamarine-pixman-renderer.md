# Aquamarine Pixman Software Renderer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the per-frame `drmGetDevice failed` retry loop on Hyper-V and add `CPixmanRenderer` + `IRenderer::isSoftware()` so Hyprland enters a clean, logged software mode when no GPU render node exists.

**Architecture:** Two-part patch to `hyprwm/aquamarine`: Part 1 adds `rendererInitFailed` flag to stop the retry loop; Part 2 introduces `IRenderer` base class, `CPixmanRenderer` (drm_dumb + pixman probe), and `IBackendImplementation::isRenderingSoftware()`. A matching Hyprland patch reads `isRenderingSoftware()` and forces `LIBGL_ALWAYS_SOFTWARE=1` before EGL init. All changes ship as patch files + custom PKGBUILDs in this repo while upstream PRs are reviewed.

**Tech Stack:** C++23, CMake, libdrm, pixman-1 (already a declared aquamarine dep), EGL/GLES3, Arch Linux `makepkg`

> **Note:** All compile/run/test steps execute on the Arch Linux VM (ssh or terminal), not Windows. The patch files and PKGBUILDs produced there are then committed from the hypr-enhanced-session repo on either machine.

---

## File Map

**aquamarine dev clone (`/tmp/aq-dev/aquamarine`):**
| Action | Path | Purpose |
|--------|------|---------|
| Create | `include/aquamarine/backend/IRenderer.hpp` | New `IRenderer` base class |
| Modify | `include/aquamarine/backend/DRM.hpp` | Change renderer type, add flag + method |
| Modify | `include/aquamarine/backend/Backend.hpp` | Add `isRenderingSoftware()` to `IBackendImplementation` |
| Modify | `src/backend/drm/Renderer.hpp` | `CDRMRenderer : public IRenderer` |
| Modify | `src/backend/drm/Renderer.cpp` | Update `blit()` call sites |
| Modify | `src/backend/drm/DRM.cpp` | Retry flag logic, pixman fallback, downcast fixes |
| Create | `src/backend/drm/PixmanRenderer.hpp` | `CPixmanRenderer` declaration |
| Create | `src/backend/drm/PixmanRenderer.cpp` | `CPixmanRenderer::attempt()` impl |

**Hyprland dev clone (`/tmp/aq-dev/Hyprland`):**
| Action | Path | Purpose |
|--------|------|---------|
| Modify | `src/Compositor.cpp` | `isRenderingSoftware()` check before OpenGL init |

**This repo (hypr-enhanced-session):**
| Action | Path | Purpose |
|--------|------|---------|
| Create | `patches/aquamarine-part1-renderer-init-failed.patch` | Part 1 patch |
| Create | `patches/aquamarine-part2-pixman-renderer.patch` | Part 2 patch |
| Create | `patches/hyprland-software-mode.patch` | Hyprland patch |
| Create | `pkgbuilds/aquamarine/PKGBUILD` | Custom aquamarine build |
| Create | `pkgbuilds/hyprland/PKGBUILD` | Custom hyprland build |

---

## Task 1: Set up aquamarine dev environment on the VM

**Files:** none yet

- [ ] **Step 1: Record installed versions**

```bash
pacman -Q aquamarine hyprland
# Example output: aquamarine 0.4.6-1  hyprland 0.46.2-1
# Note both version strings — you'll need them for git checkout
```

- [ ] **Step 2: Clone aquamarine and check out the installed version**

```bash
mkdir -p /tmp/aq-dev && cd /tmp/aq-dev
git clone https://github.com/hyprwm/aquamarine.git
cd aquamarine
# Replace TAG with the version from Step 1 (e.g. v0.4.6)
git checkout v$(pacman -Q aquamarine | awk '{print $2}' | cut -d- -f1)
git checkout -b pixman-renderer
```

- [ ] **Step 3: Install build dependencies**

```bash
sudo pacman -S --needed cmake ninja pixman libdrm mesa libgbm wayland wayland-protocols libinput libseat hyprutils
```

- [ ] **Step 4: Verify aquamarine builds cleanly from source**

```bash
cd /tmp/aq-dev/aquamarine
cmake -B build -DCMAKE_BUILD_TYPE=Release -G Ninja
ninja -C build
```

Expected: build succeeds with no errors. Fix any dependency issues before continuing.

- [ ] **Step 5: Commit baseline**

```bash
git log --oneline -1   # note the commit hash as your baseline
```

---

## Task 2: Create IRenderer base class header

**Files:**
- Create: `include/aquamarine/backend/IRenderer.hpp`
- Modify: `include/aquamarine/backend/DRM.hpp` (add include)

- [ ] **Step 1: Write IRenderer.hpp**

Create `/tmp/aq-dev/aquamarine/include/aquamarine/backend/IRenderer.hpp`:

```cpp
#pragma once

#include <vector>
#include <aquamarine/backend/Misc.hpp>

namespace Aquamarine {
    /*
     * Abstract base for aquamarine DRM renderers.
     * CDRMRenderer implements GPU-backed compositing via EGL/GBM.
     * CPixmanRenderer implements a software fallback for KMS-only devices
     * (e.g. hyperv_drm) that have no DRM render node.
     */
    class IRenderer {
      public:
        virtual ~IRenderer() = default;

        /*
         * Returns true when the renderer uses CPU software compositing
         * instead of a GPU render node. Callers (e.g. Hyprland) use this
         * to force LIBGL_ALWAYS_SOFTWARE=1 for their own EGL context.
         */
        virtual bool isSoftware() const { return false; }

        /* GL/EGL formats this renderer can handle. Empty for software renderers. */
        std::vector<SGLFormat> formats;
    };
}
```

- [ ] **Step 2: Add the include to DRM.hpp**

Open `include/aquamarine/backend/DRM.hpp`. Find the forward declaration:
```cpp
class CDRMRenderer;
```
Add the IRenderer include just above it:
```cpp
#include <aquamarine/backend/IRenderer.hpp>
class CDRMRenderer;
```

- [ ] **Step 3: Verify the header compiles in isolation**

```bash
cd /tmp/aq-dev/aquamarine
echo '#include "include/aquamarine/backend/IRenderer.hpp"' > /tmp/test_irenderer.cpp
g++ -std=c++23 -Iinclude -I/usr/include/pixman-1 \
    $(pkg-config --cflags pixman-1) \
    -c /tmp/test_irenderer.cpp -o /tmp/test_irenderer.o
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
cd /tmp/aq-dev/aquamarine
git add include/aquamarine/backend/IRenderer.hpp include/aquamarine/backend/DRM.hpp
git commit -m "feat: introduce IRenderer abstract base class"
```

---

## Task 3: Make CDRMRenderer inherit IRenderer

**Files:**
- Modify: `src/backend/drm/Renderer.hpp`
- Modify: `src/backend/drm/Renderer.cpp`

- [ ] **Step 1: Update Renderer.hpp — inherit and remove duplicate `formats`**

Open `src/backend/drm/Renderer.hpp`. Change the class declaration from:
```cpp
class CDRMRenderer {
```
to:
```cpp
class CDRMRenderer : public IRenderer {
```

Add the IRenderer include near the top of the file (after existing includes):
```cpp
#include <aquamarine/backend/IRenderer.hpp>
```

Find and remove the `formats` member (it's now inherited from `IRenderer`):
```cpp
std::vector<SGLFormat>                        formats;   // DELETE THIS LINE
```

The `SBlitResult` struct, `self`, and all other members stay exactly as-is.

- [ ] **Step 2: Update Renderer.cpp — fix `formats` references if any**

```bash
grep -n "->formats\|\.formats\b" src/backend/drm/Renderer.cpp
```

If any references exist to `renderer->formats` or similar inside `Renderer.cpp`, verify they still compile — they should, since `formats` is inherited. No code changes needed here unless the compiler reports an error.

- [ ] **Step 3: Build to verify inheritance compiles**

```bash
cd /tmp/aq-dev/aquamarine
ninja -C build 2>&1 | head -40
```

Expected: zero errors. The only change visible to the compiler is that `CDRMRenderer` now has an extra vtable entry (`isSoftware()`) and `formats` comes from the base.

- [ ] **Step 4: Commit**

```bash
git add src/backend/drm/Renderer.hpp
git commit -m "feat: CDRMRenderer inherits IRenderer"
```

---

## Task 4: Change rendererState.renderer type and fix DRM.cpp call sites

**Files:**
- Modify: `include/aquamarine/backend/DRM.hpp`
- Modify: `src/backend/drm/DRM.cpp`

- [ ] **Step 1: Change renderer field type in DRM.hpp**

Open `include/aquamarine/backend/DRM.hpp`. Find the `rendererState` struct (look for the comment `// may be null if creation fails`):

```cpp
struct {
    Hyprutils::Memory::CSharedPointer<IAllocator>   allocator;
    Hyprutils::Memory::CSharedPointer<CDRMRenderer> renderer; // may be null if creation fails
} rendererState;
```

Change `CDRMRenderer` to `IRenderer`:
```cpp
struct {
    Hyprutils::Memory::CSharedPointer<IAllocator>  allocator;
    Hyprutils::Memory::CSharedPointer<IRenderer>   renderer; // may be null if creation fails
} rendererState;
```

- [ ] **Step 2: Fix the `self` assignments in DRM.cpp**

The old code sets `rendererState.renderer->self = rendererState.renderer` in two places (`initMgpu()` and `onReady()`). Since `IRenderer` has no `self` field, these must downcast. Search:

```bash
grep -n "rendererState.renderer->self" src/backend/drm/DRM.cpp
```

For each match, replace:
```cpp
rendererState.renderer->self = rendererState.renderer;
```
with:
```cpp
if (auto drm = std::dynamic_pointer_cast<CDRMRenderer>(rendererState.renderer))
    drm->self = drm;
```

- [ ] **Step 3: Fix the blit call sites in DRM.cpp**

Search for all `rendererState.renderer->blit(` usages:

```bash
grep -n "rendererState.renderer->blit\|->blit(" src/backend/drm/DRM.cpp
```

Each blit call is inside a `shouldBlit()` guard (only reached when a real CDRMRenderer is present). Replace the direct call with a downcast. For the regular buffer blit (around line 2176):

Find:
```cpp
SP<Aquamarine::CDRMRenderer> primaryRenderer;
if (backend->primary)
    primaryRenderer = backend->primary->rendererState.renderer;
auto blitResult = backend->rendererState.renderer->blit(
    STATE.buffer, NEWAQBUF, primaryRenderer, ...);
```

Replace with:
```cpp
SP<CDRMRenderer> primaryRenderer;
if (backend->primary)
    primaryRenderer = std::dynamic_pointer_cast<CDRMRenderer>(backend->primary->rendererState.renderer);
auto drmRenderer = std::dynamic_pointer_cast<CDRMRenderer>(backend->rendererState.renderer);
auto blitResult  = drmRenderer->blit(
    STATE.buffer, NEWAQBUF, primaryRenderer, ...);
```

For the cursor blit (around line 2400+), apply the same pattern: `std::dynamic_pointer_cast<CDRMRenderer>(backend->rendererState.renderer)->blit(...)`.

- [ ] **Step 4: Fix the initMgpu() return-value assignment**

In `initMgpu()`, find:
```cpp
rendererState.renderer = CDRMRenderer::attempt(backend.lock(), gpu->renderNodeFd >= 0 ? gpu->renderNodeFd : gpu->fd);
```
The right-hand side returns `SP<CDRMRenderer>`, which is now implicitly convertible to `SP<IRenderer>` via `std::dynamic_pointer_cast` — but actually since `CDRMRenderer` inherits `IRenderer`, assigning `SP<CDRMRenderer>` to `SP<IRenderer>` works directly via the shared_ptr copy constructor. No change needed here.

- [ ] **Step 5: Build**

```bash
cd /tmp/aq-dev/aquamarine
ninja -C build 2>&1 | head -60
```

Expected: zero errors. Fixup any remaining `SP<CDRMRenderer>` / `SP<IRenderer>` mismatches the compiler reports.

- [ ] **Step 6: Commit**

```bash
git add include/aquamarine/backend/DRM.hpp src/backend/drm/DRM.cpp
git commit -m "feat: change rendererState.renderer type to SP<IRenderer>"
```

---

## Task 5: Add isRenderingSoftware() to IBackendImplementation and CDRMBackend

**Files:**
- Modify: `include/aquamarine/backend/Backend.hpp`
- Modify: `include/aquamarine/backend/DRM.hpp`
- Modify: `src/backend/drm/DRM.cpp`

- [ ] **Step 1: Add default to IBackendImplementation**

Open `include/aquamarine/backend/Backend.hpp`. Inside `IBackendImplementation`, after the last `virtual` declaration (before the closing `};`):

```cpp
/* Returns true when this backend is rendering in software mode
 * (no GPU render node available). Hyprland uses this to force
 * LIBGL_ALWAYS_SOFTWARE=1 before creating its EGL context. */
virtual bool isRenderingSoftware() const { return false; }
```

- [ ] **Step 2: Add rendererInitFailed flag and declaration to CDRMBackend in DRM.hpp**

Open `include/aquamarine/backend/DRM.hpp`. Inside `CDRMBackend`, find `rendererRequired`:
```cpp
bool rendererRequired = true;
```

Add two lines below it:
```cpp
bool rendererRequired   = true;
bool rendererInitFailed = false;   // set after CDRMRenderer + CPixmanRenderer both fail
virtual bool isRenderingSoftware() const override;
```

- [ ] **Step 3: Implement isRenderingSoftware() in DRM.cpp**

Open `src/backend/drm/DRM.cpp`. Near the `shouldBlit()` implementation:
```cpp
bool Aquamarine::CDRMBackend::shouldBlit() {
    return !!primary;
}
```

Add immediately after:
```cpp
bool Aquamarine::CDRMBackend::isRenderingSoftware() const {
    return rendererState.renderer && rendererState.renderer->isSoftware();
}
```

- [ ] **Step 4: Build**

```bash
ninja -C build 2>&1 | head -40
```

Expected: zero errors.

- [ ] **Step 5: Commit**

```bash
git add include/aquamarine/backend/Backend.hpp include/aquamarine/backend/DRM.hpp src/backend/drm/DRM.cpp
git commit -m "feat: add isRenderingSoftware() to IBackendImplementation and CDRMBackend"
```

---

## Task 6: Implement CPixmanRenderer

**Files:**
- Create: `src/backend/drm/PixmanRenderer.hpp`
- Create: `src/backend/drm/PixmanRenderer.cpp`

- [ ] **Step 1: Write PixmanRenderer.hpp**

Create `src/backend/drm/PixmanRenderer.hpp`:

```cpp
#pragma once

#include <aquamarine/backend/IRenderer.hpp>
#include <hyprutils/memory/SharedPtr.hpp>
#include <pixman.h>

namespace Aquamarine {
    class CBackend;

    /*
     * Software renderer for KMS-only devices (no DRM render node).
     * Uses a drm_dumb buffer + pixman as a probe that the KMS device is
     * functional. Actual compositing is performed by Hyprland via Mesa
     * llvmpipe (forced by LIBGL_ALWAYS_SOFTWARE=1 when isSoftware() is true).
     */
    class CPixmanRenderer : public IRenderer {
      public:
        ~CPixmanRenderer();

        static Hyprutils::Memory::CSharedPointer<CPixmanRenderer>
            attempt(Hyprutils::Memory::CSharedPointer<CBackend> backend, int drmFD);

        bool isSoftware() const override { return true; }

      private:
        CPixmanRenderer() = default;

        int             drmFD      = -1;
        uint32_t        dumbHandle = 0;
        void*           map        = nullptr;
        size_t          mapSize    = 0;
        pixman_image_t* image      = nullptr;

        Hyprutils::Memory::CWeakPointer<CBackend> backend;
    };
}
```

- [ ] **Step 2: Write PixmanRenderer.cpp**

Create `src/backend/drm/PixmanRenderer.cpp`:

```cpp
#include "PixmanRenderer.hpp"
#include <aquamarine/backend/Backend.hpp>
#include <xf86drm.h>
#include <drm/drm_mode.h>
#include <sys/mman.h>
#include <cstring>
#include <format>

using namespace Aquamarine;
using namespace Hyprutils::Memory;

#define SP CSharedPointer

CPixmanRenderer::~CPixmanRenderer() {
    if (image)
        pixman_image_unref(image);
    if (map && map != MAP_FAILED)
        munmap(map, mapSize);
    if (dumbHandle && drmFD >= 0) {
        struct drm_mode_destroy_dumb destroy{};
        destroy.handle = dumbHandle;
        drmIoctl(drmFD, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
    }
}

SP<CPixmanRenderer> CPixmanRenderer::attempt(SP<CBackend> backend_, int drmFD) {
    // --- probe: create a 1×1 dumb buffer to verify the device is functional ---
    struct drm_mode_create_dumb create{};
    create.width  = 1;
    create.height = 1;
    create.bpp    = 32;

    if (drmIoctl(drmFD, DRM_IOCTL_MODE_CREATE_DUMB, &create) < 0) {
        backend_->log(AQ_LOG_ERROR, "CPixmanRenderer: DRM_IOCTL_MODE_CREATE_DUMB failed — device cannot allocate dumb buffers");
        return nullptr;
    }

    // --- map it so we have a real CPU-accessible surface ---
    struct drm_mode_map_dumb mapDumb{};
    mapDumb.handle = create.handle;

    if (drmIoctl(drmFD, DRM_IOCTL_MODE_MAP_DUMB, &mapDumb) < 0) {
        backend_->log(AQ_LOG_ERROR, "CPixmanRenderer: DRM_IOCTL_MODE_MAP_DUMB failed");
        struct drm_mode_destroy_dumb destroy{};
        destroy.handle = create.handle;
        drmIoctl(drmFD, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
        return nullptr;
    }

    const size_t mapSz = create.pitch * create.height;
    void*        ptr   = mmap(nullptr, mapSz, PROT_READ | PROT_WRITE, MAP_SHARED, drmFD, mapDumb.offset);
    if (ptr == MAP_FAILED) {
        backend_->log(AQ_LOG_ERROR, "CPixmanRenderer: mmap of dumb buffer failed");
        struct drm_mode_destroy_dumb destroy{};
        destroy.handle = create.handle;
        drmIoctl(drmFD, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
        return nullptr;
    }

    // --- create a pixman image over the mapped buffer ---
    pixman_image_t* img = pixman_image_create_bits(
        PIXMAN_a8r8g8b8,
        static_cast<int>(create.width),
        static_cast<int>(create.height),
        static_cast<uint32_t*>(ptr),
        static_cast<int>(create.pitch));

    if (!img) {
        backend_->log(AQ_LOG_ERROR, "CPixmanRenderer: pixman_image_create_bits failed");
        munmap(ptr, mapSz);
        struct drm_mode_destroy_dumb destroy{};
        destroy.handle = create.handle;
        drmIoctl(drmFD, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
        return nullptr;
    }

    auto renderer       = SP<CPixmanRenderer>(new CPixmanRenderer());
    renderer->backend   = backend_;
    renderer->drmFD     = drmFD;
    renderer->dumbHandle = create.handle;
    renderer->map       = ptr;
    renderer->mapSize   = mapSz;
    renderer->image     = img;
    // formats stays empty: software compositing via Mesa llvmpipe does not
    // need aquamarine's GL format list.

    backend_->log(AQ_LOG_DEBUG, "CPixmanRenderer: initialized software renderer via dumb buffer + pixman");
    return renderer;
}
```

- [ ] **Step 3: Build**

```bash
cd /tmp/aq-dev/aquamarine
ninja -C build 2>&1 | head -60
```

Expected: zero errors. Fix any include path issues (`pixman.h` should be found via `pkg-config --cflags pixman-1` which CMake already links).

- [ ] **Step 4: Commit**

```bash
git add src/backend/drm/PixmanRenderer.hpp src/backend/drm/PixmanRenderer.cpp
git commit -m "feat: implement CPixmanRenderer (drm_dumb + pixman software probe)"
```

---

## Task 7: Wire pixman fallback into initMgpu() and fix updateSecondaryRendererState()

**Files:**
- Modify: `src/backend/drm/DRM.cpp`

- [ ] **Step 1: Add PixmanRenderer include to DRM.cpp**

Open `src/backend/drm/DRM.cpp`. Find the existing DRM includes (lines near the top):
```cpp
#include "Renderer.hpp"
```

Add after it:
```cpp
#include "PixmanRenderer.hpp"
```

- [ ] **Step 2: Update updateSecondaryRendererState() to short-circuit on permanent failure**

Find the block in `updateSecondaryRendererState()` that handles the non-secondary (primary) case:

```cpp
if (!primary) {
    if (rendererState.renderer && rendererState.allocator)
        return true;

    return initMgpu();
}
```

Replace with:
```cpp
if (!primary) {
    if (rendererInitFailed)
        return true;  // permanently failed — don't retry, don't log

    if (rendererState.renderer && rendererState.allocator)
        return true;

    return initMgpu();
}
```

- [ ] **Step 3: Update initMgpu() to try pixman after CDRMRenderer fails**

Find the block in `initMgpu()`:
```cpp
rendererState.renderer = CDRMRenderer::attempt(backend.lock(), gpu->renderNodeFd >= 0 ? gpu->renderNodeFd : gpu->fd);

if (!rendererState.renderer) {
    backend->log(AQ_LOG_ERROR, "drm: initMgpu: no renderer");
    return false;
}
```

Replace with:
```cpp
rendererState.renderer = CDRMRenderer::attempt(backend.lock(), gpu->renderNodeFd >= 0 ? gpu->renderNodeFd : gpu->fd);

if (!rendererState.renderer) {
    backend->log(AQ_LOG_WARNING, "drm: initMgpu: CDRMRenderer unavailable (no render node?) — trying CPixmanRenderer software fallback");
    rendererState.renderer = CPixmanRenderer::attempt(backend.lock(), gpu->renderNodeFd >= 0 ? gpu->renderNodeFd : gpu->fd);
    if (!rendererState.renderer) {
        backend->log(AQ_LOG_ERROR, "drm: initMgpu: CPixmanRenderer fallback also failed — no renderer available, will not retry");
        rendererInitFailed = true;
        return false;
    }
    backend->log(AQ_LOG_WARNING, "drm: running in software (pixman) mode — GPU render node unavailable");
}
```

- [ ] **Step 4: Build**

```bash
ninja -C build 2>&1 | head -60
```

Expected: zero errors.

- [ ] **Step 5: Commit**

```bash
git add src/backend/drm/DRM.cpp
git commit -m "feat: add rendererInitFailed flag and CPixmanRenderer fallback in initMgpu()"
```

---

## Task 8: Full build and smoke test on the VM

**Files:** none

- [ ] **Step 1: Build and install locally**

```bash
cd /tmp/aq-dev/aquamarine
ninja -C build
sudo ninja -C build install
```

This installs the patched `libaquamarine.so` to `/usr/local/lib` (or whichever prefix CMake uses). Verify:

```bash
ls -la /usr/local/lib/libaquamarine*
```

- [ ] **Step 2: Restart Hyprland to pick up the new library**

```bash
# From a root shell (already established from previous sessions):
pkill -x Hyprland
# SDDM autologin will relaunch it — wait ~3 seconds, then reconnect RDP
```

- [ ] **Step 3: Verify the fix in logs**

```bash
grep -E "drmGetDevice failed|Can't create renderer|pixman|software.*mode|initMgpu" \
    ~/.local/share/hyprland/hyprland.log | head -20
```

Expected:
- `CDRMRenderer(drm): drmGetDevice failed` appears at most **once or twice** (the startup probe in `onReady()`), never again
- `drm: initMgpu: CDRMRenderer unavailable` appears once
- `CPixmanRenderer: initialized software renderer via dumb buffer + pixman` appears once
- `drm: running in software (pixman) mode` appears once

NOT expected: any of those lines repeating at high frequency.

- [ ] **Step 4: Verify no per-second spam**

```bash
sleep 5
wc -l ~/.local/share/hyprland/hyprland.log
sleep 5
wc -l ~/.local/share/hyprland/hyprland.log
# The line count should grow by at most ~50 lines in 5 seconds (normal idle activity),
# not by thousands (the old spam rate was ~200 lines/sec).
```

---

## Task 9: Generate aquamarine patch files

**Files:**
- Create: `patches/aquamarine-part1-renderer-init-failed.patch`
- Create: `patches/aquamarine-part2-pixman-renderer.patch`

- [ ] **Step 1: Find the commit SHAs that separate Part 1 from Part 2**

```bash
cd /tmp/aq-dev/aquamarine
git log --oneline
# You should see commits like:
#   <sha6>  feat: add rendererInitFailed flag and CPixmanRenderer fallback in initMgpu()
#   <sha5>  feat: implement CPixmanRenderer (drm_dumb + pixman software probe)
#   <sha4>  feat: add isRenderingSoftware() to IBackendImplementation and CDRMBackend
#   <sha3>  feat: change rendererState.renderer type to SP<IRenderer>
#   <sha2>  feat: CDRMRenderer inherits IRenderer
#   <sha1>  feat: introduce IRenderer abstract base class
#   <base>  <original version commit>
```

Part 1 = commits sha1 + sha2 + sha3 + sha4 + sha5 + sha6 (everything)
Actually treat the whole set as two logical patches: `IRenderer+CDRMRenderer` changes (tasks 2-5) and `CPixmanRenderer+initMgpu` changes (tasks 6-7).

- [ ] **Step 2: Generate Part 1 patch (IRenderer + rendererState type change + flags)**

```bash
# Part 1: commits for IRenderer, CDRMRenderer inheritance, type change, flags
# (all commits except PixmanRenderer.hpp/cpp and initMgpu wiring)
git format-patch <base-sha>..<sha4> --stdout \
    > /path/to/hypr-enhanced-session/patches/aquamarine-part1-renderer-init-failed.patch
```

Replace `<base-sha>` with the commit hash before your first change and `<sha4>` with the `isRenderingSoftware()` commit.

- [ ] **Step 3: Generate Part 2 patch (CPixmanRenderer + initMgpu wiring)**

```bash
git format-patch <sha4>..<sha6> --stdout \
    > /path/to/hypr-enhanced-session/patches/aquamarine-part2-pixman-renderer.patch
```

Replace `<sha4>` and `<sha6>` with the appropriate commit hashes.

- [ ] **Step 4: Verify patches apply cleanly from scratch**

```bash
cd /tmp/aq-dev
git clone https://github.com/hyprwm/aquamarine.git aquamarine-verify
cd aquamarine-verify
git checkout v$(pacman -Q aquamarine | awk '{print $2}' | cut -d- -f1)
git apply /path/to/hypr-enhanced-session/patches/aquamarine-part1-renderer-init-failed.patch
git apply /path/to/hypr-enhanced-session/patches/aquamarine-part2-pixman-renderer.patch
cmake -B build -G Ninja && ninja -C build
```

Expected: applies and builds cleanly.

---

## Task 10: Hyprland side — detect software mode and force LIBGL_ALWAYS_SOFTWARE

**Files:**
- Modify: `src/Compositor.cpp` (in Hyprland dev clone)

- [ ] **Step 1: Clone Hyprland at the installed version**

```bash
cd /tmp/aq-dev
git clone https://github.com/hyprwm/Hyprland.git
cd Hyprland
git checkout v$(pacman -Q hyprland | awk '{print $2}' | cut -d- -f1)
git checkout -b software-mode
```

- [ ] **Step 2: Add the software-mode check in Compositor.cpp**

Open `src/Compositor.cpp`. Find the `STAGE_BASICINIT` case:

```cpp
case STAGE_BASICINIT: {
    Log::logger->log(Log::DEBUG, "Creating the CHyprOpenGLImpl!");
    g_pHyprOpenGL = makeUnique<CHyprOpenGLImpl>();
```

Insert BEFORE the `CHyprOpenGLImpl` construction (after the `case STAGE_BASICINIT: {` line):

```cpp
case STAGE_BASICINIT: {
    // If the aquamarine DRM backend has no GPU render node, force Mesa software
    // rendering (llvmpipe) BEFORE EGL is initialised. This must happen here —
    // after eglInitialize() it is too late.
    for (const auto& impl : g_pCompositor->m_aqBackend->getImplementations()) {
        if (impl->isRenderingSoftware()) {
            Log::logger->log(Log::WARN,
                "Aquamarine: no GPU render node available — enabling software (llvmpipe) rendering mode");
            setenv("LIBGL_ALWAYS_SOFTWARE", "1", /* overwrite */ 1);
            break;
        }
    }

    Log::logger->log(Log::DEBUG, "Creating the CHyprOpenGLImpl!");
    g_pHyprOpenGL = makeUnique<CHyprOpenGLImpl>();
```

No new includes are needed — `getImplementations()` and `isRenderingSoftware()` are on types already available in Compositor.cpp via `<aquamarine/backend/Backend.hpp>` (pulled in transitively). If the compiler complains, add:

```cpp
#include <aquamarine/backend/Backend.hpp>
```

near the top of `Compositor.cpp` with the other aquamarine includes.

- [ ] **Step 3: Build Hyprland to verify it compiles**

```bash
cd /tmp/aq-dev/Hyprland
cmake -B build -DCMAKE_BUILD_TYPE=Release -G Ninja \
    -DCMAKE_PREFIX_PATH=/usr/local   # so it finds our patched aquamarine
ninja -C build src/Compositor.cpp.o  # build just the changed TU first
```

Expected: compiles without errors.

- [ ] **Step 4: Generate Hyprland patch**

```bash
cd /tmp/aq-dev/Hyprland
git add src/Compositor.cpp
git commit -m "feat: force LIBGL_ALWAYS_SOFTWARE when aquamarine reports software renderer mode"
git format-patch HEAD~1 --stdout \
    > /path/to/hypr-enhanced-session/patches/hyprland-software-mode.patch
```

---

## Task 11: Write aquamarine PKGBUILD

**Files:**
- Create: `pkgbuilds/aquamarine/PKGBUILD`

- [ ] **Step 1: Get the AUR PKGBUILD as a base**

```bash
mkdir -p /path/to/hypr-enhanced-session/pkgbuilds/aquamarine
cd /tmp
# Use asp or paru to get the current PKGBUILD
asp export aquamarine 2>/dev/null || \
    curl -sL "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=aquamarine" \
    -o /tmp/aquamarine-PKGBUILD
```

- [ ] **Step 2: Write the PKGBUILD with patches applied**

Create `pkgbuilds/aquamarine/PKGBUILD`. Start from the base and add our patches:

```bash
# Maintainer: hypr-enhanced-session project
# Based on the official aquamarine package

pkgname=aquamarine-hyprv
pkgver=<VERSION>            # fill from pacman -Q aquamarine
pkgrel=2                    # bump from official
pkgdesc="A hyprland rendering backend (patched: pixman software renderer for hyperv_drm)"
arch=(x86_64)
url="https://github.com/hyprwm/aquamarine"
license=(BSD-3-Clause)
depends=(
    libglvnd
    libdrm
    mesa
    libinput
    pixman
    hyprutils
)
makedepends=(cmake ninja git wayland-protocols)
source=(
    "aquamarine-${pkgver}.tar.gz::https://github.com/hyprwm/aquamarine/archive/v${pkgver}.tar.gz"
    "../../patches/aquamarine-part1-renderer-init-failed.patch"
    "../../patches/aquamarine-part2-pixman-renderer.patch"
)
# Update sha256sums after writing:
# sha256sums=('SKIP' 'SKIP' 'SKIP')
sha256sums=('SKIP' 'SKIP' 'SKIP')

prepare() {
    cd "aquamarine-${pkgver}"
    git apply "${srcdir}/../../patches/aquamarine-part1-renderer-init-failed.patch"
    git apply "${srcdir}/../../patches/aquamarine-part2-pixman-renderer.patch"
}

build() {
    cmake -B build -S "aquamarine-${pkgver}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -G Ninja
    ninja -C build
}

package() {
    DESTDIR="${pkgdir}" ninja -C build install
    install -Dm644 "aquamarine-${pkgver}/LICENSE" \
        "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
}
```

Replace `<VERSION>` with the exact version string from `pacman -Q aquamarine | awk '{print $2}' | cut -d- -f1`.

Note: the `source=()` paths use relative paths to the patch files assuming `makepkg` is run from `pkgbuilds/aquamarine/`. Alternatively, use absolute paths or copy the patches into `pkgbuilds/aquamarine/`.

- [ ] **Step 3: Test the PKGBUILD**

```bash
cd /path/to/hypr-enhanced-session/pkgbuilds/aquamarine
# Copy patches here for makepkg to find them:
cp ../../patches/aquamarine-part*.patch .
makepkg --syncdeps --noconfirm 2>&1 | tail -20
```

Expected: package builds successfully, produces `aquamarine-hyprv-<ver>-2-x86_64.pkg.tar.zst`.

- [ ] **Step 4: Install the package**

```bash
sudo pacman -U aquamarine-hyprv-*.pkg.tar.zst
```

---

## Task 12: Write Hyprland PKGBUILD

**Files:**
- Create: `pkgbuilds/hyprland/PKGBUILD`

- [ ] **Step 1: Create PKGBUILD**

Create `pkgbuilds/hyprland/PKGBUILD`:

```bash
pkgname=hyprland-hyprv
pkgver=<VERSION>            # fill from pacman -Q hyprland
pkgrel=2
pkgdesc="A dynamic tiling Wayland compositor (patched: software rendering mode for hyperv_drm)"
arch=(x86_64)
url="https://github.com/hyprwm/Hyprland"
license=(BSD-3-Clause)
depends=(
    aquamarine-hyprv          # our patched aquamarine
    wayland
    libdrm
    mesa
    libinput
    pixman
    hyprutils
    hyprwayland-scanner
)
makedepends=(cmake ninja git)
conflicts=(hyprland)
provides=(hyprland)
source=(
    "hyprland-${pkgver}.tar.gz::https://github.com/hyprwm/Hyprland/archive/v${pkgver}.tar.gz"
    "../../patches/hyprland-software-mode.patch"
)
sha256sums=('SKIP' 'SKIP')

prepare() {
    cd "Hyprland-${pkgver}"
    patch -Np1 < "${srcdir}/../../patches/hyprland-software-mode.patch"
}

build() {
    cmake -B build -S "Hyprland-${pkgver}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -G Ninja
    ninja -C build
}

package() {
    DESTDIR="${pkgdir}" ninja -C build install
    install -Dm644 "Hyprland-${pkgver}/LICENSE" \
        "${pkgdir}/usr/share/licenses/${pkgname}/LICENSE"
}
```

- [ ] **Step 2: Test the PKGBUILD**

```bash
cd /path/to/hypr-enhanced-session/pkgbuilds/hyprland
cp ../../patches/hyprland-software-mode.patch .
makepkg --syncdeps --noconfirm 2>&1 | tail -20
```

Expected: package builds successfully.

- [ ] **Step 3: Install**

```bash
sudo pacman -U hyprland-hyprv-*.pkg.tar.zst
```

---

## Task 13: Full integration test

**Files:** none

- [ ] **Step 1: Restart Hyprland with both patched packages**

```bash
pkill -x Hyprland
# Wait ~3 seconds for SDDM autologin, then reconnect via Enhanced Session
```

- [ ] **Step 2: Verify aquamarine software mode log**

```bash
grep -E "pixman|software.*mode|isRenderingSoft|CPixmanRenderer" \
    ~/.local/share/hyprland/hyprland.log | head -10
```

Expected lines (appear once each, not repeated):
```
CPixmanRenderer: initialized software renderer via dumb buffer + pixman
drm: running in software (pixman) mode — GPU render node unavailable
Aquamarine: no GPU render node available — enabling software (llvmpipe) rendering mode
```

- [ ] **Step 3: Verify zero per-frame spam**

```bash
grep -c "drmGetDevice failed" ~/.local/share/hyprland/hyprland.log
# Expected: 1 or 0 (the startup probe in onReady(), never again after that)
```

```bash
wc -l ~/.local/share/hyprland/hyprland.log; sleep 10; wc -l ~/.local/share/hyprland/hyprland.log
# Log should grow by <100 lines in 10 seconds of idle (was growing by ~400+)
```

- [ ] **Step 4: Verify LIBGL_ALWAYS_SOFTWARE is set in Hyprland's environment**

```bash
HPID=$(pgrep -x Hyprland)
strings /proc/$HPID/environ | grep LIBGL
# Expected: LIBGL_ALWAYS_SOFTWARE=1
```

- [ ] **Step 5: Verify Enhanced Session RDP still works**

Disconnect and reconnect via Hyper-V Enhanced Session. Desktop should appear, mouse and keyboard work, wayvnc service is running:

```bash
systemctl --user status wayvnc-attach.service
```

---

## Task 14: Commit everything to hypr-enhanced-session

**Files:** all patch files and PKGBUILDs

- [ ] **Step 1: Stage all new files**

```bash
cd /path/to/hypr-enhanced-session
git add patches/ pkgbuilds/
git status
```

Expected: 5 new files — 3 patches + 2 PKGBUILDs.

- [ ] **Step 2: Commit**

```bash
git commit -m "$(cat <<'EOF'
Add aquamarine + Hyprland patches for software renderer on Hyper-V

Part 1 (aquamarine): introduces IRenderer base class, changes
rendererState.renderer to SP<IRenderer>, adds rendererInitFailed flag
to CDRMBackend so the per-frame CDRMRenderer retry loop fires exactly
once and stops permanently on hyperv_drm.

Part 2 (aquamarine): adds CPixmanRenderer using drm_dumb + pixman as a
software fallback renderer; adds isRenderingSoftware() to
IBackendImplementation so callers can detect software mode.

Hyprland patch: reads isRenderingSoftware() in STAGE_BASICINIT and
sets LIBGL_ALWAYS_SOFTWARE=1 before CHyprOpenGLImpl is constructed,
giving a clean documented software mode logged at startup.

PKGBUILDs: aquamarine-hyprv and hyprland-hyprv apply the patches via
makepkg for local installation while upstream PRs are reviewed.

Fixes: per-frame drmGetDevice failed spam (~39/sec) on Hyper-V VMs
where hyperv_drm exposes no DRM render node.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: Open upstream PRs (when ready)**

After local validation is solid, open two PRs:

1. `hyprwm/aquamarine` — title: `drm: add IRenderer base, CPixmanRenderer software fallback, fix per-frame retry loop on KMS-only devices`
   - Part 1 and Part 2 can be separate commits in one PR
   - Reference: this is a semver-minor public API change (`rendererState.renderer` type changes)

2. `hyprwm/Hyprland` — title: `compositor: detect aquamarine software renderer mode and force LIBGL_ALWAYS_SOFTWARE`
   - Depends on aquamarine PR merging first, or include a version guard

---

## Self-Review Notes

- **IRenderer.hpp** is in `include/aquamarine/backend/` (public API) because `rendererState.renderer` is in the public `DRM.hpp` header and callers that store `SP<IRenderer>` need the type definition.
- **`formats` removal from CDRMRenderer** — confirmed it moves to `IRenderer`; all usages of `renderer->formats` continue to work via inheritance.
- **`self` downcast** — `CDRMRenderer::self` stays `WP<CDRMRenderer>` (used in buffer attachment comparisons); DRM.cpp sets it via `std::dynamic_pointer_cast<CDRMRenderer>(rendererState.renderer)->self = drm` — safe because this code only runs when `CDRMRenderer::attempt()` succeeded.
- **blit() downcasts** — only inside `shouldBlit()` guards, so `CPixmanRenderer` is never in scope at those sites.
- **`rendererInitFailed` early return** returns `true` (not false) — `updateSecondaryRendererState()` returning true means "state is fine, proceed" even when there's no renderer; returning false would trigger an error log on every frame.
- **LIBGL_ALWAYS_SOFTWARE must be set before `eglInitialize()`** — the check happens in `STAGE_BASICINIT` before `CHyprOpenGLImpl` is constructed, which is the correct point.
