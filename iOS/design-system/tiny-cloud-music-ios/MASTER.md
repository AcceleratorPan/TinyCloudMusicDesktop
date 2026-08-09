# Tiny Cloud Music iOS Design System

**Target:** iPhone 13 Pro, iOS 18.0-26.x
**Stack:** SwiftUI, UIKit only for missing native bridges
**Tone:** content-first, compact, calm, music artwork supplies the visual color

## Principles

- Preserve every macOS capability, but reorganize it for one-handed phone use.
- Use native SwiftUI controls, system materials, SF Symbols, Dynamic Type, VoiceOver, and system navigation.
- Keep the interface neutral in light and dark mode. Red is the single brand/action accent; artwork provides secondary color.
- Do not use custom fonts, decorative gradients, ambient blobs, nested cards, hover-only behavior, or ornamental animation.
- Keep every interactive target at least 44 x 44 pt with at least 8 pt between adjacent targets.

## Navigation

- Use a five-item `TabView`: Discover, Search, Library, Media, Account.
- Give each tab its own `NavigationStack` and typed path so back navigation and deep links remain predictable.
- Put video, podcasts, radio, Personal FM, music knowledge, downloads, history, and listening reports under Media or Library without hiding any feature.
- Show the mini player with `safeAreaInset(edge: .bottom)` above the tab bar. Tapping it presents Now Playing full-screen.
- Use sheets for short choices and edits, full-screen covers for immersive playback/login, and pushed destinations for browsable content.

## Visual Tokens

| Role | SwiftUI token | Use |
| --- | --- | --- |
| Accent | `.red` / app tint | Primary actions, current playback, selection |
| Background | `Color(uiColor: .systemBackground)` | Page background |
| Grouped background | `Color(uiColor: .systemGroupedBackground)` | Dense settings/library groups |
| Primary text | `.primary` | Titles and essential metadata |
| Secondary text | `.secondary` | Artist, album, status, timestamps |
| Separator | `Color(uiColor: .separator)` | List and toolbar separation |
| Destructive | `.red` with destructive role | Delete, report, logout confirmation |

- Use system semantic colors only; never bake light/dark raw colors into components.
- Use system text styles (`.largeTitle`, `.title2`, `.headline`, `.body`, `.callout`, `.caption`) and support all Dynamic Type sizes.
- Use 4, 8, 12, 16, 24, and 32 pt spacing. Repeated rows use 8 pt corner radius at most.
- Album art is square. Video is 16:9. Stable aspect ratios prevent loading-state layout shifts.

## Components

- Lists use native `List`, `Section`, and `LazyVStack`; cards are reserved for repeated media items, not page containers.
- Commands use SF Symbols with labels or accessibility labels. Familiar playback commands may be icon-only.
- Binary settings use `Toggle`; small option sets use `Picker(.segmented)`; larger option sets use menus; numeric ranges use sliders or steppers.
- Loading keeps the destination layout stable and exposes an accessibility status. Empty and error states use `ContentUnavailableView` with a retry command when applicable.
- Destructive or account-writing actions require explicit role styling and confirmation where reversal is not immediate.
- Search uses `.searchable`, debounced hints, typed scopes, and preserves the active query on navigation return.

## Motion And Feedback

- Prefer native navigation, sheet, progress, and matched artwork transitions. No decorative scroll reveals.
- Keep custom state transitions between 150 and 250 ms and disable them when `accessibilityReduceMotion` is enabled.
- Use haptics only for successful explicit mutations, destructive confirmation, and playback-control errors.
- Never animate layout dimensions in scrolling lists.

## Accessibility

- VoiceOver combines artwork, title, creator, availability, and action state into a concise row description.
- Do not encode liked, downloaded, playing, or unavailable state by color alone; pair it with an icon and accessible text.
- Preserve 4.5:1 text contrast, Bold Text, Button Shapes, Differentiate Without Color, Reduce Motion, and Reduce Transparency.
- Keep controls reachable in portrait on a 390 x 844 pt iPhone 13 Pro canvas and usable in landscape without horizontal page scrolling.
- Use system focus and announcements for playback failures, login state, upload/download completion, and Together recovery.

## Pre-Delivery Checklist

- [ ] All current macOS routes and mutations have a reachable iOS entry.
- [ ] No text or control overlaps at default, AX3, or largest accessibility Dynamic Type.
- [ ] Touch targets are at least 44 x 44 pt and safe-area insets are respected.
- [ ] Light, dark, increased contrast, reduced motion, and VoiceOver states are verified.
- [ ] Mini player never covers tab content; keyboard never covers the active field.
- [ ] Playback, downloads, uploads, login, and Together expose loading, error, cancellation, and recovery states.
- [ ] iPhone 13 Pro screenshots at iOS 18 and 26 are visually checked.
