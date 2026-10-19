#!/usr/bin/env bash
# 应用 SUSFS 补丁及各内核版本所需的上下文修复
# 依赖环境变量：
#   ANDROID_VERSION KERNEL_VERSION KSU_VARIANT OS_PATCH_LEVEL SUB_LEVEL
#   KERNEL_ROOT SUSFS4KSU KERNEL_PATCHES LEGACY_SUKISU_CONFIG
# 调用前必须将工作目录设为 $KERNEL_ROOT
set -eo pipefail

# 列出当前目录下不属于上游的 .rej（相对路径，已排序）。
# 上游分支可能自带已提交的 .rej（如 android15-6.6-2026-04 的 mm/rmap.c.rej，
# 是上游解决合并冲突时的残留），那不是本补丁的冲突；但 patch 失败时会覆盖同名文件，
# 所以只有「被 git 跟踪且未改动」的才视为上游自带。
# 不在 git 仓库里（本地 verify_context.sh）时 git 命令为空，退回全部 .rej
list_upstream_rej() {
  git ls-files -- '*.rej' 2>/dev/null | while IFS= read -r f; do
    git diff --quiet -- "$f" 2>/dev/null && echo "$f"
  done
}
list_untracked_rej() {
  comm -23 \
    <(find . -type f -name '*.rej' | sed 's|^\./||' | sort) \
    <(list_upstream_rej | sort)
}

echo "应用 SUSFS 补丁..."

SUSFS_PATCH="50_add_susfs_in_gki-$ANDROID_VERSION-$KERNEL_VERSION.patch"
cp "$SUSFS4KSU/kernel_patches/$SUSFS_PATCH" ./common/
cp "$SUSFS4KSU"/kernel_patches/fs/* ./common/fs/
cp "$SUSFS4KSU"/kernel_patches/include/linux/* ./common/include/linux/

case "$KSU_VARIANT" in
  "Official")
    cd ./KernelSU
    cp "$SUSFS4KSU"/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch ./
    patch -p1 --forward < 10_enable_susfs_for_ksu.patch || true

    cd ..
    ;;
  "Next"|"SukiSU"|"SukiSU(40726)"|"SukiSU(40548)"|"BakaSU")
    echo "Next/SukiSU/SukiSU(40726)/SukiSU(40548)/BakaSU 使用内置 SUSFS 支持"
    ;;
esac

cd "$KERNEL_ROOT/common"
CURRENT_SUB="$SUB_LEVEL"
if [[ ! "$CURRENT_SUB" =~ ^[0-9]+$ ]]; then
  CURRENT_SUB=99999
fi

# 兼容缺少 VMA padding 接口的 5.10.66～209、5.15.74～144 和 6.1.25～68
if grep -qF 'VMA_PAD_START(vma)' "$SUSFS_PATCH" \
  && ! grep -Rqs 'VMA_PAD_START' ./include/linux; then
  echo "目标内核未提供 VMA_PAD_START，使用 vma->vm_end 兼容 SUSFS OPEN_REDIRECT"
  sed -i 's/VMA_PAD_START(vma)/vma->vm_end/g' "$SUSFS_PATCH"
fi

adjust_legacy_fdinfo_context() {
  sed -i '/^[[:space:]]*\/\*$/,/^[[:space:]]*u32 mask = mark->mask & IN_ALL_EVENTS;$/d' fs/notify/fdinfo.c
  perl -i -pe 's/\bmask,\s*mark->ignored_mask/inotify_mark_user_mask(mark)/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:%x/ignored_mask:0/g' fs/notify/fdinfo.c
}

restore_legacy_fdinfo_context() {
  perl -i -pe 's/^(\s+if \(inode\) \{)/$1\n\t\t\/\*\n\t\t * IN_ALL_EVENTS represents all of the mask bits\n\t\t * that we expose to userspace.  There is at\n\t\t * least one bit (FS_EVENT_ON_CHILD) which is\n\t\t * used only internally to the kernel.\n\t\t *\/\n\t\tu32 mask = mark->mask & IN_ALL_EVENTS;/m' fs/notify/fdinfo.c
  perl -i -pe 's/\binotify_mark_user_mask\(mark\)/mask, mark->ignored_mask/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:0/ignored_mask:%x/g' fs/notify/fdinfo.c
}

# 临时调整旧内核源码上下文，使 SUSFS 主补丁可以匹配
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "临时调整 Android 12 5.10 base.c 上下文"
    perl -i -pe 's/(int|size_t)\s+this_len\s*=\s*min_t\s*\(\s*\1\s*,/size_t this_len = min_t(size_t,/;' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "临时调整 Android 12 5.10 fdinfo.c 上下文"
    adjust_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "临时调整 Android 13 5.15 namespace.c/open.c/fdinfo.c 上下文"
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/namespace.c; then
      sed -i '/^#include <linux\/shmem_fs.h>$/a #include <linux/mnt_idmapping.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/open.c; then
      sed -i '/^#include <linux\/compat.h>$/a #include <linux/mnt_idmapping.h>' fs/open.c
    fi
    adjust_legacy_fdinfo_context
  fi
  if [[ "$OS_PATCH_LEVEL" == "lts" ]]; then
    echo "临时调整 Android 13 5.15 LTS 头文件上下文"
    sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
    sed -i '/^#include <trace\/hooks\/mm.h>$/d' fs/proc/task_mmu.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]] && ! grep -qF '#include <trace/hooks/sched.h>' fs/proc/base.c; then
    echo "临时调整 Android 14 6.1 sched.h 上下文"
    sed -i '/^#include <trace\/events\/oom.h>$/a #include <trace/hooks/sched.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "临时调整 Android 14 6.1 dma-buf.h 上下文"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -ge 157 ]]; then
    echo "临时调整 Android 14 6.1 namespace.c 上下文"
    sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "临时调整 Android 15 6.6 base.c 上下文"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]] && ! grep -qF '#include <linux/zswap.h>' mm/memory.c; then
    echo "临时调整 Android 15 6.6 memory.c 上下文"
    sed -i '/^#include <linux\/sched\/sysctl.h>$/a #include <linux/zswap.h>' mm/memory.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  if [[ "$CURRENT_SUB" -ge 58 ]]; then
    echo "临时调整 Android 16 6.12 exec.c 上下文"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/exec.c
  fi
fi

# 新版内核在 super.c 的 internal.h 之后新增了 trace/hooks/fs.h，
# 旧版 SUSFS 主补丁以 thaw_super_locked 为上下文插入 extern 声明，会整段被拒绝；
# 上游 2026-09-15 起已把声明挪到 unnamed_dev_ida 之后，不再依赖这段上下文，
# 但 ShirkNeko fork 尚未同步（固定提交的旧版补丁不改 super.c），只对旧版补丁做临时调整
SUPER_FS_H_REMOVED=""
if grep -q '^ static int thaw_super_locked' "$SUSFS_PATCH" \
  && grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "临时调整 super.c 上下文"
  sed -i '/^#include <trace\/hooks\/fs.h>$/,+1d' fs/super.c
  SUPER_FS_H_REMOVED=1
fi

patch -p1 < "$SUSFS_PATCH" || true

# 为尚未提供 SU 会话 FD 接口的 SukiSU/BakaSU 恢复旧版 exec hook 行为
EXEC_HELPER=""
if [[ "$KSU_VARIANT" == SukiSU* || "$KSU_VARIANT" == "BakaSU" ]]; then
  if grep -qF 'ksu_install_su_fd();' fs/exec.c; then
    EXEC_HELPER="ksu_install_su_fd"
  elif grep -qF 'ksu_handle_post_execveat_sucompat(' fs/exec.c; then
    EXEC_HELPER="ksu_handle_post_execveat_sucompat"
  fi
fi
if [[ -n "$EXEC_HELPER" ]] \
  && ! grep -RqsE --include='*.c' "^[[:space:]]*int[[:space:]]+${EXEC_HELPER}[[:space:]]*\(" "$KERNEL_ROOT/KernelSU/kernel"; then
  echo "$KSU_VARIANT 尚未提供 $EXEC_HELPER，恢复旧版 exec hook"
  sed -i '/^extern int ksu_install_su_fd(void);$/d' fs/exec.c
  sed -i '/^extern int ksu_handle_post_execveat_sucompat(/,+1d' fs/exec.c
  sed -i 's/is_su_session = !\(ksu_handle_execveat[^;]*;\)/\1/' fs/exec.c
  sed -i '/^[[:space:]]*bool is_su_session = false;$/d' fs/exec.c
  sed -i '/^[[:space:]]*if (unlikely(is_su_session && retval >= 0))$/,+1d' fs/exec.c
  sed -i '/^[[:space:]]*if (unlikely(is_su_session))$/,+1d' fs/exec.c
  sed -i '/^#ifdef CONFIG_KSU_SUSFS$/N;/^#ifdef CONFIG_KSU_SUSFS\n#endif \/\/ #ifdef CONFIG_KSU_SUSFS$/d' fs/exec.c
  if grep -qE 'ksu_install_su_fd|ksu_handle_post_execveat_sucompat|is_su_session' fs/exec.c; then
    echo "::error::$KSU_VARIANT exec hook 结构已变化，无法完成兼容修复"
    exit 1
  fi
fi

# 上游 5.10 补丁把 susfs_sus_kstat_spoof_vfs_statfs 的 extern 声明放在了
# susfs_statfs_by_dentry 之后，clang -Werror 会报隐式声明；声明晚于使用时前移
if [[ -f fs/statfs.c ]] && grep -qF 'susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c; then
  STATFS_USE=$(grep -n 'if (!susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c | head -1 | cut -d: -f1)
  STATFS_DECL=$(grep -n '^extern int susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c | head -1 | cut -d: -f1)
  if [[ -n "$STATFS_USE" && -n "$STATFS_DECL" && "$STATFS_DECL" -gt "$STATFS_USE" ]] \
    && grep -q '^static int susfs_statfs_by_dentry(' fs/statfs.c; then
    echo "前移 statfs.c 中 susfs_sus_kstat_spoof_vfs_statfs 的声明"
    sed -i '/^static int susfs_statfs_by_dentry(/i extern int susfs_sus_kstat_spoof_vfs_statfs(struct inode *inode, struct kstatfs *buf, bool *is_fuse);' fs/statfs.c
  fi
fi

# 在编译前报告 SUSFS 主补丁产生的冲突文件，上游自带的 .rej 不计入
mapfile -t SUSFS_REJ_FILES < <(list_untracked_rej)
SUSFS_REJ_COUNT=${#SUSFS_REJ_FILES[@]}
if [ "$SUSFS_REJ_COUNT" -gt 0 ]; then
  echo "::warning title=SUSFS 补丁冲突::SUSFS 主补丁产生了 ${SUSFS_REJ_COUNT} 个 .rej 冲突文件，可能导致后续编译失败（详见 Rejects 产物）"
  printf '%s\n' "${SUSFS_REJ_FILES[@]}"
fi

# 还原仅用于补丁匹配的临时源码调整
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "还原 Android 12 5.10 base.c 临时调整"
    sed -i 's/^size_t this_len = min_t(size_t, count, PAGE_SIZE);$/int this_len = min_t(int, count, PAGE_SIZE);/' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "还原 Android 12 5.10 fdinfo.c 临时调整"
    restore_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "还原 Android 13 5.15 临时调整"
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/namespace.c
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/open.c
    restore_legacy_fdinfo_context
    sed -i 's|i_uid_into_mnt(i_user_ns(&fi->inode), &fi->inode).val|i_uid_into_mnt(\&init_user_ns, \&fi->inode).val|g' fs/susfs.c
    sed -i 's|i_uid_into_mnt(i_user_ns(inode), inode).val|i_uid_into_mnt(\&init_user_ns, inode).val|g' fs/susfs.c
  fi
  if [[ "$OS_PATCH_LEVEL" == "lts" ]]; then
    echo "还原 Android 13 5.15 LTS 头文件上下文"
    if ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
      sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <trace/hooks/mm.h>' fs/proc/task_mmu.c; then
      sed -i '/^#include <linux\/pkeys.h>$/a #include <trace/hooks/mm.h>' fs/proc/task_mmu.c
    fi
  fi
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]]; then
    sed -i '/^#include <trace\/hooks\/sched.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]]; then
    echo "还原 Android 14 6.1 base.c 临时调整"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -ge 157 ]] && ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
    echo "还原 Android 14 6.1 namespace.c 临时调整"
    sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]]; then
    echo "还原 Android 15 6.6 base.c 临时调整"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]]; then
    echo "还原 Android 15 6.6 memory.c 临时调整"
    sed -i '/^#include <linux\/zswap.h>$/d' mm/memory.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  if [[ "$CURRENT_SUB" -ge 58 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/exec.c; then
    echo "还原 Android 16 6.12 exec.c 临时调整"
    sed -i '0,/^#include /s//#include <linux\/dma-buf.h>\n&/' fs/exec.c
  fi
fi

if [[ -n "$SUPER_FS_H_REMOVED" ]] \
  && ! grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "还原 super.c 临时调整"
  sed -i '/^#include "internal.h"$/a #include <trace/hooks/fs.h>' fs/super.c
fi

fix_missing_vm_flags_clear() {
  if [[ "$OS_PATCH_LEVEL" == "2024-11" ]] && grep -qF 'vm_flags_clear(new_vma, VM_PAD_MASK);' ./mm/mmap.c; then
    sed -i 's/vm_flags_clear(new_vma, VM_PAD_MASK);/new_vma->vm_flags \&= ~VM_PAD_MASK;/' ./mm/mmap.c
  fi
}

fix_task_mmu_show_pad() {
  local max_sub="$1"
  local excluded_patch_level="${2:-}"

  # 仅固定旧版 SUSFS 补丁会引入 goto show_pad，最新版已不再包含该代码
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le "$max_sub" ]] \
    && { [[ -z "$excluded_patch_level" ]] || [[ "$OS_PATCH_LEVEL" != "$excluded_patch_level" ]]; }; then
    sed -i -e 's/goto show_pad;/return 0;/' ./fs/proc/task_mmu.c
  fi
}

# Android 12 - 5.10 修复
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  # 修复 2024-11 分支: mmap.c 调用了 vm_flags_clear()，但同分支 mm.h 未提供 helper
  fix_missing_vm_flags_clear
  fix_task_mmu_show_pad 209
fi

# Android 13 - 5.15 修复
  if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  # 修复 2024-11 分支: mmap.c 调用了 vm_flags_clear()，但同分支 mm.h 未提供 helper
  fix_missing_vm_flags_clear
  fix_task_mmu_show_pad 148 "2024-05"
fi

# Android 14 - 6.1 修复
if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  fix_task_mmu_show_pad 75 "2024-05"
fi

# Android 15 - 6.6 修复
if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  # 修复老版 SukiSU 6.6.50~6.6.58: task_mmu.c 打入 SUSFS 后使用 vma，但旧源码没有对应声明
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -ge 50 && "$CURRENT_SUB" -le 58 ]] \
    && grep -qF 'vma = find_vma(mm, start_vaddr);' ./fs/proc/task_mmu.c; then
    TASK_MMU_PATCH="$KERNEL_PATCHES/wild/archived/susfs_fix_patches/v2.1.0/a15-6.6/task_mmu.c.patch"
    if [ ! -f "$TASK_MMU_PATCH" ]; then
      echo "::error::补丁不存在: $TASK_MMU_PATCH"
      exit 1
    fi
    cp "$TASK_MMU_PATCH" ./
    if patch -p1 --dry-run < task_mmu.c.patch >/dev/null 2>&1; then
      patch -p1 --no-backup-if-mismatch < task_mmu.c.patch
      echo "已应用 Android 15 6.6.50~6.6.58 task_mmu.c 归档修复补丁"
    else
      echo "Android 15 6.6.50~6.6.58 task_mmu.c 归档修复补丁已应用或当前上下文不匹配，跳过"
    fi
  fi
fi

# Android 16 - 6.12 修复
if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  # 固定旧版 SukiSU 在 6.12 上会重复定义 setresuid hook
  SETUID_HOOK="$KERNEL_ROOT/common/drivers/kernelsu/setuid_hook.c"
  if [[ -n "$LEGACY_SUKISU_CONFIG" && -f "$SETUID_HOOK" ]] \
    && grep -qF 'defined(CONFIG_KSU_MANUAL_HOOK))' "$SETUID_HOOK"; then
    sed -i 's/defined(CONFIG_KSU_MANUAL_HOOK))/!defined(CONFIG_KSU_SUSFS) \&\& defined(CONFIG_KSU_MANUAL_HOOK))/' "$SETUID_HOOK"
    echo "已修复 setuid_hook.c 重复定义问题"
  fi
fi

# ==== JCC: hide memfd library mappings from proc maps (display-only) ====
if [ -f "$GITHUB_WORKSPACE/scripts/apply_hide_memfd.py" ] && [ -n "$KERNEL_ROOT" ] && [ -f "$KERNEL_ROOT/common/fs/proc/task_mmu.c" ]; then
    python3 "$GITHUB_WORKSPACE/scripts/apply_hide_memfd.py" "$KERNEL_ROOT/common/fs/proc/task_mmu.c" || true
fi
# ===== M0: ACE 观测层（只记录，不阻断）=====
if [ "${ACE_OBS:-1}" = "1" ] && [ -d "${KERNEL_ROOT:-.}/common/kernel" ] && ! grep -q 'ace_obs.o' "${KERNEL_ROOT:-.}/common/kernel/Makefile" 2>/dev/null; then
ACEDIR="${KERNEL_ROOT:-.}/common"
cat > "$ACEDIR/kernel/ace_obs.c" <<'ACEEOF'
// ace_obs: 观测 libtersafe 发起的 clone（M0，只记录不拦）
#include <linux/kprobes.h>
#include <linux/sched.h>
#include <linux/mm.h>
#include <linux/fs.h>
#include <linux/ptrace.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/atomic.h>

static struct kprobe kp_clone;
static struct kprobe kp_clone3;
static atomic64_t obs_cnt = ATOMIC64_INIT(0);

static bool is_game_task(void)
{
	return strncmp(current->comm, "tencent.jkchess", 15) == 0;
}

static bool user_pc_in_libtersafe(unsigned long *out_pc)
{
	struct pt_regs *uregs = task_pt_regs(current);
	struct vm_area_struct *vma;
	const char *name;
	unsigned long pc;

	if (!current->mm || !uregs)
		return false;
	pc = uregs->pc;
	vma = find_vma(current->mm, pc);
	if (!vma || !vma->vm_file)
		return false;
	name = vma->vm_file->f_path.dentry->d_name.name;
	if (!name)
		return false;
	if (strncmp(name, "libtersafe", 10) != 0)
		return false;
	*out_pc = pc;
	return true;
}

static int pre_clone(struct kprobe *p, struct pt_regs *regs)
{
	unsigned long pc = 0;

	if (!is_game_task())
		return 0;
	if (!user_pc_in_libtersafe(&pc))
		return 0;

	atomic64_inc(&obs_cnt);
	pr_info("ace_obs: clone pc=%lx comm=%s n=%lld\n",
		pc, current->comm, (long long)atomic64_read(&obs_cnt));
	return 0;	/* 只观测，不阻断 */
}

static int __init ace_obs_init(void)
{
	int r;

	kp_clone.symbol_name = "__arm64_sys_clone";
	kp_clone.pre_handler = pre_clone;
	r = register_kprobe(&kp_clone);
	pr_info("ace_obs: clone kprobe %d\n", r);

	kp_clone3.symbol_name = "__arm64_sys_clone3";
	kp_clone3.pre_handler = pre_clone;
	r = register_kprobe(&kp_clone3);
	pr_info("ace_obs: clone3 kprobe %d\n", r);
	return 0;
}
device_initcall(ace_obs_init);
ACEEOF
printf '\nobj-y += ace_obs.o\n' >> "$ACEDIR/kernel/Makefile"
echo "ace_obs: injected into $ACEDIR"
fi

# ===== kcheat: 内核侧内存读写驱动 =====
if [ "${KCHEAT:-1}" = "1" ] && [ -d "${KERNEL_ROOT:-.}/common/kernel" ] && ! grep -q 'kcheat.o' "${KERNEL_ROOT:-.}/common/kernel/Makefile" 2>/dev/null; then
KDIR="${KERNEL_ROOT:-.}/common"
cat > "$KDIR/kernel/kcheat.c" <<'KCHEATEOF'
// kcheat: 内核侧外挂基础驱动（GKI 内核内建）
// 提供 /proc/kcheat：
//   echo "p <pid>"        > /proc/kcheat   设定目标进程
//   echo "r <addr> <len>" > /proc/kcheat   读目标内存
//   echo "w <addr> <hex>" > /proc/kcheat   写目标内存
//   cat /proc/kcheat                       取最近一次读的 hex 结果
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/sched.h>
#include <linux/sched/task.h>
#include <linux/mm.h>
#include <linux/string.h>
#include <linux/init.h>

static struct proc_dir_entry *kcheat_entry;
static struct task_struct *kcheat_target;
static char kcheat_out[8192];
static int kcheat_outlen;

static long kcheat_parse_ul(const char **ps, int base)
{
	long v = 0;
	const char *s = *ps;

	while (*s == ' ')
		s++;
	if (base == 16 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
		s += 2;
	while (*s) {
		int d;
		if (*s >= '0' && *s <= '9')
			d = *s - '0';
		else if (base == 16 && *s >= 'a' && *s <= 'f')
			d = *s - 'a' + 10;
		else if (base == 16 && *s >= 'A' && *s <= 'F')
			d = *s - 'A' + 10;
		else
			break;
		v = v * base + d;
		s++;
	}
	*ps = s;
	return v;
}

static void kcheat_hex(const unsigned char *b, int n)
{
	static const char hx[] = "0123456789abcdef";
	int i;

	kcheat_outlen = 0;
	for (i = 0; i < n && kcheat_outlen < (int)sizeof(kcheat_out) - 2; i++) {
		kcheat_out[kcheat_outlen++] = hx[(b[i] >> 4) & 0xf];
		kcheat_out[kcheat_outlen++] = hx[b[i] & 0xf];
	}
	kcheat_out[kcheat_outlen++] = '\n';
	kcheat_out[kcheat_outlen] = 0;
}

static ssize_t kcheat_write(struct file *file, const char __user *ubuf,
			    size_t len, loff_t *off)
{
	char cmd[512];
	int n = (int)min(len, sizeof(cmd) - 1);
	const char *p = cmd;

	if (copy_from_user(cmd, ubuf, n))
		return -EFAULT;
	cmd[n] = 0;
	while (*p == ' ') p++;

	if (p[0] == 'p') {
		p++;
		if (!kcheat_target) {
			pid_t pid = (pid_t)kcheat_parse_ul(&p, 10);
			kcheat_target = find_get_task_by_vpid(pid);
			if (kcheat_target)
				pr_info("kcheat: target pid=%d task=%px\n", pid, kcheat_target);
			else
				pr_info("kcheat: pid %d not found\n", pid);
		}
		return len;
	}

	if (p[0] == 'r') {
		unsigned long addr, l;
		unsigned char buf[2048];
		int got;

		p++;
		addr = kcheat_parse_ul(&p, 16);
		l = kcheat_parse_ul(&p, 10);
		if (l == 0 || l > sizeof(buf))
			l = 64;
		if (!kcheat_target)
			return -ENOENT;
		got = access_process_vm(kcheat_target, addr, buf, (int)l, 0);
		if (got < 0)
			return got;
		kcheat_hex(buf, got);
		return len;
	}

	if (p[0] == 'w') {
		unsigned long addr;
		unsigned char buf[256];
		int k = 0, hi = -1;

		p++;
		addr = kcheat_parse_ul(&p, 16);
		while (*p && k < (int)sizeof(buf)) {
			int d;
			char c = *p++;
			if (c >= '0' && c <= '9') d = c - '0';
			else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
			else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
			else continue;
			if (hi < 0) hi = d;
			else { buf[k++] = (unsigned char)((hi << 4) | d); hi = -1; }
		}
		if (!kcheat_target || k == 0)
			return len;
		access_process_vm(kcheat_target, addr, buf, k, FOLL_WRITE);
		return len;
	}

	return -EINVAL;
}

static ssize_t kcheat_read(struct file *file, char __user *ubuf,
			   size_t len, loff_t *off)
{
	if (*off >= kcheat_outlen)
		return 0;
	if (copy_to_user(ubuf, kcheat_out + *off, kcheat_outlen - *off))
		return -EFAULT;
	*off = kcheat_outlen;
	return 0;
}

static const struct proc_ops kcheat_ops = {
	.proc_write = kcheat_write,
	.proc_read = kcheat_read,
};

static int __init kcheat_init(void)
{
	kcheat_entry = proc_create("kcheat", 0666, NULL, &kcheat_ops);
	pr_info("kcheat: init entry=%px\n", kcheat_entry);
	return 0;
}

static void __exit kcheat_exit(void)
{
	if (kcheat_entry)
		proc_remove(kcheat_entry);
	pr_info("kcheat: exit\n");
}

module_init(kcheat_init);
module_exit(kcheat_exit);
MODULE_LICENSE("GPL");

KCHEATEOF
printf '\nobj-y += kcheat.o\n' >> "$KDIR/kernel/Makefile"
echo "kcheat: injected into $KDIR"
fi
