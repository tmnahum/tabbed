# Todo


- Find way to hide non active windows completely (maybe settle for minimizing). esp so that it doesnt show up in AltTab (and mission control etc) and instead the metawindow is what shows up
    - int his case also customize the window name maybe?

## Bugs
- sometimes on init the state of things is wrong, dragging around a window fixes it.
    - specifically the tab bar overlays over a window instead of on top of it on the screen
- sometimes non-main window sizes get out of sync, for example double clicking menu bar to fullscreen the app works witht he detection logic, but other windows sometimes don't become that same size. should inspect our code but also can do fallback of trying to resize window on tab switch





- Maybe: remove the functionality of increasing app size once freed. often covers up tab bar of other windows.
    - when quitting tabbed all together it is still good
- maybe: dragging the tab bar container does not drag the windows  (currently can no longer even drag it so its fine)



## Maybe:
- allow one tab windows
- change up tab design (and/or/none)
    - make tabs shorter (more like chrome not safari)
    - add a close/release window button
- change x icon on tab which frees the window, change it to a - icon or another icon we find


- launch an app in addition to capturing an existing app



## Post-MVP Features
- Keyboard shortcuts for tab switching (using Hyper key to avoid conflicts with in-app shortcuts)
- Persist groups across app restarts (match by app bundle ID + window title, best-effort) / restore previous session option on startup

Maybe:
- Drag a tab out of the tab bar to release it
- Drag a tab into another group's tab bar to move between groups