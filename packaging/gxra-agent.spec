# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec — build on the target OS/CPU (see .github/workflows/build.yml).

from pathlib import Path

block_cipher = None
root = Path(SPECPATH).resolve().parents[1]

a = Analysis(
    [str(root / "gxra" / "agent" / "__main__.py")],
    pathex=[str(root)],
    binaries=[],
    datas=[],
    hiddenimports=[
        "gxra.agent.cli",
        "gxra.agent.collectors.linux",
        "gxra.agent.collectors.windows",
        "gxra.agent.collectors.darwin",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name="gxra-agent",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
