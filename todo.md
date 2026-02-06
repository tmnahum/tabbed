# Todo
    - fill out keyboard shortcuts
        - 9 should be last always
        - think of any others to mirror browsers
        

[ip] - all in space button, put one directly in the menu bar too (under regular new group button), and customize behavior:
    - assuming we can get this info: order tab order by most recently used app/window, or highest app/window in z index whatever we can get, most recently used first and continue in order
    - maybe: skip adding apps of whom their window has a max width that is too small and cant be expanse

- investigate a way to hide non active windows completely (maybe settle for minimizing). esp so that it doesnt show up in AltTab (and mission control etc) and instead the metawindow is what shows up
    - int his case also customize the window name maybe?
    - can hide with the undocumented CGS private APIs
    

- maybe: change menu bar style to be more normal while still working with a hiding menubar (ideally keep it open) and being native-y

- change design
    - maybe make settings to cycle between many different design stlyles, to prototype them out, then pick one (or two?) and delete rest
        - what we have now
        - one that is like what we have now but with max length of tabs, draggable rest of the area
        - one that is like chrome tabs, but do not paint over rest of area
            - (inspired by ultrasnapper screenshots)
        - 3 more wildcard designs (be creative make them different from each other)


- do performance/battery review on the codebase

## Bugs
- maybe: dragging the tab bar container (not the tab) does not drag the windows
    - should either drag the windows or be undraggable
    - i think undraggable is fine
- related: minor: tab bar shows up in mission control, is able to be attempted to dragged to snap to side of pane, etc

- on add, is squeezes windows down to make room for tab bar even if there is space for tab bar already, should just show it on top instead

- hyper T does not work

- some special apps such as altTab the window close detection does not work


❯ bugs: 
    - initial positioning can be a little wrong too low etc - check if still true
    
    - going from focus on non-grouped app that is on top of tab bar into grouped app not by clicking can leave non grouped app obsuring the tab bar - or something like that



## Maybe:
- maybe behave differently in "fullscreen"?
    - feature: for windows that can't be resized, if we are in fullscreen view do not move them when added instead just switch between them, allow them to be moved without resizing all other windows (only under specific circumastances though)
        - maybe even don't resize windows at all in fullscreen, just keep the menubar at the top and switch active windows without resizing other windows, (but only in fullscreen mode), maybe adding unecessary complexity.
        - or maybe just dont resize or care about windows who can not be expanded to be fullscreen when we are in fullscreen
- related feature: if all tabs in a space are part of metawindow, (and if it's fullsecreen?) all newly opened apps join the metawindow automatically

- maybe add all in space should be menu bar level quick shortcut
    - maybe skip those with a minimum size?

- option launch an app in addition to capturing an existing app

- change up tab design (and/or/none)
    - make tabs shorter (more like chrome not safari)
    - maybe: add a window-wide close/release all windows button
- change x icon on tab which frees the window, change it to a - icon or another icon we find

- window switcher ui instead of remembering

- duplicate app protection story

- consider moving swiftui to appkit - swiftui we have lifecycle hacks right now and not that much code in it




## Post-MVP Features (important)
- Keyboard shortcuts for tab switching (using Hyper key to avoid conflicts with in-app shortcuts)
- Persist groups across app restarts (match by app bundle ID + window title, best-effort) / restore previous session option on startup

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

- free vs quit windows when closing tabs
- restoration behavior once we implement that
- hide vs dont tabs
- could have fullscreen vs small tab styles though I think its not worth it

- if all windows in a space are part of one hyperwindow, auto add any newly opened windows to the hyperspace when opened

