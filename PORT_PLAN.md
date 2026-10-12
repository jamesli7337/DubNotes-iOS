# DubNotes iOS port plan

Where the Decisions (settled) section conflicts with anything above it, the settled section wins.

Source of truth for the web app: `jamesli7337/DubNotes` @ `85b09cb` (read via a throwaway clone outside this repo; no sibling `../DubNotes` and no `gh` on this machine).
`DubNotes_Architecture.md` does **not** exist in that repo. I used `CLAUDE.md` (architecture), `README.md` (feature list) and `DATA_FORMAT.md` (schema). Source files were opened only to confirm that "diagram mode" is the web app's **board / mind-map** mode (`Notebook.kind = 'board'`, bubbles, connectors).

Each feature is in exactly one bucket. Within a bucket, items are ordered by what blocks the most other work first.

"Port now" means it can be verified with CI builds, `xcodebuild test` (a test target does not exist yet; see Problems) and simulator screenshots of seeded data. "Needs the Mac" means it needs a real iPad/Pencil to judge, or Xcode-only setup.

---

## 1. Port now

1. **Data model** – Notebook, Page, Paper, Stroke, Folder, Divider, Asset, and the element kinds text/image/shape/tape as `Codable` structs mirroring DATA_FORMAT v11. Everything else reads or writes these.
2. **Backup JSON decode + `migrateToCurrent`** – parse `{app:"noteapp", version ≤ 11, …}` and run the v1→v11 migrations. Pure logic, unit-testable, and it is the only way to get real data in without a Mac (see decisions).
3. **Persistence layer** – on-device store with dirty tracking and flush on background. Pure data work. The storage tech is a decision.
4. **Trailing-blank-page invariant + page insert/delete renumbering** – rules every paged-notebook mutation depends on; unit-testable.
5. **Geometry helpers** – page units (820×1060 default, per-page `w`/`h`), point-in-polygon, bounds, rotated-frame transforms. Blocks selection, hit-testing and rendering.
6. **Stroke rendering** – `[x,y,pressure]` points to a filled outline (perfect-freehand algorithm), `"auto"` ink resolved from paper colour, pen vs highlighter. Judged by screenshot of seeded strokes, not by pen feel. Depends on the PencilKit decision.
7. **Paper templates** – blank/ruled/grid/dot × narrow/medium/wide × white/cream/dark, colour-aware ruling. Static drawing.
8. **Element rendering** – text (wrapping, `bg` tint), image, shapes (line/arrow/rect/ellipse/triangle), tape (covering), z-order by `createdAt` interleaved with strokes. Static drawing.
9. **Library screen** – notebook cards with page-preview thumbnails, create/rename/delete, ordering (move up/down), new notebooks on top. Layout is checkable by screenshot.
10. **Folders and dividers** – nested folders, delete moves contents up a level, "Move to folder…", labelled dividers sharing the notebook `order` sequence. Model and list UI.
11. **Covers** – colour plus five procedural patterns (dots, grid, stripes, waves, chevron). Procedural drawing, screenshot-checkable.
12. **Notebook page column (read-only first)** – vertical column of pages with paper, strokes and elements rendered. Establishes the page view that drawing, zoom and export build on.
13. **Paper menu** – per-page template/spacing/colour with "this page / all pages" scope; new page inherits the previous page's paper.
14. **Undo/redo model** – per-notebook stack, one step per user action, structural page adds excluded. The stack is testable; the buttons are trivial.
15. **Tool state and persistence** – current tool, per-tool colour/size, custom colours (max 8, newest first), eraser mode, lasso shape. Replaces `localStorage`; plain state plus `UserDefaults`/equivalent.
16. **Custom colour picker** – saturation/value square, hue strip, hex field. Standard SwiftUI; the drag math is screenshot-checkable.
17. **Eraser and lasso logic** – whole-stroke and partial erase (stroke splitting), polygon/box/circle selection, hit-testing, selection transforms. Algorithms are unit-testable; how they feel to use is not (their input handling is in bucket 2).
18. **Clipboard: copy / paste / duplicate** – in-app clipboard with nudge on same-page paste. Operates on the model.
19. **Image insert** – PHPicker (works in simulator), downscale to 1600 px, store inline, land centred on the page in view.
20. **PDF import** – PDFKit; store the file once as an asset, one page per PDF page with `background {assetId, page}`, per-page `w`/`h`, progress dialog. Simulator can load a bundled test PDF.
21. **PDF page rendering** – on-demand render with a small LRU and a failed-page memo; full-bleed centre-crop. Screenshot-checkable.
22. **Export** – vector PDF (Letter width; tapes export covering; Helvetica text), PNG/JPEG at 2×. `UIGraphicsPDFRenderer` makes this near-trivial. The share sheet is checkable in the simulator; actually saving to Files is not.
23. **Backup export** – write the v11 JSON back out, assets as base64, so data can round-trip with the web app.
24. **Zoom model (50–300 %, fit-width, 100 %, 200 %)** – the camera state and the percentage control. The pinch gesture itself is in bucket 2.
25. **Ruler and protractor drawing** – unit scales, tick marks, 10° rays, inner/outer scales, view-only. Drawing is screenshot-checkable; dragging and edge-snap are in bucket 2.
26. **Theme (system/light/dark chrome)** – the paper colour is independent. Native `ColorScheme`.
27. **Board / bubble / connector data model** – `Notebook.kind='board'`, chunked pages (`col`/`row`, 2048 units), bubble `members`, connector anchors and cached endpoints. Model only, so board backups decode and round-trip even if the canvas is parked.

## 2. Needs the Mac

Ordered by what blocks the most other work. Items with real-device judgement come first, then Xcode-only setup.

1. **Pen input capture** – `UITouch`/`PKCanvasView`/custom view receiving Pencil samples with pressure, coalesced and predicted touches. Everything that draws depends on this feeling right.
2. **Stroke smoothing (EMA 0.5 in screen space)** – tuned by how ink looks under the Pencil, not in a screenshot.
3. **Finger vs Pencil routing and palm rejection** – web has `palmTouchIds`, `stylusDown`, and a post-lift cooldown. Only a real hand resting on a real iPad can judge it.
4. **Camera gestures** – one-finger pan, pinch, momentum, rubber-band clamp. Gesture feel and the pan/zoom-while-drawing arbitration.
5. **Hold-to-snap (line and shape)** – 0.5 s ghost preview, 1.1 s commit, still-pen detection, draggable handles. Timing and jitter tolerance can't be judged without a Pencil.
6. **Shape recognition thresholds** – rect/ellipse/triangle/right-triangle, 12° square snap. Algorithm is portable, but the thresholds need real hand-drawn input to tune.
7. **Live eraser and lasso interaction** – translucent-until-lift preview, drawing the loop, drag-to-move/resize/rotate with the selection overlay. Needs the Pencil to judge latency and hit slop (`TAP_SLOP`, `ERASER_RADIUS`).
8. **Ruler edge-snap and protractor baseline-snap** – the pen stroke that starts beside the edge runs straight. Needs the Pencil; drag and rotate-grip feel included.
9. **Laser pointer** – 3.5 s fading trail. Judged by feel and latency.
10. **Text in-place editing** – tap-to-place, corner scale, Pencil-vs-keyboard focus. Hardware keyboard and Scribble behaviour only show on device.
11. **Tape peel/cover by tap** – trivial logic, but "any tool or a finger" conflicts with finger = pan; the arbitration needs a device.
12. **Apple Pencil system features** – double-tap / squeeze tool switching, hover. Not in the web app; listed so it isn't forgotten. Needs a Pencil that supports them.
13. **Board canvas and mind-map snap** – unbounded canvas, spatial index, loop-to-bubble snap, connectors between nodes. Same input requirements as bucket-2 items 1–7, so it comes after them. Parked unless you decide otherwise.
14. **Signing, provisioning, device install** – Xcode/Apple Developer setup. CI currently builds with signing off.
15. **iCloud sync (CloudKit / iCloud Drive)** – web explicitly has no sync; this is new. Capabilities and entitlements are Xcode-only.
16. **Sign in with Apple** – new; only needed if sync/accounts exist. Entitlement plus device test.
17. **StoreKit / purchases** – new; sandbox testing needs the Mac and App Store Connect.
18. **TestFlight / App Store Connect** – archive, upload, review. Mac only.
19. **Open-in / share-into-app for PDFs** – the web `share_target` becomes a document type + `onOpenURL` / Share extension. Extension targets and Files interaction need Xcode config and a device.
20. **Persistent-storage guarantees** – web needs `storage.persist()`; native gets this for free, but verifying data survives app updates and device restore needs a device.

## 3. Redesign (do not copy)

Ordered by what blocks the most other work.

1. **Store: singleton in-memory maps + 0.7 s debounced IndexedDB flush** – rebuild on the native persistence layer (Port-now item 3). The `Store` singleton, the two-instance HMR caveat and `db.ts` schema versions are web artefacts. Keep only the *format* (DATA_FORMAT) for import/export.
2. **Hash router (`#/nb/<id>`, `#/f/<id>`)** – replace with `NavigationStack` / `NavigationSplitView` and a native back stack. Back-to-folder behaviour is the only thing worth preserving.
3. **Two-canvas page rendering (cache + view) with quality/pixel-budget re-rasterisation** – web workaround for DOM canvas limits. Use native tiling / `CATiledLayer` or PencilKit/Metal and drop `canvasPixelFactor`.
4. **Custom camera as one CSS transform on `.nb-camera`, custom scrollbar thumb on `body`** – replace with `UIScrollView` zoom or a native equivalent. The "append overlays to `body` with `position: fixed`" pattern disappears entirely.
5. **Per-tool dock** – the web dock is a DOM toolbar with `switch (toolState.kind)`. Rebuild as a native iPad toolbar/floating palette. Behaviour of each tool is kept (bucket 1/2); the chrome is not copied.
6. **Library and notebook screens as DOM-built views** – rebuild in SwiftUI with native lists, context menus (replacing the ⋯ menus), and sheets (replacing the in-app dialog and `window.prompt` avoidance).
7. **Split screen / secondary pane (notebook beside notebook, PDF beside notebook, floating image overlay)** – web-specific second scroller. On iPad, Stage Manager and Split View already cover side-by-side. Re-decide the in-app version after the core is done; do not port `page-scroller.ts`.
8. **AI mode slide-out chat panel + Gemini proxy** – calls a Vercel function with a shared secret compiled into the client bundle. Do not ship that secret in a native binary. If kept, put it behind real auth; if not, drop it. `aiConversations`/`aiChats` are already outside the backup format.
9. **PWA shell: `manifest.webmanifest`, service worker, precache plugin, `sw-register`, icons generator** – replaced by the app bundle, asset catalog and launch screen.
10. **`localStorage` for tool and split state, `noteapp-split` second database** – replaced by `UserDefaults` / the persistence layer.
11. **Import/Export JSON buttons on the Library screen with "Import replaces all data"** – keep the format, rebuild the flow. Replace-all is dangerous on a native app with iCloud; make it merge or confirm per notebook (see decisions).
12. **`navigator.storage.persist()` indicator on the Library screen** – meaningless natively; remove.
13. **Dev tooling: Vite, Vercel/Pages/Cloudflare deploy, CDP test harness** – none carries over. The equivalent verification is XcodeGen + the CI build + simulator screenshots already in this repo.

---

## Decisions (settled)

1. Pen: PencilKit for pen, highlighter, eraser and lasso ink. Custom code for shapes, text, tape, images, ruler, protractor, pages, PDFs, AI. Strokes convert to/from the backup format on save/load. AI ink is a throwaway second PencilKit layer. Hold-to-snap during the stroke is dropped; snap after pen lift is kept.
2. Diagram/board mode: park the canvas, keep the data model so old boards import.
3. First data path: backup JSON import, using a small throwaway backup committed as a test file. Never commit real notes, backups, keys or secrets.
4. Storage: plain files, one folder per notebook, autosaved like Notability.
5. Import: add as new copies, never replace existing data.
6. No sync at launch (keep the file layout compatible with iCloud Drive later). AI launches. Order: core app, Sign in with Apple, daily limit, AI.
7. Add a test target and an xcodebuild test step in CI.
8. Page size: keep 820x1060 units; convert only on PDF/image export.
9. Minimum iOS 17.0.
10. Split screen: keep, built in-app (formula sheet beside the notebook), after the core works. Not tuned on the web anymore.
11. Screens: match the web app's current layout and look, screen by screen, using screenshots in design/ as the reference. Build with native iPad controls, not copied web markup. This overrides any 'redesign, do not copy' wording above for screen layout.

## Problems noticed (not fixed)

**Swift repo (`DubNotes-iOS`)**
- Commit `f5b7496` is titled "Launch app on iPad simulator in CI and upload screenshot", but it only changed `.gitattributes` (one line). `.github/workflows/build.yml` has just the build step: no simulator boot/launch and no screenshot upload. The "simulator screenshots" bucket-1 premise therefore isn't wired up yet.
- No test target in `project.yml`, so nothing in CI can run unit tests.
- The workflow only runs on `push` to `main` and `workflow_dispatch`; there is no `pull_request` trigger.
- `project.yml` sets `SWIFT_VERSION: "5.0"` and `CODE_SIGN_STYLE: Manual` with signing disabled. Both will need to change before TestFlight (bucket 2).
- App is still a "DubNotes" `Text` placeholder (`RootView.swift`).

**Old web repo (`jamesli7337/DubNotes`)**
- `README.md`'s feature list is stale relative to `DATA_FORMAT.md`/`CLAUDE.md`: it describes AI mode as a per-page toggle with auto-send after ~2 s and replies as page text boxes, while `CLAUDE.md` describes it as a per-notebook switch with ephemeral ink and a slide-out panel. It also does not mention boards or mind-map mode at all. Port from `CLAUDE.md`/`DATA_FORMAT.md` where they disagree.
- `README.md` says "Off-limits for now: search, sync", yet the data format carries AI chat stores that are deliberately outside backup, so chat history can't be moved to the iOS app via a backup file.
- `VITE_GEMINI_PROXY_SECRET` is compiled into the public bundle; the README itself acknowledges anyone can extract it, so the Gemini endpoint is only protected against casual scanners.
- `README.md` says `package-lock.json` should be committed ("creates package-lock.json (commit it)"); it is present, so this is only noise.
- The README's "Run the dev server" and "Deploy" sections hardcode `base: '/DubNotes/'`, which breaks on non-GitHub-Pages hosts (the README documents this itself).
- No automated UI tests exist; correctness is verified only through `tsc --noEmit` and ad-hoc CDP scripts, so there are no web-side test fixtures to reuse for the Swift migration tests. Any real backup file will need to be exported by hand from the web app.
