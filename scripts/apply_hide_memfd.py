#!/usr/bin/env python3
"""
apply_hide_memfd.py — 在 GKI 内核源码里注入"隐藏 memfd 库映射"补丁

用法（在 kernel 源码根目录）：
    python3 apply_hide_memfd.py [fs/proc/task_mmu.c]

特点：
- 按函数签名定位，不依赖行号，适配 android15-6.6 / 6.6.x-lts 等分支
- 幂等：已打过补丁会直接跳过
- 只改显示层（show_map_vma/show_smap/show_numa_map），不影响 VMA 本身

放到 zzh20188/GKI_KernelSU_SUSFS 的构建流程里时，在拉取内核源码之后、
编译之前执行本脚本即可。
"""

import re
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "fs/proc/task_mmu.c"
MARK = "vma_is_memfd_lib"

HELPER = """
static inline bool vma_is_memfd_lib(struct vm_area_struct *vma)
{
\tstruct file *file = vma->vm_file;
\tconst char *name;

\tif (!file)
\t\treturn false;
\tname = file->f_path.dentry->d_name.name;
\tif (!name)
\t\treturn false;
\t/* memfd-backed shared object, e.g. "lib10edb57537.so" */
\tif (strncmp(name, "lib", 3) != 0)
\t\treturn false;
\treturn strstr(name, ".so") != NULL;
}
"""


def insert_helper(src: str) -> str:
    if "vma_is_memfd_lib(struct vm_area_struct" in src:
        return src
    anchor = re.search(r"\nstatic void\s*\nshow_map_vma\(", src)
    if not anchor:
        anchor = re.search(r"\nstatic void\s+show_map_vma\(", src)
    if not anchor:
        raise SystemExit("找不到 show_map_vma 定义")
    return src[: anchor.start()] + "\n" + HELPER + src[anchor.start() :]


def insert_guard(src: str, fn_name: str) -> str:
    # 找到函数体开头，紧跟 { 之后插入 early return
    pattern = re.compile(r"(\b" + fn_name + r"\s*\([^)]*\)\s*\{)")
    m = pattern.search(src)
    if not m:
        print(f"[skip] 找不到 {fn_name}")
        return src
    head_end = m.end()
    # 已在该函数里插过就跳过
    window = src[head_end : head_end + 400]
    if "vma_is_memfd_lib" in window:
        print(f"[skip] {fn_name} 已打补丁")
        return src
    guard = "\n\tif (vma_is_memfd_lib(vma))\n\t\treturn 0;\n"
    if fn_name == "show_map_vma":
        guard = "\n\tif (vma_is_memfd_lib(vma))\n\t\treturn;\n"
    return src[:head_end] + guard + src[head_end:]


def main() -> None:
    with open(PATH, "r", encoding="utf-8", errors="ignore") as f:
        src = f.read()
    if MARK in src and "show_smap" in src:
        # 粗判：已有 helper 且 show_smap 里也有 guard 就跳过
        pass
    src = insert_helper(src)
    for fn in ("show_map_vma", "show_smap", "show_numa_map"):
        src = insert_guard(src, fn)
    with open(PATH, "w", encoding="utf-8") as f:
        f.write(src)
    print(f"[ok] patched {PATH}")


if __name__ == "__main__":
    main()
