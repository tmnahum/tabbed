# Todo
- If tabbed window is fullscreen AND all windows in space are part of the tabbed window, then any new windows opening in space auto join the tabbed window

- proper alt tab feature with display, both within tabbed window group and system wide


- change design
    - maybe make settings to cycle between many different design stlyles, to prototype them out, then pick one (or two?) and delete rest
        - what we have now
        - one that is like what we have now but with max length of tabs, draggable rest of the area
        - one that is like chrome tabs, but do not paint over rest of area
            - (inspired by ultrasnapper screenshots)
        - 3+ more wildcard designs (be creative make them different from each other)


- do performance/battery review on the codebase
- scan for dead or unnecessary duplicate code

- brain

Maybe:
    - when app breaks out by going goes full screen and then unfullscreen, restore it back to the group
    - 

## Bugs
- tab bar sometimes appears in wrong space (desktop)

- going from focus on non-grouped app that is on top of tab bar into grouped app not by clicking can leave non grouped app obsuring the tab bar - or something like that

- verify the alt tab behavior follows same standards such as those that browsers like firefox, brave, follow
- search for cross space / cross display bugs

## Maybe:

- add app launching logic & restore mode that relaunches apps or something like that

- maybe: change menu bar style to be more normal while still working with a hiding menubar (ideally keep it open) and being native-y

- hyper shift tab to go back in hyper tab cycle
- maybe: window switcher ui for hyper tab

- maybe behave differently in "fullscreen"?
    - feature: for windows that can't be resized, if we are in fullscreen view do not move them when added instead just switch between them, allow them to be moved without resizing all other windows (only under specific circumastances though)
        - maybe even don't resize windows at all in fullscreen, just keep the menubar at the top and switch active windows without resizing other windows, (but only in fullscreen mode), maybe adding unecessary complexity.
        - or maybe just dont resize or care about windows who can not be expanded to be fullscreen when we are in fullscreen
- related feature: if all tabs in a space are part of metawindow, (and if it's fullsecreen?) all newly opened apps join the metawindow automatically

- maybe skip windows with a minimum size in all in space mode?

- option launch an app in addition to capturing an existing app

- change up tab design (and/or/none)
    - make tabs shorter (more like chrome not safari)
    - maybe: add a window-wide close/release all windows button
- change x icon on tab which frees the window, change it to a - icon or another icon we find


- consider moving swiftui to appkit - swiftui we have lifecycle hacks right now and not that much code in it


- as an alternative to hiding windows for better integration with stuff such as altTab. we could just recreate altTab but with awareness of our own groups, and displays as such in the ui (ie three app icons in one list view). we are already a window manager sort of esp with the hyper tab keybind
    - basically how i want to use it personally is one alttab (replacing command tab) for window level, one hyper tab (or maybe remap) for within meta-window level, and then control tab for within app level (ie firefox, vscode) (already standard)


- [gaveup] investigate a way to hide non active windows completely (maybe settle for minimizing). esp so that it doesnt show up in AltTab (and mission control etc) and instead the metawindow is what shows up
    - int his case also customize the window name maybe?
    - can hide with the undocumented CGS private APIs
        - no not other's apps unless we inject into finder which requires the user disabling system wide security features
    - maybe: implement minimization,
    - or alternative is to interface with alttab, command tab or make our own

## Post-MVP Features
Maybe:
- Drag a tab out of the tab bar to release it
- Drag a tab into another group's tab bar to move between groups
- "pinned" tabs (force left and just the icon)

# Todo later
- test that it works with Rectangles
- distribution
    - mvp is they can run ./build lol
    - over the air update system
    - $99/year signing or else it will be sus for people to install
    
# Potential configs:
- conflict: less is better so its easier for me to test with my own usecase. but more is more fun and more useful to people if it does work

- could have fullscreen vs small tab styles though I think its not worth it
    - or miltiple tab styles in general