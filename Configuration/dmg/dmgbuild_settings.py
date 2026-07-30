import os
from pathlib import Path

# dmgbuild settings file. This is read by the `dmgbuild` CLI (or Python API).
# It uses environment variables exported by the shell wrapper script:
#  - DMG_APP_PATH: path to the .app bundle to put in the DMG
#  - DMG_VOLUME_NAME: volume name to display when the DMG is mounted
#  - the background is fixed to the repository-owned image below

APP_PATH = os.environ.get('DMG_APP_PATH')
VOLUME_NAME = os.environ.get('DMG_VOLUME_NAME', 'boringNotch')
SETTINGS_ROOT = Path(__file__).resolve().parent
BACKGROUND = str(SETTINGS_ROOT / '.background' / 'background.tiff')

# Basic DMG metadata
volume_name = VOLUME_NAME
format = 'UDZO'
compression_level = 9

# Files and symlinks to include in the DMG
files = [APP_PATH] if APP_PATH else []
symlinks = {'Applications': '/Applications'}

# Background image path (dmgbuild will copy this file into the DMG's .background)
background = BACKGROUND


# Window rectangle: ((left, top), (right, bottom))
window_rect = ((0, 0), (660, 400))

# Icon size (points)
icon_size = 128

# Icon locations: map filename (or bundle name) -> (x, y) in window coords
app_basename = os.path.basename(APP_PATH) if APP_PATH else 'boringNotch.app'
icon_locations = {
    app_basename: (150, 180),
    'Applications': (510, 180),
}

# Misc Finder options
show_statusbar = False
show_tabview = False
show_toolbar = False
