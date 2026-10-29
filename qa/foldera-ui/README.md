# Native Foldera UI audit

Manual GitHub workflow, on a disposable `macos-26` runner. No network shares,
real documents, external recipients, app-default changes or model calls.

The overlay is compiled into a separate clone of reviewed source revision
`56c75d12238c3099ecafbc4a4b7047e284db695e`. Product sources on `main` are unchanged.
The hook uses the existing snapshot initialization; `FolderaUIAudit` activates real
ToolButton mouseDown/mouseUp handlers, NSButton.performClick, real menu items and
key events, then checks filesystem/application state. Setup selection/navigation
and field-edit notifications are explicitly recorded. This is in-process AppKit
integration testing, not external accessibility/XCUITest automation.

Full plan: 122 fresh-process cases. Four layouts × four window widths × light/dark
= 32 layout cases; 44 action flows × light/dark = 88; two existing native preview
fullscreen round trips. Failed cases retry once in another fresh process/fixture.
Each case has a 48-second process limit, the campaign a 22-minute limit.

Flows cover navigation, search/filter, details/preview/edit/detach, split panes,
tabs, new items, rename inline and sheet, copy/cut/paste, Trash/Undo, properties,
batch rename, Quick Open/commands, selection, viewer, sync Compare, dropdown menus,
Share open/cancel, text comparison/editor, cancel permanent deletion, archive browsing.

The extended 24-case plan also checks hidden items, all sort keys, icon size slider,
address input, new window, safe viewer toolbar actions, real synthetic folder sync,
sync history, server-dialog Cancel, About, SHA-256 clipboard output, and Cancel in
a real progress window waiting on a synthetic sparse provider-placeholder file.
It does not contact a real server or install a scheduler.

Screenshots, actual clicked steps, menu/controls inventories and raw per-case logs
are saved even for failure. Clipped-toolbar geometry is a candidate, not a bug verdict.
The final human review must distinguish product defects, bad driver expectations,
runner constraints and unsupported native transitions.

This does not claim every button/window/context-menu item is exercised. No real
network/AirDrop/mail/cloud, default-handler changes, live permissions or personal
Mac settings are tested. Share is open/cancel only. No scheduler is installed.
