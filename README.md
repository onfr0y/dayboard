# Dayboard

Dayboard is a native macOS menu bar app that lays a calendar, schedule, tasks and Good Habits over your existing desktop wallpaper. Select a date to update the agenda and open a two-day calendar timeline. Events appear as blocks on an hourly grid. Click a good habit to log a check-in from the desktop.

Choose **Show less** to collapse Schedule and Tasks together, or collapse Tasks and Good Habits separately. A collapsed section shows its heading and a **Show** control. Dayboard remembers these choices.

Open **Pomodoro** from the desktop or the Dayboard menu bar icon. Focus and break lengths default to 25 and 5 minutes and can each be set from 1 to 180 minutes. The timer keeps going while its panel is closed. Dayboard plays a sound at the end of a session and readies the next one for you to start.

The Pomodoro panel uses native Liquid Glass on macOS 26 and later. Drag its title area to reposition the panel. Dayboard remembers where you leave it.

## Install

Download the macOS ZIP for your processor from the repository's Releases page. Extract it, move Dayboard.app to Applications and open it. The app requires macOS 14 or later. Release builds are ad-hoc signed and are intended for local installation. The menu bar calendar icon opens Settings, changes the text colour and hides or shows the board.

Choose **Connect Mac Calendar** and grant calendar access to display calendars already synced to this Mac. Dayboard reads those calendars. The app can start automatically when you log in.

Schedule and the two-day timeline also display `Action Date` entries from the connected Notion Tasks database. Dayboard refreshes Notion about once a minute. **Refresh Dayboard** immediately reloads the connected data sources.

## Connect Notion

Dayboard supports the LiFE RPG-style Notion schema below. Create a personal API token or an internal connection with read access to these data sources and permission to insert rows into Activity Log for habit check-ins.

| Data source | Properties used by Dayboard |
| --- | --- |
| Tasks | `Tasks/Event` title, `Action Date` date, `Status` status, `Priority` select |
| Good Habits | `Good Habit` title |
| Activity Log | `Activity` title, `Date` date, `Good Habit` relation, `Character` relation, `History` checkbox, `Type` rich text |
| Character | The character profile linked to new habit check-ins |
| Daily Journal (optional) | `Date` date and a template for new entries |

Copy [notion-config.example.json](notion-config.example.json) to `notion-config.json`. Replace the sample UUIDs with the four Notion **data source IDs** and the **page ID** of your character profile. Optional link fields are `tasksURL`, `habitsURL`, `habitSourceURL`, `activityURL` and `characterURL`. Import the file in Dayboard Settings, then enter your token in the secure field. Dayboard stores the token in macOS Keychain. The configuration, local snapshots and pending check-ins are stored in the local Dayboard Application Support folder.

A check-in queues locally on click. Dayboard checks for an existing entry for that habit and day before creating a new entry in Activity Log. A tick appears after Notion accepts the check-in or Dayboard finds an existing entry.

To enable **Daily Journal**, add the optional `journalSourceID` to your configuration and give the Notion connection permission to read the source and create pages. Set `journalTemplateID` to select a specific template, or leave it out to use the source’s default template. You can also set `journalURL` for a shortcut in Settings. Dayboard uses your Mac’s local date. It opens an existing entry or offers to create today’s entry using the template.

## Build

Install the Xcode command-line tools with the macOS 26 SDK or later, then run the build script from the repository root.

```sh
./scripts/build.sh
```

The script creates an ad-hoc signed app ZIP in `dist/` for the current architecture. Set `DAYBOARD_ARCH` to `arm64` or `x86_64` to target a specific processor. The app uses SwiftUI, AppKit, EventKit and Security, with no third-party packages.
