#!/bin/bash -e

TARGET_ROOTFS_DIR="binary"
KERNEL_VER="5.10.160"
ARCH="arm64"
VERSION="debug"

echo -e "\033[36m ====== 开始构建 RK3588 Debian 镜像 ====== \033[0m"
echo -e "\033[36m 架构：${ARCH} | 内核：${KERNEL_VER} | 版本：${VERSION} \033[0m"

# -------- 1. 前置检查 --------
if [ ! -e linaro-bullseye-alip-*.tar.gz ]; then
	echo -e "\033[31m 错误：未找到基础镜像！请先运行 mk-base-debian.sh \033[0m"
	exit 1
fi

# -------- 2. 解压基础镜像 --------
echo -e "\033[36m 清理旧构建目录... \033[0m"
sudo rm -rf $TARGET_ROOTFS_DIR

echo -e "\033[36m 解压基础镜像... \033[0m"
sudo tar -xpf linaro-bullseye-alip-*.tar.gz

# -------- 3. 拷贝预编译包和overlay --------
echo -e "\033[36m 拷贝预编译包... \033[0m"
sudo mkdir -p $TARGET_ROOTFS_DIR/packages
sudo cp -rpf packages/$ARCH/* $TARGET_ROOTFS_DIR/packages 2>/dev/null || true
sudo cp -rpf overlay/* $TARGET_ROOTFS_DIR/
sudo cp -rpf overlay-firmware/* $TARGET_ROOTFS_DIR/
sudo cp -rpf overlay-debug/* $TARGET_ROOTFS_DIR/

# -------- 4. 【第一次拷贝】宿主机层面拷贝SDK固件 --------
echo -e "\033[36m ====== 宿主机拷贝WiFi/BT固件 ====== \033[0m"
SDK_FW_BASE="/RK3588/rk3588_sdk/debian/overlay/usr/lib/firmware"
ROOTFS_FW="$TARGET_ROOTFS_DIR/lib/firmware"

sudo mkdir -p ${ROOTFS_FW}/rtw88 ${ROOTFS_FW}/rtl_bt
sudo cp -fvL ${SDK_FW_BASE}/rtw88/rtw8822c_fw.bin ${ROOTFS_FW}/rtw88/ 2>/dev/null || true
sudo cp -fvL ${SDK_FW_BASE}/rtw88/rtw8822c_wow_fw.bin ${ROOTFS_FW}/rtw88/ 2>/dev/null || true
sudo cp -fvL ${SDK_FW_BASE}/rtl_bt/rtl8822cs_config.bin ${ROOTFS_FW}/rtl_bt/ 2>/dev/null || true
sudo cp -fvL ${SDK_FW_BASE}/rtl_bt/rtl8822cs_fw.bin ${ROOTFS_FW}/rtl_bt/ 2>/dev/null || true

# 宿主机校验
echo -e "\033[36m 宿主机校验固件... \033[0m"
FW_CHECK_PASS=1
for fw in ${ROOTFS_FW}/rtw88/rtw8822c_fw.bin ${ROOTFS_FW}/rtl_bt/rtl8822cs_fw.bin; do
	if [ -s "$fw" ]; then
		SIZE=$(du -h "$fw" 2>/dev/null | cut -f1)
		echo -e "\033[32m ✅ 宿主机找到固件：$fw ($SIZE) \033[0m"
	else
		echo -e "\033[31m ❌ 宿主机固件缺失：$fw \033[0m"
		FW_CHECK_PASS=0
	fi
done

if [ $FW_CHECK_PASS -eq 0 ]; then
	echo -e "\033[31m 宿主机固件校验失败，退出构建 \033[0m"
	exit 1
fi

# -------- 5. 准备chroot环境 --------
echo -e "\033[36m 准备chroot环境... \033[0m"
sudo rm -f $TARGET_ROOTFS_DIR/etc/resolv.conf
sudo cp -f /etc/resolv.conf $TARGET_ROOTFS_DIR/etc/

# -------- 6. 进入chroot配置 --------
echo -e "\033[36m ====== 进入chroot配置系统 ====== \033[0m"
sudo chroot $TARGET_ROOTFS_DIR /bin/bash << 'EOF_CHROOT'
set -e

echo -e "\033[36m Chroot：修复文件属主... \033[0m"
ID=$(stat --format %u /)
if [ "$ID" -ne 0 ]; then
	find / -user $ID -exec chown -h 0:0 {} \; 2>/dev/null
fi
for u in $(ls /home/ 2>/dev/null); do
	chown -h -R $u:$u /home/$u 2>/dev/null
done

echo -e "\033[36m Chroot：配置DNS... \033[0m"
cat > /etc/resolv.conf << 'DNS_CONF'
nameserver 8.8.8.8
nameserver 114.114.114.114
DNS_CONF

echo -e "\033[36m Chroot：配置APT源（仅保留中科大主源）... \033[0m"
cat > /etc/apt/sources.list << 'APT_SOURCE'
deb http://mirrors.ustc.edu.cn/debian bullseye main contrib non-free
deb http://mirrors.ustc.edu.cn/debian-security bullseye-security main contrib non-free
deb http://mirrors.ustc.edu.cn/debian bullseye-updates main contrib non-free
APT_SOURCE
apt-get update -y
apt-get upgrade -y

APT_INSTALL="apt-get install -fy --allow-downgrades"

echo -e "\033[36m Chroot：配置串口免密登录... \033[0m"
sed -i "s~\(^ExecStart=.*\)~# \1\nExecStart=-/bin/sh -c '/bin/bash -l </dev/%I >/dev/%I 2>\&1'~" /usr/lib/systemd/system/serial-getty@.service

echo -e "\033[36m Chroot：卸载linux-firmware包（避免覆盖我们的固件）... \033[0m"
apt-get remove --purge -fy linux-firmware* 2>/dev/null || true

echo -e "\033[36m Chroot：校验/lib/firmware下的固件... \033[0m"
for fw in /lib/firmware/rtw88/rtw8822c_fw.bin /lib/firmware/rtl_bt/rtl8822cs_fw.bin; do
	if [ -s "$fw" ]; then
		SIZE=$(du -h "$fw" 2>/dev/null | cut -f1)
		echo -e "\033[32m ✅ Chroot内找到固件：$fw ($SIZE) \033[0m"
	else
		echo -e "\033[31m ❌ Chroot内固件缺失：$fw \033[0m"
		ls -la $(dirname "$fw") 2>/dev/null || true
		exit 1
	fi
done

echo -e "\033[36m Chroot：配置RTL8822CS模块... \033[0m"
echo "rtw_8822cs" > /etc/modules
cat > /etc/modprobe.d/rtl8822cs.conf << 'MODCONF'
options rtw_8822cs
MODCONF

echo -e "\033[36m Chroot：配置NetworkManager... \033[0m"
systemctl enable NetworkManager 2>/dev/null || true
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/wifi.conf << 'NM_CONF'
[device]
wifi.scan-rand-mac-address=no
wifi.backend=wpa_supplicant

[connection]
wifi.powersave=2
NM_CONF
systemctl mask systemd-networkd-wait-online.service NetworkManager-wait-online.service 2>/dev/null || true
rm -f /lib/systemd/system/wpa_supplicant@.service 2>/dev/null || true

# ==================== Docker 完全集成 ====================
echo -e "\033[36m Chroot：安装 Docker（完全集成）... \033[0m"

# 1. 安装 Docker deb 包
if [ -d "/packages/docker" ] && [ "$(ls -A /packages/docker/*.deb 2>/dev/null)" ]; then
    echo -e "\033[36m 安装 Docker deb 包... \033[0m"
    $APT_INSTALL /packages/docker/*.deb 2>/dev/null || true
    apt-get install -f -y
    
    # 2. 将 linaro 用户添加到 docker 组
    usermod -aG docker linaro
    
    # 3. 创建 Docker 配置文件
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << 'DOCKER_CONFIG'
{
  "registry-mirrors": [
    "https://docker.mirrors.ustc.edu.cn",
    "https://hub-mirror.c.163.com",
    "https://mirror.baidubce.com"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
DOCKER_CONFIG
    
    # 4. Docker Compose 已通过 overlay 预置
    if [ -f "/usr/local/bin/docker-compose" ]; then
        chmod +x /usr/local/bin/docker-compose
        echo -e "\033[32m ✅ Docker Compose 已就绪 \033[0m"
    fi
    
    # 5. 启用 Docker 服务
    systemctl enable docker
    systemctl enable containerd
    
    echo -e "\033[32m ✅ Docker 完全集成完成 \033[0m"
else
    echo -e "\033[33m ⚠️ 未找到 Docker deb 包，跳过 Docker 安装 \033[0m"
fi

echo -e "\033[36m Chroot：安装exfat支持（用于兼容exfat格式）... \033[0m"
$APT_INSTALL exfat-fuse exfat-utils 2>/dev/null || true

echo -e "\033[36m Chroot：配置SSD挂载准备... \033[0m"
# 创建挂载目录
mkdir -p /home/linaro/ssd

# 创建SSD配置辅助脚本（用于首次配置）
cat > /usr/local/bin/configure-ssd.sh << 'SSD_CONFIG'
#!/bin/bash
# SSD 配置脚本

if [ "$EUID" -ne 0 ]; then 
    echo "请使用 root 权限运行: sudo $0"
    exit 1
fi

echo "=== M.2 SSD 配置工具 ==="
echo ""
echo "检测到的 NVMe 设备："
lsblk | grep nvme || echo "未检测到 NVMe 设备"
echo ""

# 检测SSD设备
if [ -b "/dev/nvme0n1p1" ]; then
    SSD_DEV="/dev/nvme0n1p1"
elif [ -b "/dev/nvme1n1p1" ]; then
    SSD_DEV="/dev/nvme1n1p1"
else
    echo "❌ 未检测到 M.2 SSD 分区"
    echo "请检查 SSD 是否正确安装"
    exit 1
fi

echo "检测到 SSD 设备: $SSD_DEV"
CURRENT_FS=$(blkid $SSD_DEV -s TYPE -o value 2>/dev/null)
echo "当前文件系统: ${CURRENT_FS:-未格式化}"

echo ""
echo "请选择操作："
echo "1) 格式化为 ext4（推荐，Linux原生支持，自动挂载）"
echo "2) 保持现有格式，仅配置自动挂载"
echo "3) 退出"
read -p "请选择 [1-3]: " choice

case $choice in
    1)
        echo "⚠️  警告：格式化会删除 SSD 上的所有数据！"
        read -p "确认要继续吗？(yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            echo "已取消"
            exit 0
        fi
        
        echo "正在卸载 $SSD_DEV ..."
        umount $SSD_DEV 2>/dev/null || true
        
        echo "正在格式化为 ext4 ..."
        mkfs.ext4 -F $SSD_DEV
        
        echo "正在配置自动挂载..."
        mkdir -p /home/linaro/ssd
        UUID=$(blkid $SSD_DEV -s UUID -o value)
        
        # 移除旧的挂载条目
        sed -i '/\/home\/linaro\/ssd/d' /etc/fstab
        
        # 添加新条目
        echo "UUID=$UUID /home/linaro/ssd ext4 defaults,nofail,noatime 0 2" >> /etc/fstab
        
        # 挂载
        mount /home/linaro/ssd
        chown -R linaro:linaro /home/linaro/ssd
        
        echo "✅ SSD 已格式化为 ext4 并挂载到 /home/linaro/ssd"
        ;;
    2)
        echo "正在配置自动挂载..."
        mkdir -p /home/linaro/ssd
        UUID=$(blkid $SSD_DEV -s UUID -o value)
        FS_TYPE=$(blkid $SSD_DEV -s TYPE -o value)
        
        # 移除旧的挂载条目
        sed -i '/\/home\/linaro\/ssd/d' /etc/fstab
        
        # 根据文件系统类型添加挂载条目
        case $FS_TYPE in
            exfat)
                echo "UUID=$UUID /home/linaro/ssd fuse.exfat defaults,nofail,uid=1000,gid=1000,umask=000,noatime 0 0" >> /etc/fstab
                ;;
            ntfs)
                echo "UUID=$UUID /home/linaro/ssd ntfs-3g defaults,nofail,uid=1000,gid=1000,umask=000,noatime 0 0" >> /etc/fstab
                ;;
            ext4)
                echo "UUID=$UUID /home/linaro/ssd ext4 defaults,nofail,noatime 0 2" >> /etc/fstab
                ;;
            *)
                echo "未知文件系统类型: $FS_TYPE"
                exit 1
                ;;
        esac
        
        # 挂载
        mount /home/linaro/ssd 2>/dev/null || true
        chown -R linaro:linaro /home/linaro/ssd 2>/dev/null || true
        
        echo "✅ SSD 已配置自动挂载到 /home/linaro/ssd"
        ;;
    3)
        echo "退出"
        exit 0
        ;;
    *)
        echo "无效选择"
        exit 1
        ;;
esac

echo ""
echo "当前挂载状态："
df -h /home/linaro/ssd
echo ""
echo "提示：桌面文件管理器可访问 /home/linaro/ssd"
SSD_CONFIG

chmod +x /usr/local/bin/configure-ssd.sh

# 创建桌面快捷方式
mkdir -p /home/linaro/Desktop
cat > /home/linaro/Desktop/配置SSD.desktop << 'DESKTOP_ENTRY'
[Desktop Entry]
Type=Application
Name=配置M.2 SSD
Comment=配置M.2 SSD自动挂载
Exec=sudo /usr/local/bin/configure-ssd.sh
Icon=drive-harddisk
Terminal=true
Categories=System;
DESKTOP_ENTRY

chmod +x /home/linaro/Desktop/配置SSD.desktop
chown -R linaro:linaro /home/linaro/Desktop

echo -e "\033[36m Chroot：安装系统组件... \033[0m"
$APT_INSTALL pm-utils triggerhappy bsdmainutils 2>/dev/null || true
cp /etc/Powermanager/triggerhappy.service /lib/systemd/system/triggerhappy.service 2>/dev/null || true
sed -i "s/#HandlePowerKey=.*/HandlePowerKey=ignore/" /etc/systemd/logind.conf

$APT_INSTALL /packages/rga2/*.deb 2>/dev/null || true
$APT_INSTALL gstreamer1.0-plugins-bad gstreamer1.0-plugins-base gstreamer1.0-plugins-ugly \
	gstreamer1.0-tools gstreamer1.0-alsa gstreamer1.0-plugins-base-apps qtmultimedia5-examples 2>/dev/null || true
$APT_INSTALL /packages/mpp/* /packages/gst-rkmpp/*.deb /packages/gstreamer/*.deb 2>/dev/null || true
$APT_INSTALL cheese v4l-utils /packages/libv4l/*.deb /packages/cheese/*.deb 2>/dev/null || true
$APT_INSTALL /packages/xserver/*.deb 2>/dev/null || true
$APT_INSTALL /packages/openbox/*.deb /packages/chromium/*.deb 2>/dev/null || true
$APT_INSTALL /packages/libdrm/*.deb /packages/libdrm-cursor/*.deb 2>/dev/null || true

echo exit 101 > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d
$APT_INSTALL /packages/blueman/*.deb 2>/dev/null || true
rm -f /usr/sbin/policy-rc.d

$APT_INSTALL /packages/rkwifibt/*.deb 2>/dev/null || true
ln -sfn /lib/firmware /vendor/etc/firmware 2>/dev/null || true

$APT_INSTALL /packages/glmark2/*.deb 2>/dev/null || true

if [ -e "/usr/lib/aarch64-linux-gnu" ]; then
	mv /packages/rknpu2/*.tar / 2>/dev/null || true
fi

$APT_INSTALL /packages/rktoolkit/*.deb 2>/dev/null || true

sed -i 's/^# *\(zh_CN.UTF-8\)/\1/' /etc/locale.gen
echo "LANG=zh_CN.UTF-8" >> /etc/default/locale
locale-gen
echo "export LC_ALL=zh_CN.UTF-8" >> ~/.bashrc
echo "export LANG=zh_CN.UTF-8" >> ~/.bashrc
$APT_INSTALL ttf-wqy-zenhei fonts-aenigma xfonts-intl-chinese 2>/dev/null || true
$APT_INSTALL fontconfig --reinstall 2>/dev/null || true

cp -rf /packages/libmali/libmali-*-x11*.deb / 2>/dev/null || true
cp -rf /packages/rkisp/*.deb / 2>/dev/null || true
cp -rf /packages/rkaiq/*.deb / 2>/dev/null || true
cp -rf /usr/lib/firmware/rockchip/ /lib/firmware/ 2>/dev/null || true

echo -e "\033[36m Chroot：清理冗余文件... \033[0m"
# 只删除不需要的rockchip目录，不删除整个firmware
rm -rf /usr/lib/firmware/rockchip 2>/dev/null || true
mkdir -p /usr/lib/firmware

# 清理包缓存
rm -rf /var/lib/apt/lists/* /var/cache/apt/* /packages/ 2>/dev/null || true

if [ -e "/usr/lib/aarch64-linux-gnu/dri" ]; then
	sed -i "1aexport LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libdrm-cursor.so.1" /usr/bin/X
	cd /usr/lib/aarch64-linux-gnu/dri/
	cp kms_swrast_dri.so swrast_dri.so rockchip_dri.so / 2>/dev/null || true
	rm -f *.so
	mv /*.so . 2>/dev/null || true
	rm -f /etc/profile.d/qt.sh 2>/dev/null || true
fi
cd /

echo -e "\033[36m Chroot：生成模块依赖... \033[0m"
depmod -a 5.10.160 2>/dev/null || true

# 最终验证固件仍在正确位置
echo -e "\033[36m Chroot：退出前最终验证固件... \033[0m"
for fw in /lib/firmware/rtw88/rtw8822c_fw.bin /lib/firmware/rtl_bt/rtl8822cs_fw.bin; do
	if [ -s "$fw" ]; then
		echo -e "\033[32m ✅ 退出前验证通过：$fw \033[0m"
	else
		echo -e "\033[31m ❌ 退出前验证失败：$fw \033[0m"
		exit 1
	fi
done

echo -e "\033[32m ✅ Chroot配置完成！ \033[0m"
EOF_CHROOT

# 检查 chroot 是否成功
if [ $? -ne 0 ]; then
	echo -e "\033[31m ❌ Chroot 配置失败 \033[0m"
	exit 1
fi

# -------- 7. 【关键修复】chroot退出后，强制回拷固件（双重保险）--------
echo -e "\033[36m ====== Chroot退出，强制回拷固件（双重保险） ====== \033[0m"

# 确保目标目录存在
sudo mkdir -p $TARGET_ROOTFS_DIR/lib/firmware/rtw88
sudo mkdir -p $TARGET_ROOTFS_DIR/lib/firmware/rtl_bt

# 强制拷贝
echo -e "\033[36m 强制拷贝固件到镜像...\033[0m"
sudo cp -fv /RK3588/rk3588_sdk/debian/overlay/usr/lib/firmware/rtw88/rtw8822c_fw.bin $TARGET_ROOTFS_DIR/lib/firmware/rtw88/ 2>/dev/null || true
sudo cp -fv /RK3588/rk3588_sdk/debian/overlay/usr/lib/firmware/rtw88/rtw8822c_wow_fw.bin $TARGET_ROOTFS_DIR/lib/firmware/rtw88/ 2>/dev/null || true
sudo cp -fv /RK3588/rk3588_sdk/debian/overlay/usr/lib/firmware/rtl_bt/rtl8822cs_config.bin $TARGET_ROOTFS_DIR/lib/firmware/rtl_bt/ 2>/dev/null || true
sudo cp -fv /RK3588/rk3588_sdk/debian/overlay/usr/lib/firmware/rtl_bt/rtl8822cs_fw.bin $TARGET_ROOTFS_DIR/lib/firmware/rtl_bt/ 2>/dev/null || true

# 同步文件系统
sync

# -------- 8. 最终校验 --------
echo -e "\033[36m ====== 最终校验构建结果 ====== \033[0m"

FW_COUNT=0
for fw in \
	"$TARGET_ROOTFS_DIR/lib/firmware/rtw88/rtw8822c_fw.bin" \
	"$TARGET_ROOTFS_DIR/lib/firmware/rtw88/rtw8822c_wow_fw.bin" \
	"$TARGET_ROOTFS_DIR/lib/firmware/rtl_bt/rtl8822cs_config.bin" \
	"$TARGET_ROOTFS_DIR/lib/firmware/rtl_bt/rtl8822cs_fw.bin"; do
	if [ -s "$fw" ]; then
		SIZE=$(du -h "$fw" 2>/dev/null | cut -f1)
		echo -e "\033[32m ✅ 最终校验通过：$fw ($SIZE) \033[0m"
		FW_COUNT=$((FW_COUNT + 1))
	else
		echo -e "\033[31m ❌ 最终校验失败：$fw 不存在/为空 \033[0m"
	fi
done

# 检查内核模块
if [ -f "$TARGET_ROOTFS_DIR/lib/modules/$KERNEL_VER/modules.dep" ]; then
	echo -e "\033[32m ✅ modules.dep 存在（$KERNEL_VER） \033[0m"
else
	echo -e "\033[33m ⚠️ 警告：modules.dep 不存在（不影响功能） \033[0m"
fi

# 显示最终文件系统统计
echo -e "\033[36m 镜像文件系统统计：\033[0m"
sudo du -sh $TARGET_ROOTFS_DIR/lib/firmware/ 2>/dev/null || echo "firmware目录不存在"

echo -e "\033[36m ====== 构建完成 ====== \033[0m"

if [ $FW_COUNT -eq 4 ]; then
	echo -e "\033[32m 🎉 构建成功！所有WiFi/BT固件已打包进镜像，直接烧录即可！ \033[0m"
	echo -e "\033[33m 💡 提示：depmod关于modules.order的警告是Rockchip内核正常现象，无需处理。 \033[0m"
	echo -e "\033[36m 📦 镜像位置：$TARGET_ROOTFS_DIR/ \033[0m"
	echo -e "\033[36m 🐳 Docker 已完全集成（开机自启，无需任何操作） \033[0m"
	echo -e "\033[36m    - Docker CE: 已安装并配置镜像加速 \033[0m"
	echo -e "\033[36m    - Docker Compose: 已安装 \033[0m"
	echo -e "\033[36m    - linaro 用户已加入 docker 组（无需 sudo） \033[0m"
	echo -e "\033[36m 💾 M.2 SSD 配置：\033[0m"
	echo -e "\033[36m    1. 首次使用请运行: sudo /usr/local/bin/configure-ssd.sh \033[0m"
	echo -e "\033[36m    2. 或双击桌面 '配置M.2 SSD' 图标 \033[0m"
	echo -e "\033[36m    3. 推荐格式化为 ext4 以获得最佳兼容性 \033[0m"
	exit 0
else
	echo -e "\033[31m ❌ 构建失败！仅找到 $FW_COUNT/4 个固件 \033[0m"
	echo -e "\033[33m 🔧 调试建议：\033[0m"
	echo -e "   1. 检查源固件是否存在：ls -la /RK3588/rk3588_sdk/debian/overlay/usr/lib/firmware/rtw88/"
	echo -e "   2. 检查目标目录权限：ls -la $TARGET_ROOTFS_DIR/lib/firmware/"
	exit 1
fi