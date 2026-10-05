# Native app icon

Resources/AppIcon.icon is an editable Icon Composer document. The five foreground
layers preserve the approved cat, terminal cutouts, four dots and original layout.
The shared group uses Icon Composer's default Liquid Glass effects, neutral shadow
and translucency. Apple renders the highlights and material depth.

Default uses the original blue automatic gradient with a white foreground. Dark
keeps the brand-blue background and specifies black for the cat and four dots.
Mono remains a system-rendered appearance.

build.sh requires Xcode 26 or later for actool and compiles the document to
Assets.car and the corresponding AppIcon.icns. Both shipping icon resources must
come from the same compiler output; the source AppIcon.icns is not copied over the
compiled fallback. BuddyMark.png independently preserves the canonical flat artwork
used in Settings and usage sharing. The compiler and Icon Composer are build tools
and are not included in the application.

Reference: https://developer.apple.com/icon-composer/
