# Default scenario for linux/dev/headless.sh: a tour of the main views, in three themes.
shot 01-inbox
key j j
shot 02-selected
key -k Return
shot 03-detail
key -k Escape
key q
type "Renew passport next friday p1 @errands #Home"
shot 04-quickadd
key -k Escape
key -M ctrl 2 -m ctrl
key j
shot 05-project
key t
type "next mon"
shot 06-date-picker
key -k Escape
key ?
shot 07-shortcuts
key -k Escape
theme catppuccin-latte
shot 08-light-theme
theme gruvbox
shot 09-gruvbox
