# The move dialog (m, v) for linux/dev/headless.sh: the empty list, a query that finds sections,
# projects and tasks, no matches, a move with its toast and undo, several tasks, and the task view.
key j j
key m
shot omarchy-move-01-empty
type "ing"
shot omarchy-move-02-query
type "zzq"
shot omarchy-move-03-no-match
key -M ctrl a -m ctrl -k BackSpace
type "work plan"
shot omarchy-move-04-section
key -k Return
shot omarchy-move-05-moved
key u
shot omarchy-move-06-undone
key J J
key v
type "re"
shot omarchy-move-07-several
key -k Escape
key -k Escape
key -k Return
key m
type "rep"
shot omarchy-move-08-from-detail
key -k Down
key -k Return
shot omarchy-move-09-subtask
key -k Escape
theme catppuccin-latte
key m
type "o"
shot omarchy-move-10-light
key -k Escape
theme tokyo-night
# In a project with sections: they sit under it; Ctrl+J moves the highlight.
key -M ctrl 2 -m ctrl
key j
key m
key -M ctrl j -m ctrl
shot omarchy-move-11-sections
key -k Escape
# Long titles are elided: the subject in the middle, titles and places at the end.
key q
type "Prepare the very long quarterly business review presentation for the leadership offsite #Work"
key -k Return
key k
key m
type "pre"
shot omarchy-move-12-long
key -k Escape
