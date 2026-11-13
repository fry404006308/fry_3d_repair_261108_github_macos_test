# -*- coding: utf-8 -*-
"""
★172 macOS 渲染压力测试：同一个进程里反复「建 pyrender 离屏渲染器 → 渲一帧 → 删掉」N 次。

为什么要有它
    同事在 Apple M5 / macOS 26 上跑 v2.11.0 arm64 包：修复链第 11 步渲六视图时报
    AttributeError: ObjCInstance b'PygletDelegate' has no attribute b'initWithAttributes_'
    这是 pyglet 在 macOS 上「同一进程反复建 / 关窗口」时 Objective-C 对象的内存管理问题（pyglet issue #1089，
    2.0.18 修复）。HG100 每次渲六视图都新建一个 OffscreenRenderer（= 一个隐藏的 pyglet 窗口）再删掉，
    一次修复要建删十几次 —— 次数越多越容易撞上。单跑一次自检不一定复现，所以这里专门反复建删。
用法
    <软件> render_stress.py <输出目录> [次数，默认 80]      （便携包启动器会挂好 runtime 与 app 路径）
输出
    <输出目录>/render_stress.json：pyglet / pyrender 版本、成功次数、第一次失败的序号与报错；退出码 0 = 全部成功
"""
import json
import platform
import sys
import time
import traceback
from pathlib import Path


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    out = Path(argv[0] if argv else 'render_stress_out'); out.mkdir(parents=True, exist_ok=True)
    n = int(argv[1]) if len(argv) > 1 else 80
    rep = dict(platform_str=platform.platform(), machine_str=platform.machine(), n_int=n, ok_int=0,
               first_fail_int=None, error_str='', seconds_float=0.0)
    t0 = time.time()
    try:
        import numpy as np
        import pyglet
        import pyrender
        import trimesh
        rep['pyglet_str'] = pyglet.version
        rep['pyrender_str'] = getattr(pyrender, '__version__', '?')
        mesh = pyrender.Mesh.from_trimesh(trimesh.creation.box(extents=(1, 1, 1)))
        for i in range(n):
            try:
                scene = pyrender.Scene(bg_color=(255, 255, 255, 0))
                scene.add(mesh)
                cam = pyrender.OrthographicCamera(xmag=1.0, ymag=1.0)
                pose = np.eye(4); pose[2, 3] = 3.0
                scene.add(cam, pose=pose)
                scene.add(pyrender.DirectionalLight(intensity=3.0), pose=pose)
                size = (64, 96, 128)[i % 3]                     # 尺寸轮换：与 HG100 的 768 / 卡片尺寸交替相似
                off = pyrender.OffscreenRenderer(viewport_width=size, viewport_height=size)
                try:
                    color, depth = off.render(scene)
                    assert color.shape[0] == size and float((depth > 0).mean()) > 0.05, '渲出来是空的'
                finally:
                    off.delete()
                rep['ok_int'] += 1
            except Exception as exc:                            # noqa: BLE001
                rep['first_fail_int'] = i
                rep['error_str'] = '%s: %s' % (type(exc).__name__, exc)
                rep['traceback_str'] = traceback.format_exc()[-3000:]
                break
    except Exception as exc:                                    # noqa: BLE001
        rep['error_str'] = 'setup %s: %s' % (type(exc).__name__, exc)
        rep['traceback_str'] = traceback.format_exc()[-3000:]
    rep['seconds_float'] = round(time.time() - t0, 1)
    (out / 'render_stress.json').write_text(json.dumps(rep, ensure_ascii=False, indent=1), encoding='utf-8')
    print('渲染压力测试：%d / %d 成功%s（pyglet %s）' % (rep['ok_int'], n, '' if rep['ok_int'] == n else '，第 %s 次失败：%s' % (
        rep['first_fail_int'], rep['error_str']), rep.get('pyglet_str')))
    return 0 if rep['ok_int'] == n else 1


if __name__ == '__main__':
    raise SystemExit(main())
