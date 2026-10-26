#!/usr/bin/env python3
"""Build the Eclipse app icons from approved vectors: the Tela-circle-proportioned
Linux and Windows circle, and a macOS squircle on Apple's 824-in-1024 grid."""
from pathlib import Path
import argparse
import base64
import copy
import hashlib
import io
import json
import shutil
import subprocess
import xml.etree.ElementTree as ET
from zipfile import ZipFile, ZIP_DEFLATED

from PIL import Image

SCRIPT = Path(__file__).resolve()
STANDALONE = (SCRIPT.parent/'mark.svg').is_file()
REPO = None if STANDALONE else SCRIPT.parents[1]
PACK = SCRIPT.parent.parent if STANDALONE else REPO/'design/icon/eclipse-linux-circle'
APP_ID = 'dev.nicholas.productivity_app'
NS = 'http://www.w3.org/2000/svg'
SIZES = [16,24,32,48,64,128,256,512]
MAC = [16,32,64,128,256,512,1024]
WIN = [16,20,24,32,40,48,64,128,256]
ET.register_namespace('',NS)


def glyph(small):
    root = ET.parse(PACK/'source'/('mark-small.svg'if small else'mark.svg')).getroot()
    group = copy.deepcopy(root.find(f'{{{NS}}}g'))
    group.set('fill','#211B2B')
    return ET.tostring(group,encoding='unicode')


def icon(size=512):
    small = size<=64
    side = 54*(.78 if small else .74)
    x = (64-side)/2+.54
    y = (64-side)/2-.54
    # Native-pixel placement of the existing optical master in the tiniest circles.
    if size in [16,24,32]:
        px,py,ps={16:(3,2.5,10.5),24:(4.5,3.75,15.75),32:(5.75,5.25,21)}[size]
        x,y,side=[value*64/size for value in [px,py,ps]]
    bounds='102.75 101 818.75 823'if small else'102.75 100 818.75 824'
    return (f'<svg xmlns="{NS}" width="64" height="64" viewBox="0 0 64 64">'
            '<title>Eclipse - Stillness subtle rugged - circular Linux icon</title>'
            '<desc>Ink eclipse on an off-white circle, with transparent margins matching the common Tela-circle 54-in-64 grid.</desc>'
            '<circle cx="32" cy="32" r="27" fill="#F8F7F4"/>'
            f'<svg x="{x:.8f}" y="{y:.8f}" width="{side:.8f}" height="{side:.8f}" viewBox="{bounds}">'
            f'{glyph(small)}</svg></svg>')


def mac_icon(size):
    small = size<=64
    side = 824*(.74 if small else .70)
    x = 100+(824-side)/2+824*.008
    y = 100+(824-side)/2-824*.009
    bounds='102.75 101 818.75 823'if small else'102.75 100 818.75 824'
    return (f'<svg xmlns="{NS}" width="1024" height="1024" viewBox="0 0 1024 1024">'
            '<title>Eclipse - Stillness subtle rugged - macOS icon</title>'
            '<rect x="100" y="100" width="824" height="824" rx="185" fill="#F8F7F4"/>'
            f'<svg x="{x:.8f}" y="{y:.8f}" width="{side:.8f}" height="{side:.8f}" viewBox="{bounds}">'
            f'{glyph(small)}</svg></svg>')


def mac_catalog():
    folder=PACK/'macos/AppIcon.appiconset';folder.mkdir(parents=True,exist_ok=True)
    for size in MAC:
        (folder/f'app_icon_{size}.png').write_bytes(render(mac_icon(size),size))
    images=[{'size':f'{base}x{base}','idiom':'mac','filename':f'app_icon_{base*scale}.png','scale':f'{scale}x'}
            for base in [16,32,128,256,512] for scale in [1,2]]
    (folder/'Contents.json').write_text(json.dumps({'images':images,'info':{'version':1,'author':'xcode'}},indent=2)+'\n')


def windows_ico():
    folder=PACK/'windows';folder.mkdir(exist_ok=True)
    frames=[Image.open(io.BytesIO(render(icon(size),size))).convert('RGBA')for size in WIN]
    frames[-1].save(folder/'app_icon.ico',format='ICO',sizes=[(s,s)for s in WIN],append_images=frames[:-1])


def render(data,size):
    result=subprocess.run(['rsvg-convert','-w',str(size),'-h',str(size)],input=data.encode(),
                          stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True)
    return result.stdout


def png_embed(path,x,y,size):
    data=base64.b64encode(path.read_bytes()).decode()
    return f'<image x="{x}" y="{y}" width="{size}" height="{size}" href="data:image/png;base64,{data}"/>'


def make_preview():
    doc=f'<svg xmlns="{NS}" width="1400" height="1070" viewBox="0 0 1400 1070">'
    doc+='<rect width="1400" height="1070" fill="#E8E5EA"/><g font-family="DejaVu Sans,sans-serif">'
    doc+='<text x="60" y="78" font-size="34" letter-spacing="3" fill="#211B2B">ECLIPSE / CIRCULAR LINUX ICON</text>'
    doc+='<text x="60" y="125" font-size="21" fill="#6A6073">Subtle rugged mark - ink on off-white - Tela-circle proportions</text>'
    for x,bg,fg in [(60,'#F4F3F0','#514859'),(730,'#25212D','#DED7E6')]:
        doc+=f'<rect x="{x}" y="170" width="610" height="590" rx="18" fill="{bg}"/>'
        doc+=png_embed(PACK/'eclipse-linux-circle-512.png',x+49,195,512)
        doc+=f'<text x="{x+35}" y="725" font-size="21" fill="{fg}">True circular silhouette / transparent corners</text>'
        doc+=f'<rect x="{x}" y="790" width="610" height="210" rx="18" fill="{bg}"/>'
        xx=x+30
        for size in [16,24,32,48,64,128]:
            path=PACK/f'icons/hicolor/{size}x{size}/apps/{APP_ID}.png'
            doc+=png_embed(path,xx,950-size,size)
            doc+=f'<text x="{xx}" y="978" font-size="16" fill="{fg}">{size}</text>'
            xx+=max(size,38)+22
    doc+='<text x="60" y="1043" font-size="18" fill="#6A6073">Circle diameter: 54 / 64 canvas units. Original fragile flecks retained; no surface dots.</text>'
    doc+='</g></svg>'
    folder=PACK/'preview';folder.mkdir(exist_ok=True)
    (folder/'light-and-dark.svg').write_text(doc)
    subprocess.run(['rsvg-convert',str(folder/'light-and-dark.svg'),'-o',str(folder/'light-and-dark.png')],check=True)


def build(update=False):
    if update and REPO is None:
        raise ValueError('Use the repository generator to update project assets.')
    for size in SIZES:
        file=PACK/f'icons/hicolor/{size}x{size}/apps/{APP_ID}.png'
        file.parent.mkdir(parents=True,exist_ok=True)
        file.write_bytes(render(icon(size),size))
    file=PACK/f'icons/hicolor/scalable/apps/{APP_ID}.svg'
    file.parent.mkdir(parents=True,exist_ok=True)
    file.write_text(icon())
    shutil.copy2(PACK/f'icons/hicolor/512x512/apps/{APP_ID}.png',PACK/'eclipse-linux-circle-512.png')
    mac_catalog()
    windows_ico()
    make_preview()
    if update:
        for file in (PACK/'icons/hicolor').rglob('*'):
            if file.is_file():
                target=REPO/'linux/icons/hicolor'/file.relative_to(PACK/'icons/hicolor')
                target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(file,target)
        for file in (PACK/'macos/AppIcon.appiconset').iterdir():
            shutil.copy2(file,REPO/'macos/Runner/Assets.xcassets/AppIcon.appiconset'/file.name)
        shutil.copy2(PACK/'windows/app_icon.ico',REPO/'windows/runner/resources/app_icon.ico')
    record={'appId':APP_ID,'variant':'Linux circle / subtle rugged / clean moon',
            'circle':{'canvas':64,'cx':32,'cy':32,'radius':27,'fill':'#F8F7F4'},'ink':'#211B2B',
            'sizes':SIZES,'macos':{'canvas':1024,'tile':824,'radius':185,'sizes':MAC},'windowsIco':WIN,'smallMasterAtOrBelow':64,'fullGlyphFractionOfDisc':.74,'smallGlyphFractionOfDisc':.78,
            'research':'https://github.com/vinceliuice/Tela-circle-icon-theme',
            'sources':{n:hashlib.sha256((PACK/'source'/n).read_bytes()).hexdigest()for n in ['mark.svg','mark-small.svg']}}
    (PACK/'manifest.json').write_text(json.dumps(record,indent=2)+'\n')
    portable=PACK/'source/build.py'
    if SCRIPT!=portable.resolve():shutil.copy2(SCRIPT,portable)
    with ZipFile(PACK.with_suffix('.zip'),'w',ZIP_DEFLATED)as archive:
        for file in sorted(PACK.rglob('*')):
            if file.is_file()and'__pycache__'not in file.parts:
                archive.write(file,f'{PACK.name}/{file.relative_to(PACK)}')
    print(f'Built circle variant: {PACK}')
    if update:print('Updated Linux, macOS and Windows app icons.')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--update-project',action='store_true')
    args=parser.parse_args()
    build(args.update_project)
