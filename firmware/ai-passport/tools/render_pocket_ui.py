#!/usr/bin/env python3
"""Render actual firmware widgets with LVGL on the host; no device access."""
import argparse
from pathlib import Path
import subprocess
ROOT = Path(__file__).resolve().parents[1]

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--lvgl',type=Path,required=True)
    parser.add_argument('--pet',type=Path,help='Optional verified sixteen-frame resource for host rendering')
    args=parser.parse_args()
    host=ROOT/'build/pocket-ui'; host.mkdir(parents=True,exist_ok=True)
    source=host/'source'; source.mkdir(exist_ok=True)
    pet=(ROOT/'assets/pets/nomi/frames-rgb565.bin').read_bytes()
    (source/'pet.c').write_text('const unsigned char pet_frames[] __asm__("_binary_pet_frames_start") = {\n'+','.join(str(b) for b in pet)+'};\n')
    cmake=f'''cmake_minimum_required(VERSION 3.16)
project(pocket_preview C CXX ASM)
set(CONFIG_LV_BUILD_DEMOS OFF CACHE BOOL "" FORCE)
set(CONFIG_LV_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(CONFIG_LV_USE_THORVG_INTERNAL OFF CACHE BOOL "" FORCE)
set(LV_BUILD_CONF_PATH "{ROOT}/tests/pocket_render/lv_conf.h" CACHE PATH "" FORCE)
add_subdirectory("{args.lvgl.resolve()}" lvgl)
add_executable(pocket_render "{ROOT}/tests/pocket_render/main.c" "{ROOT}/main/companion_ui.c" "{ROOT}/main/companion_model.c" "{ROOT}/assets/fonts/cp_font16.c" "{ROOT}/assets/fonts/cp_font20.c" "{ROOT}/assets/fonts/cp_digits58.c" pet.c)
target_include_directories(pocket_render PRIVATE "{ROOT}/tests/pocket_render" "{ROOT}/main")
target_link_libraries(pocket_render PRIVATE lvgl::lvgl m)
'''
    (source/'CMakeLists.txt').write_text(cmake)
    subprocess.run(['cmake','-S',str(source),'-B',str(host/'cmake'),'-G','Ninja'],check=True)
    subprocess.run(['cmake','--build',str(host/'cmake'),'-j','8'],check=True)
    subprocess.run([str(host/'cmake/pocket_render'),str(host)]+([str(args.pet.resolve())] if args.pet else []),check=True,timeout=30)
    from PIL import Image,ImageDraw,ImageFont
    labels=['Pet screensaver','Quota · demo values','Task reminder','Hold to dictate','Confirmed insertion','Disconnected','Presentation · demo count','Presentation · focus paused','Presentation · permission','Reminder · layout restored']
    canvas=Image.new('RGB',(3*280,4*372),(231,233,238))
    draw=ImageDraw.Draw(canvas)
    for i,file in enumerate(sorted(host.glob('*.ppm'))):
        image=Image.open(file); image.save(file.with_suffix('.png'))
        x=(i%3)*280+20; y=(i//3)*372+16
        canvas.paste(image,(x,y)); draw.text((x,y+329),labels[i],fill=(48,50,57))
    canvas.save(host/'actual-firmware-ui.png')
    print(host/'actual-firmware-ui.png')
if __name__=='__main__': main()
