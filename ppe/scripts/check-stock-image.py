#!/usr/bin/env python3
"""AX6 单槽 stock 布局的镜像体积 / UBI / sysupgrade 结构校验。

本文件派生自 Steven-ZYC/AX6-OpenWrt-Tiny（MIT）的 scripts/check-stock-image.py，
只改了两处常量与两处文案，其余结构校验逐字保留。

为什么改：
  上游取 MAX = 28 MiB，依据是 `STOCK_MTD_BYTES = 0x023C0000`（35.75 MiB），
  那是**小米原厂 A/B 双槽里单槽**的大小。本机已被刷成单卷大 UBI：
      mtd12 "rootfs" = 0x06640000 = 102.25 MiB
      ubi0: 818 LEB × 126,976 B = 99.0 MiB 可用，坏块 0
  沿用 28 MiB 会把合法镜像直接判死，且与本机物理上限差 2.9 倍。

  MAX 取 64 MiB 而不是贴着 99 MiB，是为了给 rootfs_data（overlay 可写区）留空间：
      818 LEB = kernel(47) + rootfs(≤512) + rootfs_data(≥259 ≈ 32 MiB)
  64 MiB 下 rootfs 约占 512 LEB，overlay 还剩 ~32 MiB，装 tailscale 后的
  增量（压缩后约 8–9 MiB）有充足余量。

口径说明：这只是 CI 守卫，不是刷机安全认证。真机仍需核对 /proc/mtd、
当前槽位、UBI 坏块与引导标志位。
"""
from __future__ import annotations

import pathlib
import struct
import sys
import tarfile

MIB = 1024 * 1024
# 本机 mtd12 实测值（0x06640000 = 107,216,896 B = 102.25 MiB）
STOCK_MTD_BYTES = 0x06640000
MAX_FACTORY_BYTES = 64 * MIB
PEB_BYTES = 128 * 1024


def check(sysupgrade: pathlib.Path, factory: pathlib.Path) -> str:
    if not sysupgrade.is_file() or not factory.is_file():
        raise ValueError("both factory.ubi and sysupgrade.bin must exist")
    if "redmi_ax6-stock" not in sysupgrade.name or not sysupgrade.name.endswith("-sysupgrade.bin"):
        raise ValueError("unexpected sysupgrade filename; expected AX6 stock layout")
    if "redmi_ax6-stock" not in factory.name or not factory.name.endswith("-factory.ubi"):
        raise ValueError("unexpected factory UBI filename; expected AX6 stock layout")
    factory_bytes = factory.stat().st_size
    upgrade_bytes = sysupgrade.stat().st_size
    if factory_bytes > MAX_FACTORY_BYTES:
        raise ValueError(
            f"factory UBI {factory_bytes} bytes exceeds cap "
            f"{MAX_FACTORY_BYTES} bytes ({MAX_FACTORY_BYTES // MIB} MiB)"
        )
    if not factory_bytes or factory_bytes % PEB_BYTES:
        raise ValueError("factory UBI is not an exact multiple of 128 KiB erase blocks")
    if upgrade_bytes > MAX_FACTORY_BYTES:
        raise ValueError(
            f"sysupgrade archive {upgrade_bytes} bytes exceeds cap "
            f"{MAX_FACTORY_BYTES} bytes ({MAX_FACTORY_BYTES // MIB} MiB)"
        )

    volume_ids: set[int] = set()
    with factory.open("rb") as handle:
        for index in range(factory_bytes // PEB_BYTES):
            block = handle.read(PEB_BYTES)
            if block[:4] != b"UBI#":
                raise ValueError(f"factory UBI missing EC header at erase block {index}")
            vid_offset = struct.unpack_from(">I", block, 16)[0]
            if vid_offset + 12 > PEB_BYTES or block[vid_offset:vid_offset + 4] != b"UBI!":
                raise ValueError(f"factory UBI has invalid VID header at erase block {index}")
            volume_ids.add(struct.unpack_from(">I", block, vid_offset + 8)[0])
    if not {0, 1}.issubset(volume_ids):
        raise ValueError("expected both kernel (volume 0) and rootfs (volume 1) in factory UBI")

    try:
        with tarfile.open(sysupgrade, "r:*") as archive:
            entries = {pathlib.PurePosixPath(m.name).name: m for m in archive.getmembers() if m.isfile()}
            if "kernel" not in entries or "root" not in entries or "CONTROL" not in entries:
                raise ValueError("sysupgrade must contain kernel, root and CONTROL entries")
            kernel_bytes = entries["kernel"].size
            root_bytes = entries["root"].size
            if not (0 < kernel_bytes < MAX_FACTORY_BYTES and 0 < root_bytes < MAX_FACTORY_BYTES):
                raise ValueError("empty or unusually oversized kernel/rootfs in sysupgrade")
    except (tarfile.TarError, OSError) as exc:
        raise ValueError(f"invalid sysupgrade tar archive: {exc}") from exc

    return "\n".join((
        f"- **HARD SIZE GATE: PASS** ({MAX_FACTORY_BYTES // MIB} MiB maximum factory UBI)",
        f"- Local mtd12 reference: {STOCK_MTD_BYTES / MIB:.2f} MiB; "
        f"reserved nominal headroom: {(STOCK_MTD_BYTES - MAX_FACTORY_BYTES) / MIB:.2f} MiB",
        f"- Factory UBI: **{factory_bytes / MIB:.2f} MiB** "
        f"({factory_bytes} bytes; {factory_bytes // PEB_BYTES} × 128 KiB erase blocks)",
        f"- Sysupgrade image: **{upgrade_bytes / MIB:.2f} MiB** ({upgrade_bytes} bytes)",
        f"- Sysupgrade kernel: {kernel_bytes / MIB:.2f} MiB; SquashFS root: {root_bytes / MIB:.2f} MiB",
        "- **NOT a flash-safety certification**: verify /proc/mtd, active slot, UBI bad blocks, "
        "bootloader and upgrade method on the actual AX6.",
    ))


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("usage: check-stock-image.py PATH_TO_SYSUPGRADE_BIN PATH_TO_FACTORY_UBI")
        print(check(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])))
    except ValueError as exc:
        print(f"ERROR: AX6 stock-layout image rejected: {exc}", file=sys.stderr)
        sys.exit(1)
