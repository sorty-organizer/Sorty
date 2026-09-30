"""Finder layout for the Sorty drag-to-install disk image."""

import os

application = defines["app"]
format = "UDZO"
files = [application]
symlinks = {"Applications": "/Applications"}
background = defines["background"]
window_rect = ((200, 200), (464, 564))
icon_locations = {os.path.basename(application): (115, 230), "Applications": (350, 230)}
icon_size = 80
text_size = 13
default_view = "icon-view"
show_icon_preview = False
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
include_icon_view_settings = True
