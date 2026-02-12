
- MRU stuff fix, + performance

- unclose window.... if even possible idk. if it was browser can use their native undelete keyboard shortcut and automte that?

- quick switcher & MRU improvements
    - quick switcher when switching to window and back to old window it sometimes opens the app you were just in instead of the window you teid to tab back into
    - quick switcher design / style
    - quick switcher general reliablitiy
        - quick switcher sometimes does not get order right until like two focuses sometimes
        - performance sometimes bad
        - quick switcher forgets about individual apps to easily 
            - might be issue with discovery across spaces which may be hacky. i believe alttab maintains internal list vs ours rechecks every time?
    - mru maybe doesnt get updated on all window changes, just app changes and in-group window changes?, idk

- make settings window show up as window (it does show up in alttab, maybe reconsider what we're targetting)
    
    
- new window during app already active functionality
    - iterm2 doesnt work
    - need good scan of everything to make sure its correct
    - also include whatever else we can
    

- fullscreen improvements
    - turns out we can draw tab bar (so maybe have it show up on mouse top of screen?)
    - right now behaviro somewhat unspecified. did a feature which i didnt merge, need to redo



- platofrm structure me understanding issues and also refactor?
- preemptive detailed logging
- improve tests including minimum performance in tests
    
Small 
- hyper t when not in a window has option for add all in space
- option to auto 1-tab-group all new windows if not matched to existing window

- make new branch main branch and main branch "old" branch
- simplify settings ux

- maybe: feture: in addition to web sites, lets add folders search which opens folders in a default terminal and/or code editor
- feature: tab renaming, if tab has name set use that instead of window name

Future:
- pinned tabs
- hide tab bar mode (just focused on alt tab navigation)
- maybe: virtual tabs in which they belong to multiple windows (for apps with one window max like codex)
    - limitation: pretty much unfeasable to be able to switch what space a window is in

--------
## todo:

In the future (maybe present?) ai / ralph loop should be able to take a list like the above and do it correctly. already usually can from code perspective but not design perspective, but idk. Maybe need a prompt -> prompt step
    - one real issue with this app is that it is too difficult / i haven't set up an ai visual viewer, so i need to be in the loop to test if result looks right, easier to do this for browser apps currently


- [x] fullscreen restoration
    - can maybe improve was tired when designed this
- [x]display title on hover tab (preview to hard) IF the tabs are shrunk enough
- new tab to the right (right click on tab)

- virtual tabs (brainstorm w superpowers)
    - if a tab is virtual, it can exist in multiple spaces at once
    - ok nevermind switching spaces is impoossible

- pinned tabs:
    - tabs are left aliggned. jut show their icon. still draggable but only among other left aligned stuff
    - right click to pin/unpin, can also drag into / outof pin area

--- 
- launch app? / spotlight alternative?
    - alt new tab ui
    - either: inspired by chrome/ff, or by arc
        - arc-like
            - center tab in middle with search
            - shows available windows from space underneeth, can select with down arrow enter or with mouse
            - can search in following priority
                - 1) windows in current space
                - 2) windows outside of space (virtualized badge)
                - 3) apps to launch in space and then capture
                - 4) web pages, powered by connection to browser of your choice, opening these opens a new window of browser of your choice in new tab

- glassify the new tab pane

- run code simplifier, do throrough review and refactor, in new branch for saftey

- new feature: browser integration

- separate keyboard shortcut for remove current tab from space and close current tab
 -> ig theres q for app... but im thinking hyper w should close it. maybe command or hyper shift w should which is already browsers standard
---
bugs
- in window switch
---

- maybe: name windows for displation in quick switcher~
- fullscreen to unfullscreen restoration
- make sure you can have multiple fullscreen windows on one space and the new app detection logic still joins it to the active one
- space detection might want to be a more baked in primitive.
    -> right now you can cheeze it which could be fun but its not intended. also no way to move tabs between spaces. need to be intentional here
    
- display title on hover tab (preview to hard) IF its shrunk enough

- option to have tabs have a max size and left align, 
    - make sure dragging tab bar has sane behavior
    
    - option in settings to change tab style: what we have now vs left aligned tabs with a max width (more like chrome etc) - keep task bar undraggable for now, but will have room to allow drag in the future
    
---------------------
- maybe: make height 24 instead of 28 to match menu bar on my m1 mac air (remove from padding)
    - prompt: make the tab bar height 24 instead of 28: change tabBarHeight in TabBarPanel.swift to 24, change tab item .padding(.vertical, 4) to .padding(.vertical, 3) in TabBarView.swift, and change the outer HStack .padding(.vertical, 2) to .padding(.top, 1) .padding(.bottom, 1)  
    
    
- maybe: option to always make all lone windows single tabbed windows


- maybe: option for quick switcher to bring window to you instead of you to window, this way there is no space switch animation
- wait. this is also how we can clean up mission control view. clicking a tab brings the window here. all other windows live can live on their own desktop away from site (holy moly)

- maybe: multispace/multigroup windows: for annoying windows like codex which only have one window per app. put it in multiple window groups across spaces, clicking the window moves it to where you are
    - similar to above, maybe evolves into it
    - call this virtual tabs?


- simplify session restore config options maybe


feature ideas: 
    - see maybes above
    - pinned tabs. just like browsers



-----------


BUGS:
    - signal app specifically (most apps dont but others might) pick up control + tab key shortcut even though im pressing hyper tab
    - capture new windows when maximized doesnt work reliably
    - fullscreen restoration on app quit is 2px too short - sometimes. now its stopped
    
    - quiting new tab adder with esc (or any way) should refocus the current tab w/out requiring clickation

- option for quick switcher keys to overwrite command tab and command ` (by windowgroup > by app)

- option to make tabs have max width, and left aligned instead of justified

- menubar clicking window should navigate to that window

- setting to not show the tab bar if height of window is full (still useful via switcher)
    - also option to never show tab bar?

- freeing  window focuses it, not the next active tabs
- replace x button (maybe - button) since it frees and doesnt close, maybe config to close window
    - ok maybe the active tab its a - free button, non active tabs its a x close window button (active tab can be closed with traffic lights)
    

Window Handling:
    - handle changing spaces
        - ux:
            - either: drag tab bar to change, dragging window out does not change it
            - or dragging any child window into space moves the whole group there
                - probably this is better but we need to make freeing logic good (shift select)
    - maybe: handle fullscreening app differently
        - right now it breaks out
        - can have it rejoin group on unfullscreen
            - can have it have an indicator in the group that its a part of the gorup but fullscreened



Meta Dev:
    - set up vscode swift lsp
    - claude swift extension reduce the false positives
    
    - maybe a custom commit script
    
    - code cleanliness:
        - set up proper log system so claude doesnt either guess at bug or ask me to log as often
        - make sure tests are everywhere. i think its only writing tests when using superpowers implement skill. could copy that in general into claude.md or just ask it to test after the fact...
        
    

- feature: spotlight launcher
    - in addition to adding apps from the current space in a list
    - have a windows search / spotlite (everyones favorite features) like launcher
    which just searches your apps and launches an app window then captures it
    - in the future though it might search the web iswtg and make a browser webview type tab, and we will truly unify desktop and web apps into one control system muahahaha (will be disablable)
        - maybe just open it in helium (compact tabs and tabs and url in line),
        then to open new tab in new window user can drag out, otherwise it will be like double tabs. need to find way to make new helium window and navigate in it. good to allow any browser of users choice
        - also register a system right click shortcut to search text or open link in browser of choice

Maybe:
- might be too complex
    - double click to fullscreen -> if allready in fullscreen double click restores to old behavior (like it would without this app)
- not sure
    - mode to turn off tab display entirely, focus ont he alttab clone aspect of the app
        - should windows still stay together? probably not actually
        - add a window with hyper t, then use alttab clone stuff to navigate in groups
        - question: could this have all been desktop based, just have a seperate keybind for navigating within desktop (alttab already does this)
           - altab does not show desktops as a group though tbf
        - could also alternatively have a "hide tab bar on maximized option"

----- More ------


# uncommited from main branch
1. Frame-based notification suppression (e8a572c) — replaced time-based suppression with frame-based
    - (related to distinguishing movement notifs that came from itself type shit)                                                    
3. Focus-change listener for auto-capture (0bc3f81) — replaced polling with a focus-change listener for tab drag-outs                 
4. Simplified session restore (9ef511c) — single toggle (restoreOnLaunch) instead of the restore mode enum, plus cross-Space window 
matching   


# Todo
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
