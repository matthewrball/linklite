# SPDX-License-Identifier: GPL-2.0-or-later
# dmgbuild settings for the LinkLite installer window. See scripts/build-dmg.sh.
from pathlib import Path

app = Path(defines["app"]).resolve()
assets = Path(defines["assets"]).resolve()
assert app.name == "LinkLite.app" and app.is_dir()

# LZMA: the smallest format; needs macOS 10.15, below LinkLite's minimum.
format = "ULMO"
files = [str(app)]
symlinks = {"Applications": "/Applications"}
# Changing FinderInfo on the signed app would invalidate its sealed bundle.
hide_extensions = []
background = str(assets / "background.png")
icon = str(app / "Contents/Resources/AppIcon.icns")
window_rect = ((200, 120), (720, 492))
default_view = "icon-view"
show_status_bar = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 104
text_size = 13
scroll_position = (0.0, 0.0)
icon_locations = {
    "LinkLite.app": (200, 270),
    "Applications": (520, 270),
    # Hidden files sit outside the window.
    ".VolumeIcon.icns": (820, 100),
    ".DS_Store": (980, 100),
    ".background.tiff": (980, 280),
    ".fseventsd": (820, 280),
}
