#!/bin/bash
# prepare-docker.sh - 在构建前准备所有 Docker 组件

DOCKER_DEB_DIR="/RK3588/rk3588_sdk/debian/packages/arm64/docker"
OVERLAY_BIN_DIR="/RK3588/rk3588_sdk/debian/overlay/usr/local/bin"

# 1. 创建目录
mkdir -p "$DOCKER_DEB_DIR"
mkdir -p "$OVERLAY_BIN_DIR"

# 2. 下载 Docker deb 包（如果不存在）
cd "$DOCKER_DEB_DIR"
if [ ! -f "containerd.io_1.6.9-1_arm64.deb" ]; then
    echo "下载 Docker deb 包..."
    wget -c https://mirrors.aliyun.com/docker-ce/linux/debian/dists/bullseye/pool/stable/arm64/containerd.io_1.6.9-1_arm64.deb
    wget -c https://mirrors.aliyun.com/docker-ce/linux/debian/dists/bullseye/pool/stable/arm64/docker-ce-cli_20.10.23~3-0~debian-bullseye_arm64.deb
    wget -c https://mirrors.aliyun.com/docker-ce/linux/debian/dists/bullseye/pool/stable/arm64/docker-ce_20.10.23~3-0~debian-bullseye_arm64.deb
fi

# 3. 下载 Docker Compose 到 overlay（如果不存在）
cd "$OVERLAY_BIN_DIR"
if [ ! -f "docker-compose" ]; then
    echo "下载 Docker Compose..."
    wget -c https://github.com/docker/compose/releases/download/v2.24.2/docker-compose-linux-arm64 -O docker-compose
    chmod +x docker-compose
fi

echo "Docker 组件准备完成！"