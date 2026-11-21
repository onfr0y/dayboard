# Dayboard

Dayboard is a native macOS menu bar app that lays a calendar, schedule, tasks and Good Habits over your existing desktop wallpaper. Select a date to see its schedule and tasks. Click a good habit to log a check-in from the desktop.

## Install

Download the macOS ZIP for your processor from the repository's Releases page. Extract it, move Dayboard.app to Applications and open it. The app requires macOS 14 or later. Release builds are ad-hoc signed and are intended for local installation. The menu bar calendar icon opens Settings, changes the text colour and hides or shows the board.

Choose **Connect Mac Calendar** and grant calendar access to display calendars already synced to this Mac. Dayboard reads those calendars. The app can start automatically when you log in.

## Connect Notion

Dayboard supports the LiFE RPG-style Notion schema below. Create a personal API token or an internal connection with read access to these data sources and permission to insert rows into Activity Log for habit check-ins.

| Data source | Properties used by Dayboard |
| --- | --- |
| Tasks | `Tasks/Event` title, `Action Date` date, `Status` status, `Priority` select |
| Good Habits | `Good Habit` title |
| Activity Log | `Activity` title, `Date` date, `Good Habit` relation, `Character` relation, `History` checkbox, `Type` rich text |
| Character | The character profile linked to new habit check-ins |

Copy [notion-config.example.json](notion-config.example.json) to `notion-config.json`. Replace the sample UUIDs with the four Notion **data source IDs** and the **page ID** of your character profile. Optional link fields are `tasksURL`, `habitsURL`, `habitSourceURL`, `activityURL` and `characterURL`. Import the file in Dayboard Settings, then enter your token in the secure field. Dayboard stores the token in macOS Keychain. The configuration, local snapshots and pending check-ins are stored in the local Dayboard Application Support folder.

A check-in queues locally on click. Dayboard checks for an existing entry for that habit and day before creating a new entry in Activity Log. A tick appears after Notion accepts the check-in or Dayboard finds an existing entry.

## Build

Install the Xcode command-line tools and run the build script from the repository root.

```sh
./scripts/build.sh
```

The script creates an ad-hoc signed app ZIP in `dist/` for the current architecture. Set `DAYBOARD_ARCH` to `arm64` or `x86_64` to target a specific processor. The app uses SwiftUI, AppKit, EventKit and Security, with no third-party packages.
