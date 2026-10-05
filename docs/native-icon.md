# Native app icon

Resources/AppIcon.icon is an editable Icon Composer document. The five foreground
layers preserve the approved cat, terminal cutouts, four dots and original layout.
The shared group uses Icon Composer's default Liquid Glass effects, neutral shadow
and translucency. Apple renders the highlights and material depth.

Default uses the blue gradient from the system App Store icon with a white
foreground. Dark uses a system-style black gradient with the same blue gradient
for the cat and four dots. The blue stops retain their Display P3 and sRGB color
spaces; the gradients run vertically.
Mono remains a system-rendered appearance.

build.sh requires Xcode 26 or later for actool and compiles the document to
Assets.car and the corresponding AppIcon.icns. Both shipping icon resources must
come from the same compiler output; the source AppIcon.icns is not copied over the
compiled fallback. Settings uses a cached frameless template of the original cat
and four dots, black in light appearance and white in dark appearance. Its header
shows only the app name; the current version appears in the update section.
BuddyMark.png independently preserves the canonical flat artwork used in usage
sharing. The compiler and Icon Composer are build tools
and are not included in the application.

Reference: https://developer.apple.com/icon-composer/
