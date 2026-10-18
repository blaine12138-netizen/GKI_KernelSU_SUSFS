#!/usr/bin/env python3
"""
apply_hide_memfd.py (v2) — 隐藏 memfd 注入库的 proc 映射

v2 关键点：**只对"进程读取自己的 maps"隐藏**（current->mm == vma->vm_mm），
外部读取者（例如验牌器 App 用 root 读游戏 maps 自检）照常能看到该映射。
这样既不破坏外挂自身的注入校验，又能挡住游戏进程内 ACE 的自扫描。

用法（内核源码根目录）：
    python3 apply_hide_memfd.py [fs/proc/task_mmu.c]
"""

import re
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "fs/proc/task_mmu.c"
MARK = "vma_is_memfd_lib"

HELPER = """
static inline bool vma_is_memfd_lib(struct vm_area_struct *vma)
{
\tstruct file *file;
\tconst char *name;

\t/*
\t * Only hide when the process is reading its own maps.
\t * External readers (e.g. the companion app doing root-side
\t * injection checks) still see the mapping.
\t */
\tif (vma->vm_mm != current->mm)
\t\treturn false;

\tfile = vma->vm_file;
\tif (!file)
\t\treturn false;
\tname = file->f_path.dentry->d_name.name;
\tif (!name)
\t\treturn false;
\tif (strncmp(name, "lib", 3) != 0)
\t\treturn false;
\treturn strstr(name, ".so") != NULL;
}
"""


def insert_helper(src: str) -> str:
    if "vma_is_memfd_lib(struct vm_area_struct" in src:
        # 已经存在：如果还是旧版（没有 current->mm 判断）就替换整段
        m = re.search(r"\nstatic inline bool vma_is_memfd_lib\(struct vm_area_struct \*vma\)\n\{.*?\n\}\n", src, re.S)
        if m and "current->mm" not in m.group(0):
            return src[: m.start()] + "\n" + HELPER + src[m.end():]
        return src
    m = re.search(r"\nstatic void\s*\n?show_map_vma\(", src)
    if not m:
        raise SystemExit("找不到 show_map_vma 定义")
    return src[: m.start()] + "\n" + HELPER + src[m.start():]


def insert_after(src: str, anchor_regex: str, guard: str, label: str) -> str:
    m = re.search(anchor_regex, src)
    if not m:
        print(f"[skip] 找不到 {label}")
        return src
    end = m.end()
    if MARK in src[end : end + 300]:
        print(f"[skip] {label} 已打补丁")
        return src
    return src[:end] + guard + src[end:]


def main() -> None:
    src = open(PATH, encoding="utf-8", errors="ignore").read()
    src = insert_helper(src)
    src = insert_after(
        src,
        r"show_map_vma\(struct seq_file \*m, struct vm_area_struct \*vma\)\s*\{",
        "\n\tif (vma_is_memfd_lib(vma))\n\t\treturn;\n",
        "show_map_vma",
    )
    src = insert_after(
        src,
        r"static int show_smap\(struct seq_file \*m, void \*v\)\s*\{.*?struct vm_area_struct \*vma = v;",
        "\n\tif (vma_is_memfd_lib(vma))\n\t\treturn 0;\n",
        "show_smap",
    )
    src = insert_after(
        src,
        r"static int show_numa_map\(struct seq_file \*m, void \*v\)\s*\{.*?struct vm_area_struct \*vma = v;",
        "\n\tif (vma_is_memfd_lib(vma))\n\t\treturn 0;\n",
        "show_numa_map",
    )
    open(PATH, "w", encoding="utf-8").write(src)
    print(f"[ok] patched {PATH}")


if __name__ == "__main__":
    main()
