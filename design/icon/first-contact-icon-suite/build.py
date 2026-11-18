#!/usr/bin/env python3
"""Build/validate the approved First Contact icons. Requires Pillow and librsvg."""
from pathlib import Path
import argparse
import copy
import hashlib
import io
import json
import shutil
import subprocess
import xml.etree.ElementTree as ET
import zipfile
from PIL import Image, ImageDraw, ImageFont

ROOT=Path(__file__).resolve().parent
SOURCE=ROOT/'source/eclipse.svg'
APP_ID='dev.nicholas.productivity_app'
LINUX=[16,22,24,32,48,64,96,128,256,512,1024]
ANDROID={'mdpi':1,'hdpi':1.5,'xhdpi':2,'xxhdpi':3,'xxxhdpi':4}
SIZES=sorted(set(LINUX+[20,40,2048]))
NS='http://www.w3.org/2000/svg'
ET.register_namespace('',NS)

def write(path,data):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_bytes(data)

def render(source,size):
    return subprocess.run(['rsvg-convert','-w',str(size),'-h',str(size)],input=source,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout

def android_foreground():
    # An adaptive icon's top layer: the sun and moon alone on a 108dp canvas,
    # over a red background layer (android/.../values/colors.xml). The red
    # tile would span the 72dp a launcher shows, so they sit where they do in
    # the circle whatever shape the launcher cuts.
    original=ET.parse(SOURCE).getroot()
    doc=ET.Element(f'{{{NS}}}svg',width='432',height='432',viewBox='0 0 108 108')
    art=ET.SubElement(doc,f'{{{NS}}}g',transform='translate(18 18) scale(1.125)')
    for child in original.find(f'{{{NS}}}g'):
        if child.get('fill')!='#C44430':
            art.append(copy.deepcopy(child))
    return ET.tostring(doc,encoding='utf-8',xml_declaration=True)

def android_assets(source):
    foreground=android_foreground()
    assets={}
    for density,scale in ANDROID.items():
        assets[f'mipmap-{density}/ic_launcher.png']=render(source,round(48*scale))
        assets[f'mipmap-{density}/ic_launcher_foreground.png']=render(foreground,round(108*scale))
    return assets

def frame(data):
    return Image.open(io.BytesIO(data)).convert('RGBA')

def validate_png(data,size):
    im=frame(data)
    assert im.size==(size,size)
    a=im.getchannel('A')
    assert all(a.getpixel(pt)==0 for pt in [(0,0),(size-1,0),(0,size-1),(size-1,size-1)])
    assert im.getpixel((size//2,size//2))[3]==255
    assert a.getbbox()==(0,0,size,size),(size,a.getbbox())
    return im

def preview(png):
    sheet=Image.new('RGB',(1600,1120),'#E6E2DC')
    d=ImageDraw.Draw(sheet)
    fonts='/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'
    title=ImageFont.truetype(fonts,32)
    label=ImageFont.truetype(fonts,21)
    small=ImageFont.truetype(fonts,16)
    d.text((40,24),'ECLIPSE / FIRST CONTACT — ICON SUITE',font=title,fill='#3D302D')
    for x,bg,fg in [(30,'#F8F6F0','#3D302D'),(820,'#24262C','#EEEAE2')]:
        d.rounded_rectangle((x,90,x+750,1090),radius=18,fill=bg)
        d.text((x+28,115),'Adjusted composition / original ivory moon',font=label,fill=fg)
        im=frame(png[512]);im.thumbnail((340,340),Image.Resampling.LANCZOS)
        sheet.paste(im,(x+205,165),im)
        d.text((x+28,548),'Linux',font=label,fill=fg)
        im=frame(png[256]);im.thumbnail((200,200),Image.Resampling.LANCZOS)
        sheet.paste(im,(x+275,590),im)
        d.text((x+28,832),'Native pixel sizes',font=label,fill=fg)
        xx=x+28
        for size in [16,20,24,32,40,48,64,128]:
            im=frame(png[size]);sheet.paste(im,(xx,1008-size),im)
            d.text((xx,1020),str(size),font=small,fill=fg)
            xx+=max(size,26)+18
    sheet.save(ROOT/'preview.png')

def update_project():
    repo=ROOT.parents[2]
    assert (repo/'pubspec.yaml').is_file(),'--update-project requires the suite inside this repository'
    copied=[]
    for source in (ROOT/'linux/icons/hicolor').rglob('*'):
        if source.is_file():
            dest=repo/'linux/icons/hicolor'/source.relative_to(ROOT/'linux/icons/hicolor')
            write(dest,source.read_bytes());copied.append((source,dest))
    for source in (ROOT/'android/res').rglob('*.png'):
        dest=repo/'android/app/src/main/res'/source.relative_to(ROOT/'android/res')
        write(dest,source.read_bytes());copied.append((source,dest))
    write(repo/'web/icon.svg',SOURCE.read_bytes());copied.append((SOURCE,repo/'web/icon.svg'))
    for source,dest in copied:
        assert source.read_bytes()==dest.read_bytes()
    return len(copied)

def build(install=False):
    source=SOURCE.read_bytes()
    master=ET.fromstring(source)
    assert {e.get('fill') for e in master.iter() if e.get('fill')}=={'#C44430','#F8BD49','#FFF6DE'}
    png={s:render(source,s) for s in SIZES}
    frames={s:validate_png(data,s) for s,data in png.items()}
    for size,data in png.items():
        write(ROOT/f'png/eclipse-{size}.png',data)
    for size in LINUX:
        write(ROOT/f'linux/icons/hicolor/{size}x{size}/apps/{APP_ID}.png',png[size])
    write(ROOT/f'linux/icons/hicolor/scalable/apps/{APP_ID}.svg',source)
    for name,data in android_assets(source).items():
        write(ROOT/'android/res'/name,data)
    # Validate actual source colours at stable interior points at master size.
    im=frames[1024]
    for point,color in [((32,5),(196,68,48,255)),((20,20),(248,189,73,255)),((38,37),(255,246,222,255))]:
        assert im.getpixel(tuple(round(v*16) for v in point))==color
    copied=update_project() if install else 0
    checks=[f'{len(png)} native vector PNG renders validated (16–2048px)','Approved three-colour palette and original ivory moon verified',f'{copied} project assets copied and verified' if install else 'Standalone build; project assets not copied']
    preview(png)
    manifest={'design':'First Contact — adjusted sun and moon placement, 5% smaller original ivory moon, reference edge contours','source':'source/eclipse.svg','sourceSha256':hashlib.sha256(source).hexdigest(),'appId':APP_ID,'palette':{'background':'#C44430','sun':'#F8BD49','moon':'#FFF6DE'},'composition':{'canvas':64,'sun':{'centre':[29,29.75],'nominalRadius':19},'moon':{'centre':[37.5,36.55],'nominalRadius':16.15}},'linuxSizes':LINUX,'masterPngSizes':SIZES,'applicationIntegration':install,'validation':checks}
    write(ROOT/'manifest.json',(json.dumps(manifest,indent=2)+'\n').encode())
    files={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(ROOT.rglob('*')) if p.is_file() and p.name!='SHA256SUMS' and '__pycache__' not in p.parts}
    write(ROOT/'SHA256SUMS',''.join(f'{digest}  {name}\n' for name,digest in files.items()).encode())
    archive=ROOT.parent/'first-contact-icon-suite.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
        for path in sorted(ROOT.rglob('*')):
            if path.is_file() and '__pycache__' not in path.parts:
                z.write(path,f'{ROOT.name}/{path.relative_to(ROOT)}')
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
    print('\n'.join(checks))
    print(f'ZIP verified: {archive}')

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--update-project',action='store_true',help='Copy generated assets into this app repository')
    build(parser.parse_args().update_project)
