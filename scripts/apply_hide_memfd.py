#!/usr/bin/env python3
"""
apply_hide_memfd.py (v3) — 隐藏 memfd 注入库的 proc 映射

v3 关键修正：
1) 只对"进程读自己的 maps"隐藏（current->mm == vma->vm_mm）——
   验牌器 App 外部读取照常可见，注入自检不受影响
2) 只隐藏 **tmpfs/shmem(memfd)** 上的 `lib*.so`，普通文件（APK 解压出来的
   host/lib*.so）保持可见——否则注入器读自己的 maps 找不到自己的库

用法：python3 apply_hide_memfd.py [fs/proc/task_mmu.c]
"""

import re
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "fs/proc/task_mmu.c"
MARK = "vma_is_memfd_lib"
TMPFS_MAGIC = "0x01021994"  # include/uapi/linux/magic.h

HELPER = f"""
static inline bool vma_is_memfd_lib(struct vm_area_struct *vma)
{{
\tstruct file *file;
\tconst char *name;

\t/* only when the process reads its own maps */
\tif (vma->vm_mm != current->mm)
\t\treturn false;

\tfile = vma->vm_file;
\tif (!file || !file->f_inode)
\t\treturn false;
\t/* TMPFS_MAGIC: memfd lives on shmem; real files stay visible */
\tif (file->f_inode->i_sb->s_magic != {TMPFS_MAGIC})
\t\treturn false;
\tname = file->f_path.dentry->d_name.name;
\tif (!name)
\t\treturn false;
\tif (strncmp(name, "lib", 3) != 0)
\t\treturn false;
\treturn strstr(name, ".so") != NULL;
}}
"""


def insert_helper(src: str) -> str:
    m = re.search(
        r"\nstatic inline bool vma_is_memfd_lib\(struct vm_area_struct \*vma\)\n\{.*?\n\}\n",
        src,
        re.S,
    )
    if m:
        return src[: m.start()] + "\n" + HELPER + src[m.end():]
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
