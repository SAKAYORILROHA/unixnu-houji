#!/bin/bash
# Apply the XNU tree fixes that make the houji kernel build on a non-Apple host
# (no Apple PPL/TXM hardware, open source drop lacks the closed PPL half).
#
# Run after:  ./unixnu defconfig houji_defconfig -D <device> && ./unixnu fetch -D <device> && ./unixnu tree -D <device>
# Usage:      scripts/apply-tree-xnu-fixes.sh <device-repo-path>
#
# Idempotent: safe to re-run.
set -uo pipefail

DEV="${1:-}"
if [ -z "$DEV" ] || [ ! -f "$DEV/board.toml" ]; then
  echo "usage: $0 <path-to-device-repo>" >&2
  exit 2
fi
DEV=$(cd "$DEV" && pwd)
# run from the UniXNU checkout (the script may live in the device repository)
TREE="${UNIXNU_TREE:-$PWD/out/houji/tree}"
if [ ! -d "$TREE/.cache/xnu-work" ] && [ -d "$DEV/../out/houji/tree/.cache/xnu-work" ]; then
  TREE="$(cd "$DEV/../out/houji/tree" && pwd)"
fi
X="$TREE/.cache/xnu-work"
[ -d "$X" ] || { echo "no XNU work tree at $X; run ./unixnu tree -D $DEV from the UniXNU checkout, or set UNIXNU_TREE" >&2; exit 1; }

echo "== 1. machine master: enable the arm64 asm and arm pmap implementations =="
M="$X/config/MASTER.arm64.bcm2837"
python3 - "$M" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1]); t = p.read_text()
if 'options   NOS_ARM_ASM' not in t:
    t += 'options   NOS_ARM_ASM\t\t# [unixnu-port] include the arm64 assembly implementations\n'
if 'options   NOS_ARM_PMAP' not in t:
    t += 'options   NOS_ARM_PMAP\t\t# [unixnu-port] include the arm pmap implementation\n'
p.write_text(t)
print('   ', [l for l in t.splitlines() if 'NOS_ARM' in l])
PY

echo "== 2. Apple-closed units: AMCC rorgn, PPL SART/UAT headers, CPU tunables =="
mkdir -p "$X/osfmk/arm64/ppl" "$X/osfmk/arm64/tunables"
write_amcc() {
  cat > "$X/osfmk/arm64/$1.c" <<EOF
/* [unixnu-port] Apple ships $1 only inside the closed per-SoC library.
 * Nothing on this port uses KTRR/CTRR text lockdown, so the unit is empty. */
#include <stdint.h>
static const uint8_t unixnu_port_unused_$1 __attribute__((unused)) = 0;
EOF
}
for f in amcc_rorgn_common amcc_rorgn_ppl amcc_rorgn_ppl_amcc amcc_rorgn_ppl_ctrr3; do
  write_amcc "$f"
done
cat > "$X/osfmk/arm64/ppl/sart.h" <<'EOF'
/* [unixnu-port] Apple's SART (IOMMU for ANS/NVMe) is not in the open source drop
 * and does not exist on Qualcomm hardware; bootstrap is a no-op. */
#ifndef _ARM64_PPL_SART_H_
#define _ARM64_PPL_SART_H_
static inline void sart_bootstrap(void) { }
#endif
EOF
cat > "$X/osfmk/arm64/ppl/uat.h" <<'EOF'
/* [unixnu-port] Apple's UAT (user address translation) helpers are closed and
 * unused on this port; keep the include resolvable. */
#ifndef _ARM64_PPL_UAT_H_
#define _ARM64_PPL_UAT_H_
#endif
EOF
cat > "$X/osfmk/arm64/tunables/tunables.s" <<'EOF'
/* [unixnu-port] Apple's per-SoC CPU tunables (HID/ACC register settings applied by
 * start.s) are closed source and do not exist on Cortex-A76/A55. */
.macro APPLY_TUNABLES midr, tmp1, tmp2
.endmacro
EOF
echo "    stubs written"

echo "== 3. PPL monitor helpers used by osfmk/arm/pmap/pmap.c =="
cat > "$X/osfmk/arm/pmap/pmap_ppl_apple_stub.c" <<'EOF'
/*
 * [unixnu-port] Apple keeps the PPL "monitor" half of the arm pmap inside its
 * closed library. Nothing on a Qualcomm SoC implements or needs it, so these are
 * no-ops. Declarations are spelled out here on purpose: osfmk/arm/pmap/pmap.h
 * redirects some of these names through macros.
 */
#include <mach/boolean.h>
#include <mach/vm_types.h>
#include <stdbool.h>
#include <stddef.h>

extern void CleanPoC_DcacheRegion_Force(vm_offset_t va, size_t length);

void pmap_ppl_lockdown_pages(vm_address_t kva, vm_size_t size, unsigned int flags, bool ppl_writable)
{ (void)kva; (void)size; (void)flags; (void)ppl_writable; }

void pmap_ppl_unlockdown_pages(vm_address_t kva, vm_size_t size, unsigned int flags, bool ppl_writable)
{ (void)kva; (void)size; (void)flags; (void)ppl_writable; }

void *ptep_get_iommu(void *pte)
{ (void)pte; return (void *)0; }

bool pmap_pending_preemption(void)
{ return false; }

bool _pmap_pending_preemption_real(void)
{ return false; }

void ml_enable_monitor(void)
{ }

void CleanPoC_DcacheRegion_Force_nopreempt_nohid(vm_offset_t va, size_t length)
{ CleanPoC_DcacheRegion_Force(va, length); }
EOF
python3 - <<'PY'
from pathlib import Path
x = Path('/root/unixnu/UniXNU/out/houji/tree/.cache/xnu-work')
files = x / 'osfmk/conf/files.arm64'
t = files.read_text()
if 'pmap_ppl_apple_stub.c' not in t:
    lines = t.splitlines()
    for i, line in enumerate(lines):
        if line.startswith('osfmk/arm/pmap/pmap_ppl_interface.c'):
            lines.insert(i + 1, 'osfmk/arm/pmap/pmap_ppl_apple_stub.c\toptional nos_arm_pmap')
            break
    files.write_text('\n'.join(lines) + '\n')
    print('    registered in files.arm64')
c = x / 'osfmk/arm/pmap/pmap.c'
src = c.read_text()
anchor = '#include <arm/pmap/pmap_internal.h>'
if 'unixnu-port forward declaration' not in src and anchor in src:
    src = src.replace(anchor, anchor + '\n\n/* [unixnu-port] forward declaration for the static definition further down */\nstatic void pmap_phys_write_disable(vm_address_t va);\n', 1)
    c.write_text(src)
    print('    pmap.c forward declaration added')
PY

echo "== 4. IORPCMessageFromMach for prelinked iOS 16 storage components =="
if ! grep -q 'IORPCMessageFromMach' "$X/iokit/Kernel/IOLib.cpp" 2>/dev/null; then
  ( cd "$X" && patch -p1 < "$DEV/patches/xnu-iorpc-message-from-mach.patch" >/dev/null ) && echo "    patch applied"
else
  echo "    already present"
fi

echo "== 5. prelink: 20H392 Libm literal pool + tool path =="
python3 - "$DEV" <<'PY'
import sys
from pathlib import Path
dev = Path(sys.argv[1])
tool = Path('/root/unixnu/UniXNU/kits/XnuPrelink/emit_prelink.py')
if tool.is_file():
    t = tool.read_text()
    entry = ("    # iPhone X iOS 16.7.16 (20H392): math literal table, ends before the next function.\n"
             "    ('0000807f0000004100008040db0f493f', 1228, '73df5b757c53532583e3686b7d93df11ec1f5dd8c201d05502654a7812cc385f'),\n")
    if '73df5b757c53532583e3686b7d93df11' not in t:
        anchor = 'MATH_LITERAL_POOLS = (\n'
        if anchor in t:
            tool.write_text(t.replace(anchor, anchor + entry, 1))
            print('    literal pool added')
    else:
        print('    literal pool already present')
b = dev / 'board.toml'
t = b.read_text()
if 'kits/NativePrelink/emit_prelink.py' in t:
    b.write_text(t.replace('kits/NativePrelink/emit_prelink.py', 'kits/XnuPrelink/emit_prelink.py'))
    print('    board.toml prelink tool path fixed')
PY

echo "== done =="
echo "next: ./unixnu build kernel -D $DEV   (the first pass fails at the bootstrap link; rerun if the archives complain about link.filelist)"
