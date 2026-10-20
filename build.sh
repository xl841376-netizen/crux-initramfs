#!/bin/bash
# ============================================================
#  crux initramfs 构建
#
#  做法：以一份「基础 initramfs」为底（提供 busybox + e2fsck 等工具集），
#        只替换里面的 init 脚本，再重新打包。
#        这样不需要在 CI 里交叉编译 busybox，产物和工具集完全可控。
#
#  用法:
#    ./build.sh --base <基础 initramfs.cpio.gz> [--init <脚本>] [--out <目录>]
#
#  基础 initramfs 获取:
#    gh release download initramfs-base --repo <owner>/crux-initramfs -D base
#    （或从设备上取 /mnt/efi/EFI/crux/initramfs.cpio.gz）
# ============================================================
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
INIT="$HERE/init"
BASE=""
OUT="$HERE/out"

usage() { sed -n '2,18p' "$0"; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE=$2; shift 2 ;;
        --init) INIT=$2; shift 2 ;;
        --out)  OUT=$2;  shift 2 ;;
        -h|--help) usage ;;
        *) echo "未知参数: $1"; usage ;;
    esac
done

[ -n "$BASE" ] || { echo "!! 必须给 --base <基础 initramfs.cpio.gz>"; exit 1; }
[ -f "$BASE" ] || { echo "!! 基础文件不存在: $BASE"; exit 1; }
[ -f "$INIT" ] || { echo "!! init 脚本不存在: $INIT"; exit 1; }

command -v cpio >/dev/null || { echo "!! 需要 cpio（apt install cpio）"; exit 1; }
command -v gzip >/dev/null || { echo "!! 需要 gzip"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "== [1/5] 解开基础 initramfs"
gzip -dc "$BASE" | ( cd "$WORK" && cpio -idm --quiet )

echo "== [2/5] 校验基础工具集（init 脚本依赖这些 applet）"
MISSING=""
for a in findfs blkid awk sed df head timeout setsid mount umount switch_root \
         sleep date sync sh cat echo mkdir rm touch printf; do
    if [ ! -e "$WORK/bin/$a" ] && [ ! -e "$WORK/sbin/$a" ]; then
        MISSING="$MISSING $a"
    fi
done
[ -x "$WORK/sbin/e2fsck" ] || MISSING="$MISSING e2fsck(/sbin)"
if [ -n "$MISSING" ]; then
    echo "!! 基础 initramfs 缺少:$MISSING"
    exit 1
fi
echo "   applet 齐全"

echo "== [3/5] 替换 init"
cp -f "$WORK/init" "$WORK/init.orig" 2>/dev/null || true
install -m 0755 "$INIT" "$WORK/init"

echo "== [4/5] 语法自检"
if command -v busybox >/dev/null; then
    busybox sh -n "$WORK/init" && echo "   busybox sh -n: OK"
elif command -v dash >/dev/null; then
    dash -n "$WORK/init" && echo "   dash -n: OK（近似检查）"
else
    echo "   跳过（无 busybox/dash）"
fi
if grep -q '^#!' "$WORK/init"; then
    head -1 "$WORK/init" | grep -q 'busybox sh' || echo "   注意: init 首行不是 #!/bin/busybox sh"
fi

echo "== [5/5] 打包"
mkdir -p "$OUT"
NAME="crux-initramfs-$(date +%Y%m%d)-r$(git -C "$HERE" rev-list --count HEAD 2>/dev/null || echo 0).cpio.gz"
( cd "$WORK" && find . | cpio -o -H newc --quiet ) | gzip -9 > "$OUT/$NAME"
( cd "$OUT" && sha256sum "$NAME" > SHA256SUMS )
echo "== 完成: $OUT/$NAME  $(du -h "$OUT/$NAME" | cut -f1)"
echo "   条目数: $(gzip -dc "$OUT/$NAME" | cpio -t 2>/dev/null | wc -l)"
echo
echo "部署（设备上）:"
echo "  mount /dev/sda35 /mnt/efi"
echo "  cp $OUT/$NAME /mnt/efi/EFI/crux/initramfs.cpio.gz"
echo "  sync && umount /mnt/efi"