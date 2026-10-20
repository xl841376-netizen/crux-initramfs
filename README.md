# crux-initramfs

Xiaomi Mi 9 Pro 5G（crux / SM8150）跑 Linux mainline 用的 initramfs：在 `switch_root` 之前定位根分区并做分区检查/修复。

内核 `Image`、设备树 `.dtb`、根文件系统都不在本仓库。本仓库产出 `initramfs.cpio.gz`（约 2.4 MB），放 ESP `EFI/crux/` 下由 grub 加载：

```ini
linux   ($root)/EFI/crux/Image75 rw ... root=UUID=xxxxxxxx-...
initrd  ($root)/EFI/crux/initramfs.cpio.gz
```

## 1. 根分区定位顺序

| 顺位 | 来源 | 行为 |
|---|---|---|
| 1 | cmdline `root=UUID=` / `PARTUUID=` / `LABEL=` / `PARTLABEL=` / `/dev/sdX` | 优先使用；解析到就直接用，解析失败才往下 |
| 2 | cmdline 无 `root=` 或 `root=auto` | `crux.auto=1`（默认）时按 PARTLABEL 探测：`linux-root26` → `linux-root` → `linux-root-next` |
| 3 | 上面都没结果 | 扫描 ext4 块设备逐个试探 |
| 4 | 全部失败 | 进 rescue shell（busybox sh），候选列表打到控制台 |

每个候选先过 `probe_root`：只读挂载后需同时存在 `/etc/os-release` 与可执行 `/sbin/init`，用于排除 Android 分区等非目标根。

cmdline `root=` 优先于自动探测；早期版本按 `uname -r` 硬映射到 `LABEL=linux-root26`，在同时存在 `linux-root26` 与 `linux-root` 的机器上会选错根并覆盖 grub 传入的 `root=`。

## 2. 分区检查 / 修复

| 动作 | 触发 | 结果 |
|---|---|---|
| `e2fsck -p` | 每个候选挂载前 | 失败则 `e2fsck -fy` 重试一次 |
| 挂载重试 | `mount` 返回非 0 | 修复后重挂，仍失败换下一候选 |
| 模块版本匹配 | 挂载成功后 | 检查 `/lib/modules/$KVER`（或 `/usr/lib/modules/$KVER`），不存在则告警 |
| fstab 一致性 | 挂载成功后 | 比对 `/etc/fstab` 根条目（`PARTLABEL=` / `UUID=`）与实际设备，不一致告警 |
| 可写性 | 挂载成功后 | 写 `.crux_rwtest`；失败则 `remount,rw` 重试，结果写入报告 |
| 剩余空间 | 挂载成功后 | < 512 MiB 告警 |
| 上次关机状态 | 挂载成功后 | `/var/lib/crux/shutdown-clean` 存在为 `clean`，否则 `dirty`，随后由 systemd 侧重建 |

报告落盘 `/var/lib/crux/boottrace.txt`，格式：

```
=== crux boottrace ===
time      : Tue Oct 20 13:01:22 CST 2026
kver      : 7.3.0-rc5-crux73
cmdline   : ... root=UUID=a9c4c05b-... ...
rootspec  : UUID=a9c4c05b-...
cands     : /dev/sda36 /dev/sda37
rootdev   : /dev/sda36 (PARTLABEL=linux-root UUID=a9c4c05b-...)
fsck      : /dev/sda36
rw        : 1
modules   : yes (/lib/modules/7.3.0-rc5-crux73)
fstab_root: PARTLABEL=linux-root -> match=yes
free      : 61234MiB
shutdown  : dirty
```

后台运行 earlylog：把 `/dev/kmsg` 持续写到 `/var/log/crux-early.log`，不依赖 systemd。

## 3. cmdline 选项

| 选项 | 作用 |
|---|---|
| `root=UUID=...` 等 | 指定根分区（sda36/sda37 共存时须指定） |
| `root=auto` 或不写 | 自动探测（上表第 2、3 顺位） |
| `crux.auto=0` | 关闭自动探测：只认 `root=`，找不到进 rescue |
| `crux.auto=1` | 允许自动探测（默认） |

## 4. 构建

以「基础 initramfs」为底（提供 busybox + `e2fsck` 等工具），只替换 `init`：

```bash
# 取基础包（Release: initramfs-base）
gh release download initramfs-base --repo xl841376-netizen/crux-initramfs -D base

./build.sh --base base/initramfs-base.cpio.gz --out out
#   out/crux-initramfs-YYYYMMDD-rN.cpio.gz
#   out/SHA256SUMS
```

`build.sh` 的校验（任一失败即退出）：

1. 基础包 applet 是否齐全（`findfs blkid awk sed df head timeout setsid mount umount switch_root sleep date sync sh ...` + `/sbin/e2fsck`）
2. `init` 语法（`busybox sh -n`，无 busybox 时 `dash -n`）
3. 产物条目数与 sha256

## 5. 部署

```bash
mount /dev/sda35 /mnt/efi
cp out/crux-initramfs-*.cpio.gz /mnt/efi/EFI/crux/initramfs.cpio.gz
sync && umount /mnt/efi
```

grub 的 `initrd` 行指向该文件；多个菜单项可共用同一份。

## 6. 故障排查

| 现象 | 查看 |
|---|---|
| 卡在黑屏 / 未到 systemd | 串口，或根挂上后 `cat /var/lib/crux/boottrace.txt`；早期日志 `crux-early.log` |
| 进 rescue shell（`/ #`） | 候选全失败，控制台打印候选列表；手动 `mount /dev/sdaXX /newroot` 试探 |
| 启动了另一个系统 | 检查 grub 的 `root=`；`root=` 优先于自动探测 |
| 模块加载失败 | boottrace 里 `modules: NO` → 内核与 rootfs 的 `/lib/modules/<kver>` 版本串不一致 |

## 7. 限制

- 依赖「基础 initramfs」提供工具集，不从头编 busybox；可切换为 `busybox-static` + `e2fsprogs` 自建
- 只处理 ext4
- 无 dm-crypt 加密根分支

## 8. 相关仓库

| 仓库 | 内容 |
|---|---|
| `crux-minimal-rootfs` | 根文件系统 tar（含固件、内核模块、overlay） |
| `linux`（`crux-sm8150-73` 分支） | 内核 `Image` + `.dtb` + 内核模块 |
| 本仓库 | `initramfs.cpio.gz`：根分区定位 + 分区检查/修复 |