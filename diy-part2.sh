#!/bin/bash
# ================================================================
# diy-part2.sh —— 默认值定制 + 配置定型（加载 .config 之后运行）
# 运行目录：OpenWrt 源码根（$BUILD_ROOT/openwrt）
# ================================================================
set -euo pipefail

# ---- 失败诊断 ----------------------------------------------------
# 断言失败时输出 GitHub 注解（::error::），run 页面顶部直接能看到原因，
# 不用翻几千行日志；ERR trap 兜住"没预想到会失败"的命令（如 make defconfig）。
# 注意 fail 里的 exit 不触发 ERR trap，所以不会重复报错。
fail() { echo "::error::diy-part2: $*" >&2; exit 1; }
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "::error::diy-part2 意外失败 rc=$rc：$BASH_COMMAND" >&2' ERR

ASSETS="${ASSETS:-$GITHUB_WORKSPACE}"

# ---- 机型选择：来自 workflow_dispatch 的 target_model 输入 ----
# 只编所选机型；其余机型在下面第 5 节统一关闭。
ALL_DEVICES="youhua_pt1570_r10 tianyi_tyfza1_2p5g tianyi_tyfza1_4ge youhua_pt1500_h10_2p5g"
PROFILE="${TARGET_MODEL:-youhua_pt1570_r10}"
case " $ALL_DEVICES " in
  *" $PROFILE "*) ;;
  *) fail "未知机型 '$PROFILE'（可选：$ALL_DEVICES）" ;;
esac
# 主机名/SSID 默认值跟随机型（仍可用环境变量覆盖）
case "$PROFILE" in
  youhua_pt1570_r10)      MODEL_LABEL="PT1570-R10" ;;
  tianyi_tyfza1_2p5g)     MODEL_LABEL="TYFZA1-2.5G" ;;
  tianyi_tyfza1_4ge)      MODEL_LABEL="TYFZA1-4GE" ;;
  youhua_pt1500_h10_2p5g) MODEL_LABEL="PT1500-H10" ;;
esac
WRT_IP="${WRT_IP:-192.168.1.1}"
WRT_NAME="${WRT_NAME:-$MODEL_LABEL}"
# 2026-11-19 起无线默认值完全跟随 ITB 原厂固件：SSID/加密由
# files/etc/uci-defaults/92-tyfza1-wifi-default 在首启时生成，不再编译期改写模板。
WRT_TZ="${WRT_TZ:-<+08>-8}"
WRT_ZONENAME="${WRT_ZONENAME:-Asia/Shanghai}"
FW_AUTHOR="${FW_AUTHOR:-lu-1991}"
echo "TARGET_MODEL=$PROFILE (hostname=$MODEL_LABEL)"

CFG="package/base-files/files/bin/config_generate"
WIFI_UC="package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"

echo "=========================================="
echo "diy-part2: 默认值定制 + 配置定型"
echo "=========================================="

echo "---- [1/7] config_generate 默认值 ----"
# ---- 1. config_generate 默认值 ----
if [ -f "$CFG" ]; then
  sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG"
  sed -i "s|set system\.@system\[-1\]\.hostname='[^']*'|set system.@system[-1].hostname='$WRT_NAME'|" "$CFG"
  sed -i "s|timezone='[^']*'|timezone='$WRT_TZ'|" "$CFG"
  sed -i "s|zonename='[^']*'|zonename='$WRT_ZONENAME'|" "$CFG"
  sed -i \
    -e "s|time\.apple\.com|ntp.aliyun.com|g" \
    -e "s|time1\.google\.com|time1.cloud.tencent.com|g" \
    -e "s|time\.cloudflare\.com|ntp.ntsc.ac.cn|g" \
    -e "s|pool\.ntp\.org|cn.pool.ntp.org|g" "$CFG"
  echo "✅ IP=$WRT_IP hostname=$WRT_NAME tz=$WRT_TZ NTP=国内源"
else
  echo "::warning::未找到 $CFG，跳过默认值修改"
fi

echo "---- [1b/7] 无线方案（完全对齐 ITB 原厂固件） ----"
# ---- 1b. 无线默认值：mac80211.uc 保持原厂/上游原样 ----
# 2026-11-19：从 new-fit-4ge-20261119.itb 解包确认，原厂 mac80211.uc 与上游
# 逐行相同；SSID / WPA2-PSK / 首启启用全部由原厂 uci-defaults 负责：
#   files/etc/uci-defaults/92-tyfza1-wifi-default
#   files/etc/uci-defaults/92-tyfza1-wireless-country
# 本脚本不再改写生成器，只做"没有被上一版钉死脚本污染"的硬断言。
WIFI_DEF=files/etc/uci-defaults/92-tyfza1-wifi-default
test -f "$WIFI_DEF" \
  || fail "缺少原厂无线默认脚本 $WIFI_DEF"
grep -qF "wireless.default_radio0.ssid=\"TYFZA1-5G-" "$WIFI_DEF" \
  || fail "$WIFI_DEF 未设置原厂 5G SSID"
grep -qF "wireless.default_radio1.ssid=\"TYFZA1-" "$WIFI_DEF" \
  || fail "$WIFI_DEF 未设置原厂 2.4G SSID"
grep -qF "wireless.default_radio0.encryption='psk2'" "$WIFI_DEF" \
  || fail "$WIFI_DEF 未设置 WPA2-PSK"
grep -qF "wireless.default_radio0.key='12345678'" "$WIFI_DEF" \
  || fail "$WIFI_DEF 未设置原厂默认密钥"
# 2026-11-19 启动链路复核：factory 卷异常时 /tmp/tyfza1-factory/lan_mac 不存在，
# br-lan 在 S10boot 也还没建，原版 92 号脚本会 exit 0 提前退出并被 boot 删除，
# 导致 5G 停在 disabled=1 / SSID=OpenWrt / 加密=none。CI 版必须有回退与重试。
grep -qF 'suffix="0000"' "$WIFI_DEF" \
  || fail "$WIFI_DEF 缺无 MAC 兜底（factory 卷异常时默认无线配置会整段跳过）"
! grep -qE '^\[ -n "\$suffix" \] \|\| exit 0' "$WIFI_DEF" \
  || fail "$WIFI_DEF 仍会在无 MAC 时 exit 0 被 boot 删除"
grep -qF "|| exit 1" "$WIFI_DEF" \
  || fail "$WIFI_DEF 缺 wifi-iface 时序重试保护"
# htmode / 信道仍交还驱动推导：模板里不允许残留旧的 HT20 钉死。
if [ -f "$WIFI_UC" ]; then
  if grep -qE 'htmode[[:space:]]*=[[:space:]]*"HT20"' "$WIFI_UC"; then
    fail "mac80211.uc 仍存在 htmode 钉死（应交还驱动推导）"
  fi
  grep -qF 'filter(htmode_order, (m) => band[lc(m)])[0]' "$WIFI_UC" \
    || fail "mac80211.uc 的 htmode 推导块缺失（原厂应保持上游原样）"
  echo "✅ mac80211.uc 保持原厂原样，htmode/信道交还驱动推导"
else
  echo "::warning::未找到 $WIFI_UC，跳过模板核验"
fi
echo "✅ 无线默认：原厂 TYFZA1-xxxx / TYFZA1-5G-xxxx + WPA2-PSK（首启由 92 号脚本生成）"

echo "---- [1c/7] 2.4G 开机兜底脚本 ----"
# ---- 1c. 2.4G 开机兜底：首启阶段补齐 country / 启用 / 不隐藏 ----
# 编译期改的是"生成器"，前提是刷机时选"不保留配置"；否则 /etc/config/wireless
# 不会重新生成，等于没改。这里在首启阶段再兜一次。
# 注意：协议（htmode）与信道同样交还驱动推导，兜底脚本不做钉死 —— 与原厂一致。
WIFI24=files/etc/uci-defaults/97-pt1570-r10-wifi24
test -f "$WIFI24" \
  || fail "缺少 $WIFI24（2.4G 只有编译期改写，重启后可能回退）"
grep -qE "country='?CN" "$WIFI24" \
  || fail "$WIFI24 未设置 country=CN"
if grep -qE "htmode='?[A-Z]+[0-9]+|channel='?[0-9]+" "$WIFI24"; then
  fail "$WIFI24 不应钉死 htmode / 信道（应交还驱动推导）"
fi
echo "✅ 2.4G 开机兜底脚本就位：$WIFI24"

echo "---- [1d/7] Fluent 主题（拉库编译，锁定 v1.0.9） ----"
# ---- 1d. luci-theme-fluent：从上游源码构建 ----
# 锁定 tag v1.0.9 解引用后的 commit：该 commit 的 package/ 下只有主题一个包，
# 依赖仅 +luci-base（main 分支后加了 +flock，本环境无 flock 包会导致 defconfig
# 丢包，故不追 main）。上游打 v1.0.9 标签时 Makefile 忘了 bump，仍是 1.0.8，
# 所以版本断言写 1.0.8 是对的；升级主题只改 FLUENT_SHA。
FLUENT_REPO="${FLUENT_REPO:-https://github.com/LazuliKao/luci-theme-fluent}"
FLUENT_SHA="${FLUENT_SHA:-bd52cc181baa54b194f4cd3e34810aa3d8e37f50}"
FPKG=package/luci-theme-fluent
if [ ! -f "$FPKG/Makefile" ]; then
  rm -rf "$FPKG" .fluent-src
  for i in 1 2 3; do
    git clone -q "$FLUENT_REPO" .fluent-src && break
    echo "  clone 第 $i 次失败，重试…"; rm -rf .fluent-src; sleep 5
    [ "$i" = 3 ] && fail "Fluent 主题仓库克隆失败（$FLUENT_REPO）"
  done
  git -C .fluent-src checkout -q "$FLUENT_SHA" \
    || fail "Fluent checkout $FLUENT_SHA 失败（上游仓库被改写？）"
  [ "$(git -C .fluent-src rev-parse HEAD)" = "$FLUENT_SHA" ] \
    || fail "Fluent 源码不在锁定的 commit $FLUENT_SHA"
  cp -a .fluent-src/package/luci-theme-fluent "$FPKG" 2>/dev/null \
    || { mkdir -p package && cp -a .fluent-src/package/luci-theme-fluent "$FPKG"; }
  rm -rf .fluent-src
fi
grep -q '^PKG_NAME:=luci-theme-fluent$' "$FPKG/Makefile" \
  || fail "$FPKG/Makefile 不是 luci-theme-fluent"
grep -q '^PKG_VERSION:=1\.0\.8$' "$FPKG/Makefile" \
  || fail "$FPKG/Makefile 版本不是 1.0.8（v1.0.9 tag commit 应为 1.0.8）"
grep -q '^LUCI_DEPENDS:=+luci-base$' "$FPKG/Makefile" \
  || fail "$FPKG/Makefile 依赖变了（不应含 +flock，本环境无此包）"
echo "✅ Fluent 主题源码就位 @ $FLUENT_SHA (v1.0.9)"

echo "---- [2/7] apk 源声明 ----"
# ---- 2. apk 源声明 ----
mkdir -p files/etc/apk/repositories.d
{
  echo "# 本 target 架构 aarch64_cortex-a55，官方/国内镜像一般没有该目录，"
  echo "# 默认不启用任何外部源。配套内核模块与用户态包用同批 packages。"
} > files/etc/apk/repositories.d/distfeeds.list
echo "✅ distfeeds.list 已生成"

echo "---- [3/7] 固件版本号 ----"
# ---- 3. 固件版本号：追加作者与构建时间 ----
FW_BUILD_TIME="${FW_BUILD_TIME:-$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M')}"
DESC_BODY='%D %V %C'
FW_DESC_SUFFIX="${FW_DESC_SUFFIX:-· ${FW_AUTHOR} · ${FW_BUILD_TIME}}"
FW_DESC_LINE="DISTRIB_DESCRIPTION='${DESC_BODY} ${FW_DESC_SUFFIX}'"
OSREL_LINE="OPENWRT_RELEASE=\"${DESC_BODY} ${FW_DESC_SUFFIX}\""
export FW_DESC_LINE OSREL_LINE
for f in package/base-files/files/etc/openwrt_release \
         package/base-files/files/usr/lib/os-release; do
  if [ -f "$f" ]; then
    if [ "${f##*/}" = "openwrt_release" ]; then
      perl -i -pe 's/^DISTRIB_DESCRIPTION=.*/$ENV{FW_DESC_LINE}/' "$f"
    else
      perl -i -pe 's/^OPENWRT_RELEASE=.*/$ENV{OSREL_LINE}/' "$f"
    fi
    echo "✅ 版本号模板已更新: $f"
  fi
done

echo "---- [4/7] 机型 profile ----"
# ---- 4. 机型 profile 双保险 ----
grep -q "^CONFIG_TARGET_rtl9617c_generic_DEVICE_${PROFILE}=y$" .config || \
  echo "CONFIG_TARGET_rtl9617c_generic_DEVICE_${PROFILE}=y" >> .config
sed -i "/^CONFIG_TARGET_PROFILE=/d" .config
echo "CONFIG_TARGET_PROFILE=\"DEVICE_${PROFILE}\"" >> .config

echo "---- [4b/7] ccache / initramfs ----"
# ---- 4b. 编译加速（ccache）与镜像范围（initramfs） ----
# ccache 的开关在上游 config/Config-devel.in 里是：
#     menuconfig DEVEL
#     config CCACHE
#         bool "Use ccache" if DEVEL        <-- 有 "if DEVEL"
# 也就是说 DEVEL=n 时该符号**不可见**，Kconfig 会把它强制回默认值 n，
# .config 里写的 CONFIG_CCACHE=y 会被 defconfig 改写成 "# ... is not set"。
# 2026-11-14 实测：只写 CCACHE=y 时，下面第 6 节的断言直接失败（job 25 秒退出）。
# 所以必须同时打开 DEVEL —— 它只是让"开发者选项"可见，不改默认产物。
sed -i '/^# CONFIG_DEVEL is not set$/d; /^CONFIG_DEVEL=/d' .config
echo "CONFIG_DEVEL=y" >> .config
# DEVEL=y 会顺带把 AUTOREBUILD 的默认值变成 y（config/Config-devel.in 里
# "bool ... if DEVEL" + "default y"）。CI 里它只会让 make 反复重编，显式关掉。
sed -i '/^# CONFIG_AUTOREBUILD is not set$/d; /^CONFIG_AUTOREBUILD=/d' .config
echo "# CONFIG_AUTOREBUILD is not set" >> .config
# ccache 缓存目录由 rules.mk 决定：CONFIG_CCACHE_DIR 为空时用 $(TOPDIR)/.ccache
# （即源码根的 .ccache），workflow 按这个路径做缓存。
sed -i '/^# CONFIG_CCACHE is not set$/d; /^CONFIG_CCACHE=/d' .config
echo "CONFIG_CCACHE=y" >> .config
echo "✅ ccache: 启用（DEVEL=y，AUTOREBUILD 关闭）"

# initramfs-recovery 要单独再编一遍内核（约多 8 分钟）。
# 默认不编；需要救砖镜像时在 Run workflow 里勾 build_initramfs。
if [ "${BUILD_INITRAMFS:-false}" = "true" ]; then
  sed -i '/^# CONFIG_TARGET_ROOTFS_INITRAMFS is not set$/d' .config
  echo "CONFIG_TARGET_ROOTFS_INITRAMFS=y" >> .config
  echo "✅ initramfs-recovery: 构建（+约 8 分钟）"
else
  sed -i '/^CONFIG_TARGET_ROOTFS_INITRAMFS=y$/d' .config
  echo "# CONFIG_TARGET_ROOTFS_INITRAMFS is not set" >> .config
  echo "✅ initramfs-recovery: 跳过（仅出 sysupgrade.itb）"
fi

echo "---- [5/7] 两次 defconfig（最慢的一步） ----"
# ---- 5. 两次 defconfig + 丢包重新断言 ----
# uboot-envtools 的 host fw_printenv 在此 target 会挂，必须保持关闭
sed -i 's|^CONFIG_PACKAGE_uboot-envtools=y|# CONFIG_PACKAGE_uboot-envtools is not set|' .config

make defconfig
for sym in tyfza1-pon-control luci-ssl uhttpd fitblk tailscale \
           luci-app-tailscale-community luci-i18n-tailscale-community-zh-cn \
           luci-app-samba4 samba4-server vsftpd \
           luci-app-upnp miniupnpd-nftables luci-app-wol \
           luci-theme-fluent luci-i18n-fluent-zh-cn; do
  if ! grep -q "^CONFIG_PACKAGE_${sym}=y$" .config; then
    sed -i "/^# CONFIG_PACKAGE_${sym} is not set$/d; /^CONFIG_PACKAGE_${sym}=/d" .config
    echo "CONFIG_PACKAGE_${sym}=y" >> .config
    echo "  re-asserted $sym"
  fi
done
make defconfig

# 只构建所选机型：defconfig 会把 target 的默认机型一起选中，多产出其它 itb。
# 产物文件名 tianyi_* 字母序在 youhua_* 之前，取产物/校验时极易抓错（2026-11-13 实测）。
for d in $ALL_DEVICES; do
  [ "$d" = "$PROFILE" ] && continue
  sed -i "s|^CONFIG_TARGET_rtl9617c_generic_DEVICE_${d}=y$|# CONFIG_TARGET_rtl9617c_generic_DEVICE_${d} is not set|" .config
done
n_dev=$(grep -cE '^CONFIG_TARGET_rtl9617c_generic_DEVICE_[A-Za-z0-9_]+=y$' .config || true)
[ "$n_dev" = "1" ] \
  || fail "启用了 $n_dev 个机型，必须只有 $PROFILE"

echo "---- [6/7] 硬断言 ----"
# ---- 6. 硬断言（任何一条失败都说明配置被破坏，提前终止而不是编两小时后炸）----
echo "===== hard assertions ====="
# 虚拟包防御：miniupnpd 只有 PROVIDES，写裸名必被 defconfig 丢弃
! grep -q '^CONFIG_PACKAGE_miniupnpd=y$' .config \
  || fail "CONFIG_PACKAGE_miniupnpd=y 是虚拟包，必须写 miniupnpd-nftables"
grep -q "^CONFIG_TARGET_rtl9617c_generic_DEVICE_${PROFILE}=y$" .config \
  || fail "profile $PROFILE 未启用"
# defconfig 会把没有依赖的选项清掉，这里确认"加速"与"镜像范围"没被悄悄改回去
grep -q '^CONFIG_DEVEL=y$' .config \
  || fail "CONFIG_DEVEL 被 defconfig 丢弃（它不可见时 CONFIG_CCACHE 会连带失效）"
echo "  OK   CONFIG_DEVEL=y"
grep -q '^CONFIG_CCACHE=y$' .config \
  || fail "CONFIG_CCACHE 被 defconfig 丢弃（编译会慢很多）"
echo "  OK   CONFIG_CCACHE=y"
if grep -qE '^CONFIG_AUTOREBUILD=y$' .config; then
  fail "CONFIG_AUTOREBUILD 被 DEVEL 带成 y（会让 make 反复重编）"
fi
echo "  OK   AUTOREBUILD 已关闭"
if [ "${BUILD_INITRAMFS:-false}" = "true" ]; then
  grep -q '^CONFIG_TARGET_ROOTFS_INITRAMFS=y$' .config \
    || fail "勾了 build_initramfs 但 CONFIG_TARGET_ROOTFS_INITRAMFS 未启用"
  echo "  OK   initramfs-recovery 已启用"
else
  grep -q '^# CONFIG_TARGET_ROOTFS_INITRAMFS is not set$' .config \
    || fail "未勾 build_initramfs，但 initramfs 仍被启用（会多编一次内核）"
  echo "  OK   initramfs-recovery 已关闭"
fi
for sym in tyfza1-pon-control luci-ssl uhttpd fitblk tailscale \
           luci-app-tailscale-community luci-i18n-tailscale-community-zh-cn \
           luci-app-samba4 samba4-server vsftpd \
           luci-app-upnp miniupnpd-nftables luci-app-wol \
           luci-theme-fluent luci-i18n-fluent-zh-cn \
           luci-theme-argon luci-app-argon-config \
           luci-i18n-argon-config-zh-cn \
           kmod-fs-ext4 kmod-fs-vfat kmod-nls-utf8 kmod-usb-storage \
           kmod-usb-storage-uas wpad-mesh-openssl; do
  grep -q "^CONFIG_PACKAGE_${sym}=y$" .config \
    || fail "$sym 在两次 defconfig 后被丢弃"
  echo "  OK   $sym"
done
# 两套主题并存（2026-11-18 用户确认）：argon 由设备 profile 的 DEVICE_PACKAGES
# 与 pon 包依赖强选，配置里也显式打开；默认主题由 files/etc/uci-defaults/
# 98-pt1570-fluent-default 设为 Fluent（必须排在厂商的 97-rtl9617c-argon-default
# 之后，否则又被改回 Argon），Argon 仍可在「系统→语言和界面」切换。
echo "  OK   Fluent 默认 + argon 并存（Fluent 设置页随包编译）"

# files/ 静态注入已废弃：主题一律走 package 源码构建，残留文件说明有旧缓存
# （files/etc/uci-defaults/98-pt1570-fluent-default 是默认主题开关，不算静态注入）
find files \( -iname '*vantage*' -o -iname '*fluent*' \) ! -path '*/etc/uci-defaults/*' \
  -print -quit 2>/dev/null | grep -q . \
  && fail "files/ 里残留 Vantage/Fluent 静态主题文件（应删除，主题走拉库编译）"
echo "  OK   files/ 无静态主题残留（默认主题脚本除外）"
grep -q '^# CONFIG_PACKAGE_uboot-envtools is not set$' .config \
  || fail "uboot-envtools 必须关闭"
echo "  OK   uboot-envtools disabled"

# FIT rootfs 能不能挂上，取决于两个内核符号（必须落在 target config，
# 写顶层 .config 会被 make defconfig 静默丢弃）
grep -q '^CONFIG_UIMAGE_FIT_BLK=y$' target/linux/rtl9617c/config-6.18 \
  || fail "target config-6.18 缺少 CONFIG_UIMAGE_FIT_BLK=y"
grep -q '^CONFIG_MTD_ROOTFS_ROOT_DEV=y$' target/linux/generic/config-6.18 \
  || fail "generic config-6.18 缺少 CONFIG_MTD_ROOTFS_ROOT_DEV=y"
echo "  OK   UIMAGE_FIT_BLK + MTD_ROOTFS_ROOT_DEV"

# 默认 WAN = pon0.1101 + PPPoE + PON FE（2026-11-11 真机实证——仅 R10 验证过）。
# 其它机型的上行 VLAN 未在本仓库验证，不带这套默认值，由上游默认配置接管。
WAN_DEF=files/etc/uci-defaults/95-pt1570-wan-default
if [ "$PROFILE" = "youhua_pt1570_r10" ]; then
  test -f "$WAN_DEF" \
    || fail "缺少默认 WAN 的 uci-defaults 脚本"
  grep -q 'wan_vlan=1101' "$WAN_DEF" \
    || fail "默认上网 VLAN 未设为 1101"
  grep -q "pon.pon.offload='1'" "$WAN_DEF" \
    || fail "默认未打开 PON FE(offload=1)，单播上行会全丢"
  ! grep -q "type='8021q'" "$WAN_DEF" \
    || fail "uci 值里出现了字面单引号，netifd 认不出设备类型"
  echo "  OK   default WAN -> pon0.1101 (pppoe) + PON FE on"
else
  # 同步删掉资产树与源码树两份副本，避免 payload 校验 MISMATCH / 镜像带错 VLAN
  rm -f "$WAN_DEF" "$ASSETS/files/etc/uci-defaults/95-pt1570-wan-default"
  echo "  SKIP default WAN（$PROFILE 非 R10，VLAN 未验证，交由上游默认）"
fi

# 板级注入核验
grep -q "SUPPORTED_DEVICES += youhua,pt1570-r10" target/linux/rtl9617c/image/Makefile \
  || fail "image/Makefile 缺少 SUPPORTED_DEVICES"
grep -q "youhua,pt1570-r10" target/linux/rtl9617c/base-files/lib/upgrade/platform.sh \
  || fail "platform.sh 白名单缺少 youhua,pt1570-r10"
test -f target/linux/rtl9617c/dts/rtl9617c-pt1570-r10.dts \
  || fail "DTS 缺失"
echo "  OK   DTS + image/Makefile + platform.sh"

# 空配置 defconfig 会把上游默认 target 的包写成显式 =y（污染源），反向断言
for bad in kmod-mac80211 kmod-cfg80211 kmod-mt7915e kmod-mt76-core \
           wpad-basic-mbedtls mt7981-wo-firmware eip197-mini-firmware; do
  if grep -qE "^CONFIG_PACKAGE_${bad}=(y|m)$" .config; then
    fail "检测到污染包 ${bad}（默认 target 的包残留）"
  fi
done
echo "  OK   无 mediatek/openwrt_one 残留包"

# WiFi 驱动 overlay 核验：PE 头必须是已 revert 的参考版（4076 words）
DST=target/linux/rtl9617c/files-6.18/drivers/net/wireless/realtek/rtl_ax_ap
got=$(md5sum "$DST/pe-tx-code.h" | cut -d' ' -f1)
[ "$got" = "7eb49893f43b897bf03fa82ae2323984" ] \
  || fail "pe-tx-code.h md5=$got，参考版 PE 程序未生效"
echo "  OK   rtl_ax_ap = PT1570 verified version"

echo "===== key config ====="
grep -E '^CONFIG_TARGET_(BOARD|SUBTARGET)=' .config || true
cp .config "$ASSETS/Config-final.txt"
echo "🎉 diy-part2.sh 完成"
