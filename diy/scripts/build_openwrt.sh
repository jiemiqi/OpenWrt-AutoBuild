
#!/bin/bash

set -e

echo "#### openwrt 自动构建脚本 ####"
READY_FLAG="$HOME/.openwrt_ready"
OPENWRT_DIR="$HOME/openwrt"
FILES_DIR="$OPENWRT_DIR/files"

# 允许重置
if [ "$1" == "--reset" ]; then
    echo "🔁 重置构建环境..."
    rm -f "$READY_FLAG"
    rm -rf "$OPENWRT_DIR"
    echo "✅ 已重置"
fi

# 如果前置步骤已完成，则跳过
if [ -f "$READY_FLAG" ]; then
    echo "⚠️ 已检测到前置步骤已完成，跳过 1~7 步骤..."
    echo "如需强制重新构建运行bash build_openwrt.sh --reset"
else
    echo "### 1. 克隆 Openwrt 源码 ###"
    git clone --branch openwrt-24.10 https://github.com/immortalwrt/immortalwrt.git "$OPENWRT_DIR"

    echo "### 2. 添加自定义软件包 ###"
    cd "$OPENWRT_DIR/package"
    #git clone --depth=1 https://github.com/NueXini/NueXini_Packages
    git clone --depth=1 https://github.com/rufengsuixing/luci-app-adguardhome.git
    git clone --depth=1 https://github.com/8680/openwrt-lolcat
    git clone --depth=1 https://github.com/nikkinikki-org/OpenWrt-nikki
    git clone -b dev --depth=1 https://github.com/vernesong/OpenClash.git
    mkdir -p "$FILES_DIR/usr/bin"
    wget https://raw.githubusercontent.com/8680/OpenWrt-AutoBuild/master/diy/data/neofetch/neofetch -O "$FILES_DIR/usr/bin/neofetch" || echo "警告：neofetch 下载失败"
    chmod 775 "$FILES_DIR/usr/bin/neofetch"

    echo "### 3. 更新和安装 feeds ###"
FEEDS_CONF="$OPENWRT_DIR/feeds.conf.default"
cat > "$FEEDS_CONF" << EOF
src-git packages https://github.com/immortalwrt/packages.git;openwrt-24.10
src-git luci https://github.com/immortalwrt/luci.git;openwrt-24.10
src-git routing https://github.com/openwrt/routing.git;openwrt-24.10
src-git telephony https://github.com/openwrt/telephony.git;openwrt-24.10
EOF
    cd "$OPENWRT_DIR"
    ./scripts/feeds update -a
    ./scripts/feeds install -a

    echo "### 4. 应用自定义配置 ###"
    PASSWD_FILE="$OPENWRT_DIR/package/base-files/files/etc/passwd"
    [ -f "$PASSWD_FILE" ] && sed -i 's/\/bin\/ash/\/usr\/bin\/zsh/g' "$PASSWD_FILE"
    CONFIG_GENERATE_FILE="$OPENWRT_DIR/package/base-files/files/bin/config_generate"
    if [ -f "$CONFIG_GENERATE_FILE" ]; then
        # 使用 O2 级别的优化
        sed -i 's/Os/O2/g' include/target.mk
        # 移除 SNAPSHOT 标签
        sed -i 's,-SNAPSHOT,,g' include/version.mk
        sed -i 's,-SNAPSHOT,,g' package/base-files/image-config.in
        sed -i '/CONFIG_BUILDBOT/d' include/feeds.mk
        sed -i 's/;)\s*\\/; \\/' include/feeds.mk
        # Nginx
        sed -i "s/large_client_header_buffers 2 1k/large_client_header_buffers 4 32k/g" feeds/packages/net/nginx-util/files/uci.conf.template
        sed -i "s/client_max_body_size 128M/client_max_body_size 2048M/g" feeds/packages/net/nginx-util/files/uci.conf.template
        sed -i '/client_max_body_size/a\\tclient_body_buffer_size 8192M;' feeds/packages/net/nginx-util/files/uci.conf.template
        sed -i '/client_max_body_size/a\\tserver_names_hash_bucket_size 128;' feeds/packages/net/nginx-util/files/uci.conf.template
        sed -i '/ubus_parallel_req/a\        ubus_script_timeout 600;' feeds/packages/net/nginx/files-luci-support/60_nginx-luci-support
        sed -ri "/luci-webui.socket/i\ \t\tuwsgi_send_timeout 600\;\n\t\tuwsgi_connect_timeout 600\;\n\t\tuwsgi_read_timeout 600\;" feeds/packages/net/nginx/files-luci-support/luci.locations
        sed -ri "/luci-cgi_io.socket/i\ \t\tuwsgi_send_timeout 600\;\n\t\tuwsgi_connect_timeout 600\;\n\t\tuwsgi_read_timeout 600\;" feeds/packages/net/nginx/files-luci-support/luci.locations
        # uwsgi
        sed -i 's,procd_set_param stderr 1,procd_set_param stderr 0,g' feeds/packages/net/uwsgi/files/uwsgi.init
        sed -i 's,buffer-size = 10000,buffer-size = 131072,g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
        sed -i 's,logger = luci,#logger = luci,g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
        sed -i '$a cgi-timeout = 600' feeds/packages/net/uwsgi/files-luci-support/luci-*.ini
        sed -i 's/threads = 1/threads = 2/g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
        sed -i 's/processes = 3/processes = 4/g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
        sed -i 's/cheaper = 1/cheaper = 2/g' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
        #golang 
        rm -rf feeds/packages/lang/golang
        git clone https://github.com/sbwml/packages_lang_golang -b 24.x feeds/packages/lang/golang
        #修改后台ip地址
        sed -i 's/192.168.1.1/192.168.0.22/g' "$CONFIG_GENERATE_FILE"
        # 修改NTP 服务器
        sed -i "s/set system.ntp.enable_server='0'/set system.ntp.enable_server='1'/g" "$CONFIG_GENERATE_FILE"
        #修改hostname
        sed -i "s/\(set system.@system\[-1\].hostname='\)[^']*'/\1OpenWrt'/" "$CONFIG_GENERATE_FILE"
        #ttyd免帐号登录
        sed -i 's/\/bin\/login/\/bin\/login -f root/' feeds/packages/utils/ttyd/files/ttyd.config
    fi

    echo "### 5. 设置 Clash 核心 ###"
    OPENCLASH_CORE_DIR="$FILES_DIR/etc/openclash/core"
    mkdir -p "$OPENCLASH_CORE_DIR"
    cd "$OPENCLASH_CORE_DIR"

    CLASH_DEV_URL="https://github.com/vernesong/OpenClash/releases/download/Clash/clash-linux-amd64.tar.gz"
    CLASH_TUN_URL="https://raw.githubusercontent.com/vernesong/OpenClash/refs/heads/core/master/premium/clash-linux-amd64-2023.08.17-13-gdcc8d87.gz"

    echo "正在获取 Clash Meta 最新版本..."
    # LATEST_META_VERSION=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    # if [ -z "$LATEST_META_VERSION" ]; then
    #     echo "❌ 获取 Clash Meta 最新版本失败，退出"; exit 1
    # fi
    CLASH_META_URL="https://github.com/MetaCubeX/mihomo/releases/download/v1.19.20/mihomo-linux-amd64-v1.19.20.gz"

    wget -qO- "$CLASH_DEV_URL" | tar xOvz > clash && chmod +x clash
    wget -qO- "$CLASH_TUN_URL" | gunzip -c > clash_tun && chmod +x clash_tun
    wget -qO- "$CLASH_META_URL" | gunzip -c > clash_meta && chmod +x clash_meta

    wget -qO GeoSite.dat "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"
    wget -qO GeoIP.dat "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoIP.dat"
    wget -qO geoip.metadb "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"

    echo "### 6. 设置终端工具 (oh-my-zsh) ###"
    mkdir -p "$FILES_DIR/root"
    cd "$FILES_DIR/root"
    git clone https://github.com/robbyrussell/oh-my-zsh .oh-my-zsh || echo "警告：克隆 oh-my-zsh 失败"
    git clone https://github.com/zsh-users/zsh-autosuggestions .oh-my-zsh/custom/plugins/zsh-autosuggestions
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git .oh-my-zsh/custom/plugins/zsh-syntax-highlighting
    git clone https://github.com/zsh-users/zsh-completions .oh-my-zsh/custom/plugins/zsh-completions
    wget https://raw.githubusercontent.com/8680/OpenWrt-AutoBuild/master/diy/data/zsh/.zshrc -O .zshrc

    echo "### 7. 应用构建配置 ###"
    wget https://raw.githubusercontent.com/jiemiqi/OpenWrt-AutoBuild/master/diy/configs/x86.config -O "$OPENWRT_DIR/.config"

    touch "$READY_FLAG"
    echo "✅ 前置步骤完成。下次将自动跳过这些操作。"
fi

cd "$OPENWRT_DIR"

echo "### 8. 是否开始构建固件？ ###"
read -p "是否开始构建固件？(yes/no): " confirm
if [[ "$confirm" != [yY] && "$confirm" != [yY][eE][sS] ]]; then
    cd "$OPENWRT_DIR"
    echo "⚠️ 构建已取消，下次运行将跳过前置步骤，已切换到源码目录：$OPENWRT_DIR"
    echo "如需自行配置插件应用 请运行make menuconfig"
    exec bash
    exit 0
fi

echo "### 9. 下载源码 ###"
make download -j$(nproc)

echo "### 10. 生成 defconfig ###"
make defconfig

echo "### 11. 开始构建 (使用 $(nproc) 线程) ###"
make V=s -j$(nproc)

echo "🎉 构建完成！固件已生成。"
