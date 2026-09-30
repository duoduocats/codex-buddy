#!/usr/bin/env python3
"""Create the small Finder background and a bilingual, illustrated install guide.

Install build-only dependencies from requirements-installer-assets.txt. On macOS the
system Arial Unicode font supplies Chinese glyphs; only used glyphs are embedded
in the PDF. The drawings are illustrations, not captures of a user's computer.
"""
from pathlib import Path
import argparse
from PIL import Image, ImageDraw, ImageFont
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.colors import HexColor
from reportlab.lib.utils import ImageReader

ROOT = Path(__file__).resolve().parent.parent
FONT = Path('/System/Library/Fonts/Supplemental/Arial Unicode.ttf')
REGULAR = Path('/System/Library/Fonts/Supplemental/Arial.ttf')
BOLD = Path('/System/Library/Fonts/Supplemental/Arial Bold.ttf')
BLUE = '#2462F4'
INK = '#182844'
MUTED = '#62718A'
PDF_NAME = 'Installation-Guide.pdf'


def background(out):
    scale = 2
    image = Image.new('RGB', (1440, 1080), '#F6F9FF')
    draw = ImageDraw.Draw(image)
    # A restrained light-blue wash stays legible behind Finder's icon labels.
    for y in range(1080):
        t = y / 1080
        draw.line((0, y, 1440, y), fill=(int(247 - 9*t), int(250 - 7*t), 255))
    def label(text, xy, size, color=INK, strong=False, center=True):
        font = ImageFont.truetype(str(BOLD if strong and text.isascii() else FONT), size * scale)
        draw.text(tuple(v*scale for v in xy), text, fill=color, font=font,
                  anchor='mt' if center else 'lt')
    label('Codex Buddy', (360, 38), 30, strong=True)
    label('拖入 Applications，开始使用', (360, 84), 16)
    label('Drag into Applications to install', (360, 111), 14, MUTED)
    # Finder places the real app and Applications icons over these two positions.
    draw.rounded_rectangle((135*scale, 153*scale, 273*scale, 283*scale),
                           radius=26*scale, fill='#FFFFFF')
    draw.rounded_rectangle((447*scale, 153*scale, 585*scale, 283*scale),
                           radius=26*scale, fill='#FFFFFF')
    draw.line((313*scale, 219*scale, 398*scale, 219*scale), fill=BLUE, width=5*scale)
    draw.line((382*scale, 203*scale, 398*scale, 219*scale, 382*scale, 235*scale),
              fill=BLUE, width=5*scale, joint='curve')
    draw.line((94*scale, 327*scale, 626*scale, 327*scale), fill='#DCE5F6', width=scale)
    label('首次安装？打开下方图文指南', (360, 342), 15)
    label('First install? Open the illustrated guide below', (360, 368), 13, MUTED)
    # The guide icon occupies the clear region below. No metadata is written.
    image.save(out / 'dmg-background.png', optimize=True, dpi=(144,144))


def guide(out):
    pdfmetrics.registerFont(TTFont('Guide', str(FONT)))
    pdfmetrics.registerFont(TTFont('GuideBold', str(BOLD)))
    c = canvas.Canvas(str(out / PDF_NAME), pagesize=(612, 792), invariant=1,
                      pageCompression=1)
    c.setTitle('Codex Buddy - Installation Guide / 安装指南')
    c.setAuthor('Codex Buddy contributors')
    c.setSubject('First installation on macOS: drag to Applications and approve the first launch')
    icon = ImageReader(str(ROOT / 'Resources/AppIcon.iconset/icon_128x128@2x.png'))

    def rect(x, y, w, h, fill='#F2F6FF', radius=12, stroke=None):
        c.setFillColor(HexColor(fill))
        c.setStrokeColor(HexColor(stroke or fill))
        c.roundRect(x, y, w, h, radius, stroke=int(stroke is not None), fill=1)

    def text(value, x, y, size=12, color=INK, bold=False):
        c.setFont('GuideBold' if bold and value.isascii() else 'Guide', size)
        c.setFillColor(HexColor(color))
        c.drawString(x, y, value)

    def number(n, y):
        c.setFillColor(HexColor(BLUE))
        c.circle(54, y+4, 13, stroke=0, fill=1)
        c.setFillColor(HexColor('#FFFFFF'))
        c.setFont('GuideBold', 12)
        c.drawCentredString(54, y, str(n))

    def arrow(x1, x2, y):
        c.setStrokeColor(HexColor(BLUE)); c.setLineWidth(2.5)
        c.line(x1,y,x2,y); c.line(x2-7,y+6,x2,y); c.line(x2-7,y-6,x2,y)

    def folder(x,y):
        rect(x,y,57,39, '#97C6FF', 5)
        rect(x+3,y+34,24,9, '#97C6FF', 3)
        rect(x,y,57,34, '#71B2FF', 5)
        text('A', x+21,y+10,19,'#FFFFFF',True)

    def button(title,x,y,w=110):
        rect(x,y,w,26,BLUE,6)
        c.setFillColor(HexColor('#FFFFFF')); c.setFont('Guide',11)
        c.drawCentredString(x+w/2,y+8,title)

    for lang in ('zh','en'):
        zh = lang == 'zh'
        rect(0,0,612,792,'#FFFFFF',0)
        c.drawImage(icon,42,712,49,49,mask='auto')
        text('Codex Buddy',104,741,25,bold=True)
        text('首次安装指南' if zh else 'First installation',105,719,13,MUTED)
        text('macOS 13+ · Apple silicon',42,682,11,MUTED)

        number(1,647)
        text('拖入应用程序，再从应用程序打开' if zh else 'Drag to Applications, then launch',77,646,15,bold=True)
        rect(77,528,493,99)
        c.drawImage(icon,150,554,45,45,mask='auto')
        arrow(244,354,576); folder(402,555)
        text('Codex Buddy',137,541,10)
        text('Applications',400,541,10)
        text('安装后请从 Applications 文件夹打开 App。' if zh else 'Open Codex Buddy from Applications after copying it.',77,514,11,MUTED)

        number(2,480)
        text('首次启动被拦截时，先关闭提示' if zh else 'If the first launch is blocked, dismiss the alert',77,479,15,bold=True)
        rect(77,397,493,64)
        c.drawImage(icon,92,411,35,35,mask='auto')
        text('无法验证开发者' if zh else 'Developer cannot be verified',143,435,12)
        text('提示措辞随 macOS 版本变化。' if zh else 'The exact wording varies by macOS version.',143,416,10,MUTED)
        text('当前发行版未经过 Apple 公证。' if zh else 'This release has not been notarized by Apple.',77,382,11,MUTED)

        number(3,348)
        text('在系统设置中允许这一个 App' if zh else 'Approve this app in System Settings',77,347,15,bold=True)
        rect(77,223,493,106)
        text('系统设置' if zh else 'System Settings',93,303,11,MUTED)
        arrow(169 if zh else 184,207,307)
        text('隐私与安全性' if zh else 'Privacy & Security',225,303,11,bold=True)
        text('向下滚动至安全性' if zh else 'Scroll down to Security',93,277,11,MUTED)
        text('Codex Buddy',93,245,12)
        button('仍要打开' if zh else 'Open Anyway',429,237,121)
        text('再次确认“打开”；按系统提示验证即可。' if zh else 'Confirm Open, and authenticate if macOS asks.',77,208,11,MUTED)

        number(4,174)
        text('完成，去顶栏查看额度' if zh else 'You are ready. Find Codex Buddy in the menu bar',77,173,15,bold=True)
        text('此后可正常启动，无需重复设置。' if zh else 'Future launches do not need the same approval.',77,151,11,MUTED)
        text('先确认下载来自下方官方 Release，且文件未遭篡改。' if zh else 'Use the official release below and verify the download is intact.',42,116,10,MUTED)
        text('图中设置为示意图；若提示包含恶意软件或 App 已损坏，请停止并重新核对下载。' if zh else 'Illustrations are schematic. Stop if macOS reports malware or a damaged app.',42,98,9,MUTED)
        release='https://github.com/duoduocats/codex-buddy/releases'
        apple='https://support.apple.com/zh-cn/102445' if zh else 'https://support.apple.com/en-us/102445'
        text('下载 / Download: '+release,42,73,9,BLUE)
        c.linkURL(release,(42,70,570,84),relative=0)
        text(('Apple 安全打开说明: ' if zh else 'Apple launch instructions: ')+apple,42,54,9,BLUE)
        c.linkURL(apple,(42,51,570,65),relative=0)
        text('中文 1 / 2' if zh else 'English 2 / 2',500,27,9,MUTED)
        c.showPage()
    c.save()


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--output',type=Path,default=ROOT/'docs/install')
    args=parser.parse_args()
    if not FONT.exists():
        raise SystemExit('Packaging assets require the macOS system Arial Unicode font.')
    args.output.mkdir(parents=True,exist_ok=True)
    background(args.output)
    guide(args.output)
    print('Created Finder background and bilingual Installation-Guide.pdf')
