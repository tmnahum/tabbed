# Todo
- when adding a window switch to it's tab automatically
- add a button in initial window picker to add all windows in space and create


- investigate a way to hide non active windows completely (maybe settle for minimizing). esp so that it doesnt show up in AltTab (and mission control etc) and instead the metawindow is what shows up
    - int his case also customize the window name maybe?
    - can hide with the undocumented CGS private APIs

## Bugs
- Maybe: remove the functionality of increasing app size once freed. often covers up tab bar of other windows.
    - when quitting tabbed all together it is still good
- maybe: dragging the tab bar container does not drag the windows  (currently can no longer even drag it so its fine)

❯ bugs: 
    - initial positioning can be a little wrong too low etc

    - closing settings quits the whole app
    
    - going from focus on non-grouped app into grouped app not by clicking can leave non grouped app obsuring the tab bar - or something like that

## Maybe:

- option launch an app in addition to capturing an existing app

- change up tab design (and/or/none)
    - make tabs shorter (more like chrome not safari)
    - maybe: add a window-wide close/release all windows button
- change x icon on tab which frees the window, change it to a - icon or another icon we find


- duplicate app protection story




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

