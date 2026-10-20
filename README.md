# crux-initramfs

Xiaomi Mi 9 Pro 5G（crux / SM8150）跑 Linux mainline 用的 **initramfs**：
负责在 `switch_root` 之前 **找到正确的根分区**，并顺手做一轮 **分区体检/修复**。

内核 `Image`、设备树 `.dtb`、根文件系统都不在本仓库；本仓库只产出一个
`initramfs.cpio.gz`（约 2.4 MB），放在 ESP 的 `EFI/crux/` 下由 grub 加载：

```ini
linux   ($root)/EFI/crux/Image75 rw ... root=UUID=xxxxxxxx-...
initrd  ($root)/EFI/crux/initramfs.cpio.gz
```

---

## 1. 根分区怎么定：优先级

| 顺位 | 来源 | 说明 |
|---|---|---|
| 1 | cmdline `root=UUID=` / `PARTUUID=` / `LABEL=` / `PARTLABEL=` / `/dev/sdX` | **最高权威**，解析到就直接用；解析失败才往下走 |
| 2 | cmdline 无 `root=` 或 `root=auto` | `crux.auto=1`（默认）时按 PARTLABEL 惯例探测：`linux-root26` → `linux-root` → `linux-root-next` |
| 3 | 上面都没结果 | 扫描所有 ext4 块设备逐个试探 |
| 4 | 全部失败 | 进 rescue shell（busybox sh），并把候选列表打到控制台 |

每个候选都要先过 **`probe_root`** 检查才算"像 crux 根"：只读挂载后必须同时存在
`/etc/os-release` 与可执行的 `/sbin/init`。这能挡住"扫到 Android 分区"这类误选。

> 历史坑：早期版本按 `uname -r` 硬映射（`7.3* → LABEL=linux-root26`）。当机器上同时有
> `linux-root26`（旧根）和 `linux-root`（新根）时，它会找到另一个系统的根、并把 grub 传的
> `root=UUID=` 覆盖掉。**现在 cmdline `root=` 永远优先**。

## 2. 分区体检 / 修复

| 动作 | 触发 | 结果记录 |
|---|---|---|
| `e2fsck -p` | 每个候选挂载前 | 失败则自动 `e2fsck -fy` 再试一次 |
| 挂载失败重试 | `mount` 返回非 0 | 修完再挂，仍失败就换下一个候选 |
| 模块版本匹配 | 挂载成功后 | 检查 `/lib/modules/$KVER`（或 `/usr/lib/modules/$KVER`）是否存在，不匹配就告警——**内核与 rootfs 版本串不一致会在这里暴露** |
| fstab 一致性 | 挂载成功后 | 比对 `/etc/fstab` 的根条目（`PARTLABEL=` / `UUID=`）与实际设备，不一致告警 |
| 可写性 | 挂载成功后 | 写 `.crux_rwtest`；失败则 `remount,rw` 重试，结果写进报告 |
| 剩余空间 | 挂载成功后 | < 512 MiB 告警 |
| 上次关机状态 | 挂载成功后 | 看 `/var/lib/crux/shutdown-clean` 是否存在 → `clean` / `dirty`，随后由 systemd 侧重新创建 |

报告落盘：**`/var/lib/crux/boottrace.txt`**（宿主机可 `cat` 查看），形如：

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

另外后台常驻一个 **earlylog**：把 `/dev/kmsg` 持续写到
`/var/log/crux-early.log`，不依赖 systemd，hang 住时也能看到开机早期日志。

## 3. cmdline 选项

| 选项 | 作用 |
|---|---|
| `root=UUID=...` 等 | 指定根分区（推荐；sda36/sda37 共存时必须给） |
| `root=auto` 或不写 | 自动探测（见上表第 2、3 顺位） |
| `crux.auto=0` | 禁止自动探测：只认 `root=`，找不到就进 rescue |
| `crux.auto=1` | 允许自动探测（默认） |

## 4. 构建

以一份「基础 initramfs」为底（提供 busybox + `e2fsck` 等工具集），只替换 `init`：

```bash
# 取基础包（本仓库 Release: initramfs-base）
gh release download initramfs-base --repo xl841376-netizen/crux-initramfs -D base

# 构建
./build.sh --base base/initramfs-base.cpio.gz --out out

# 产物
#   out/crux-initramfs-YYYYMMDD-rN.cpio.gz
#   out/SHA256SUMS
```

`build.sh` 会做三件校验，任一失败就退出：

1. 基础包里的 applet 是否齐全（`findfs blkid awk sed df head timeout setsid mount
   umount switch_root sleep date sync sh ...` + `/sbin/e2fsck`）
2. `init` 的语法（`busybox sh -n`，没有 busybox 时退回 `dash -n`）
3. 产物条目数与 sha256

## 5. 部署

```bash
# 设备上
mount /dev/sda35 /mnt/efi
cp out/crux-initramfs-*.cpio.gz /mnt/efi/EFI/crux/initramfs.cpio.gz
sync && umount /mnt/efi
```

grub 里 `initrd` 行指向这个文件即可（多个菜单项可以共用同一份）。

## 6. 故障排查

| 现象 | 看哪里 |
|---|---|
| 卡在黑屏 / 没到 systemd | 串口或 `cat /var/lib/crux/boottrace.txt`（根挂上后才可见）；早期日志 `crux-early.log` |
| 进 rescue shell（`/ #`） | 候选全失败，控制台会打印候选列表；手动 `mount /dev/sdaXX /newroot` 试探 |
| 启动了"另一个系统" | 检查 grub 的 `root=` 是否写错；本 initramfs 已保证 `root=` 优先 |
| 模块加载失败 | boottrace 里 `modules: NO` → 内核与 rootfs 的 `/lib/modules/<kver>` 版本串不一致 |

## 7. 已知限制 / Roadmap

- 现在依赖「基础 initramfs」提供工具集，不从头编 busybox。后续可以切换到
  `busybox-static` + `e2fsprogs` 自建，摆脱对基础包的依赖。
- 只做 ext4（crux 目前根分区都是 ext4）。
- 没有加密根的分支（dm-crypt 未适配）。

## 8. 相关仓库

| 仓库 | 内容 |
|---|---|
| `crux-minimal-rootfs` | 可解压即用的根文件系统 tar（含固件、内核模块、overlay） |
| `linux`（`crux-sm8150-73` 分支） | 内核 `Image` + `.dtb` + 内核模块 |
| **本仓库** | `initramfs.cpio.gz`：根分区定位 + 分区体检/修复 |
