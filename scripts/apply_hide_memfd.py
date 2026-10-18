#!/usr/bin/env python3
"""
apply_hide_memfd.py — 在 GKI 内核源码里隐藏 memfd 加载库的 proc 映射

用法（内核源码根目录）：
    python3 apply_hide_memfd.py [fs/proc/task_mmu.c]

改动：
- 在 show_map_vma() 开头加早退
- 在 show_smap() / show_numa_map() 里，等 `struct vm_area_struct *vma = v;`
  之后再插入早退（这两个函数参数是 void *v，不能提前引用 vma）
幂等：已打过补丁会跳过。
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
    m = re.search(r"\nstatic void\s*\n?show_map_vma\(", src)
    if not m:
        raise SystemExit("找不到 show_map_vma 定义")
    return src[: m.start()] + "\n" + HELPER + src[m.start():]


def insert_after(src: str, anchor_regex: str, guard: str, label: str) -> str:
    """在匹配 anchor_regex 的位置之后插入 guard（幂等）"""
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

    # show_map_vma: 参数就是 vma，函数体开头直接判断
    src = insert_after(
        src,
        r"show_map_vma\(struct seq_file \*m, struct vm_area_struct \*vma\)\s*\{",
        "\n\tif (vma_is_memfd_lib(vma))\n\t\treturn;\n",
        "show_map_vma",
    )
    # show_smap: 参数 void *v，必须在 vma 局部变量声明之后
    src = insert_after(
        src,
        r"static int show_smap\(struct seq_file \*m, void \*v\)\s*\{.*?struct vm_area_struct \*vma = v;",
        "\n\tif (vma_is_memfd_lib(vma))\n\t\treturn 0;\n",
        "show_smap",
    )
    # show_numa_map: 同样在 vma 声明之后
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
