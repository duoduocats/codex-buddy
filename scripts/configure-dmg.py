#!/usr/bin/env python3
"""Set Finder's DMG window layout without controlling Finder or using AppleScript."""
from pathlib import Path
import argparse
from ds_store import DSStore
from mac_alias import Alias

parser=argparse.ArgumentParser()
parser.add_argument('volume',type=Path)
args=parser.parse_args()
volume=args.volume.resolve()
background=volume/'.background'/'install.png'
alias=Alias.for_file(str(background))
# The relative target and volume name resolve after a downloaded DMG is remounted.
# Do not retain the builder's temporary mount location in distributed metadata.
alias.volume.posix_path=b'/Volumes/Codex Buddy'
with DSStore.open(str(volume/'.DS_Store'),'w+') as store:
    store['.']['bwsp']={
        # WindowBounds is Finder's outer frame. Allow the title/path bars in
        # addition to the 720 x 540 pt background and icon canvas.
        'WindowBounds':'{{240, 120}, {720, 600}}',
        'ShowToolbar':False,'ShowStatusBar':False,'ShowPathbar':False,
        'ShowSidebar':False,'ContainerShowSidebar':False,
        'PreviewPaneVisibility':False,
    }
    store['.']['icvp']={
        'viewOptionsVersion':1,'backgroundType':2,
        'backgroundImageAlias':alias.to_bytes(),
        'backgroundColorRed':1.0,'backgroundColorGreen':1.0,'backgroundColorBlue':1.0,
        'iconSize':96.0,'textSize':13.0,'gridSpacing':100.0,
        'gridOffsetX':0.0,'gridOffsetY':0.0,
        'labelOnBottom':True,'showIconPreview':True,
        'showItemInfo':False,'arrangeBy':'none',
        'scrollPositionX':0.0,'scrollPositionY':0.0,
    }
    store['.']['vstl']=('type',b'icnv')
    store['.']['icvo']=('bool',True)
    store['Codex Buddy.app']['Iloc']=(204,220)
    store['Applications']['Iloc']=(516,220)
    # Finder can retain the user's global path bar preference. Keep two guide
    # label lines above that bar instead of depending on ShowPathbar=False.
    store['安装指南 Installation Guide.pdf']['Iloc']=(360,428)
print('Configured 720 x 600 Finder frame for the 720 x 540 content canvas')
