# Grassfield.Ui public API changelog

`ui/Grassfield/Ui/qmldir` lists the types that the shell and the apps import (`import Grassfield.Ui`). This file is its
changelog. It is append-only and machine-checked by `tests/ci/ui_api.py` (`just check-contracts`).

Rule: a type added to, renamed in or removed from the qmldir gets a line in the block below in the same commit.

- `add <Name> [singleton]`: the type is public. A rename is `remove <Old> -> <New>` plus `add <New>`.
- `remove <Name> [-> <Replacement>]`: the type is gone; the replacement, when there is one, must be public.
- Lines are never edited or deleted, only appended. A removed name is not added again under the same name.

The test fails when the set `add` minus `remove` differs from the qmldir (names and the `singleton` flag), when a
`remove` names a type that was never added, or when a replacement is not public. Why: Segmented became SegmentedControl
without a line and broke Settings' MousePage; a qmldir edit now cannot pass without this file.

```ui-api
add Tokens singleton
add Appearance singleton
add Material
add Icon
add NavChevron
add MenuItem
add MenuSeparator
add PopupMenu
add Slider
add Toggle
add Tooltip
add Button
add LinkText
add TextCursor
add JsonSafety
add SwatchRow
add TintedIcon
add IconEffect
add Accent
add IconModes
add FolderStyle
add FolderPlate singleton
add FolderEffect
add FolderIcon
add PointerSize
add PointerColors
add WallpaperConfig
add DisplayRole
add GrassfieldArtwork
add MenuPlace
add IconShape singleton
add IconTile
add IconShapePrewarm
add AutoAppearance
add NotificationPrefs
add DisplayName
add FocusRing
add ToolButton
add CheckBox
add RadioButton
add Switch
add TextField
add SearchField
add SpinBox
add SegmentedControl
add ComboBox
add ProgressBar
add ScrollBar
add Sheet
add FocusGuard
add ActivationKeys
add WindowActions
add WindowControls
add UnifiedToolbar
add SettingsContract
add MenuShortcut
add GlassTint
add RimmedCapsule
add SidebarPanel
add TileGlyph
add SoftwareUpdateLogic
add UninstallLogic
add DevicePicture
add KeyFocus
add MenuHeader
add Spinner
add ProgressRing
add MenuPopup
add TimeOfDay
add SoundEffects
add Glide
```

## Property changes of public types
Properties added to a public type (not machine-checked: the block above tracks types). Append-only, one line each.

- 2026-11-04 `SearchField.focusRing` (bool, default `true`): `false` draws no 3-px focus ring while the field has the focus,
  for a popover over a window that stays key (Emoji & Symbols, ADR-0045 OC-3). Existing users unchanged. Test:
  `tests/unit/tst_controlstext.qml` `test_searchFieldFocusRingOptOut`.
