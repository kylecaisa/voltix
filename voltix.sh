#!/bin/bash
# Filename: voltix.sh
# Description: Voltix节点全功能管理工具（包含Chromium环境部署）

set -euo pipefail

# ---------- 全局常量定义 ----------
readonly VERSION="1358570"  # 必须在此处正确定义
readonly CHROMIUM_URL="https://commondatastorage.googleapis.com/chromium-browser-snapshots/Linux_x64/${VERSION}/chrome-linux.zip"
readonly DRIVER_URL="https://commondatastorage.googleapis.com/chromium-browser-snapshots/Linux_x64/${VERSION}/chromedriver_linux64.zip"
readonly INSTALL_DIR="/opt/chromium"
readonly BIN_DIR="/usr/local/bin"

# ---------- 颜色定义 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
# 路径配置
VOLTIX_DIR="$HOME/voltix"
TMUX_SESSION="voltix"
PHANTOM_KEYS="$VOLTIX_DIR/phantomKeys.txt"

# 环境检查函数
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：请使用root权限运行此脚本${NC}"
        exit 1
    fi
}

# Chromium安装函数
install_chromium() {
    echo -e "${GREEN}>>> 开始安装Chromium${NC}"
    
    # 阶段1: 清理旧版本
    echo -e "${YELLOW}[1/6] 清理旧版本...${NC}"
    sudo snap remove chromium --purge 2>/dev/null || true
    sudo apt-get purge chromium* -y 2>/dev/null || true
    sudo rm -rf "${INSTALL_DIR}" "${BIN_DIR}/chromium-browser" "${BIN_DIR}/chromedriver"
    sudo apt-get autoremove -y

    # 阶段2: 安装系统依赖
    echo -e "${YELLOW}[2/6] 安装系统依赖...${NC}"
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        wget unzip xdg-utils \
        libgbm1 libgl1-mesa-glx libnss3 libxss1 libasound2 \
        libatk1.0-0 libcups2 libdrm2 libxkbcommon0 libgtk-3-0 \
        libdrm-amdgpu1 libminizip1 libwayland-client0 libwayland-server0

    # 阶段3: 下载组件（使用全局常量）
    echo -e "${YELLOW}[3/6] 下载组件...${NC}"
    mkdir -p /tmp/chromium-install
    cd /tmp/chromium-install

    wget -q "${CHROMIUM_URL}" -O chrome-linux.zip || {
        echo -e "${RED}Chromium下载失败${NC}"; exit 1
    }

    wget -q "${DRIVER_URL}" -O chromedriver_linux64.zip || {
        echo -e "${RED}ChromeDriver下载失败${NC}"; exit 1
    }

    # 阶段4: 解压安装
    echo -e "${YELLOW}[4/6] 解压文件...${NC}"
    sudo mkdir -p "${INSTALL_DIR}"
    sudo unzip -q chrome-linux.zip -d "${INSTALL_DIR}"
    sudo unzip -q chromedriver_linux64.zip -d "${INSTALL_DIR}"
    
    # 修复lib目录
    sudo mkdir -p "${INSTALL_DIR}/chrome-linux/lib"
    sudo ln -s /usr/lib/x86_64-linux-gnu/libgbm.so.1 "${INSTALL_DIR}/chrome-linux/lib/libgbm.so"

    # 阶段5: 配置环境
    echo -e "${YELLOW}[5/6] 配置系统路径...${NC}"
    sudo ln -sf "${INSTALL_DIR}/chrome-linux/chrome" "${BIN_DIR}/chromium-browser"
    sudo ln -sf "${INSTALL_DIR}/chromedriver_linux64/chromedriver" "${BIN_DIR}/chromedriver"
    sudo chmod +x "${INSTALL_DIR}/chrome-linux/chrome" "${INSTALL_DIR}/chromedriver_linux64/chromedriver"
    
    # 更新动态链接库
    sudo ldconfig

    # 阶段6: 验证安装
    echo -e "${YELLOW}[6/6] 验证安装...${NC}"
    if ! ldd "${INSTALL_DIR}/chrome-linux/chrome" | grep -q 'not found'; then
        echo -e "${GREEN}✓ 依赖完整性验证通过${NC}"
    else
        echo -e "${RED}✗ 存在未解决的依赖项："
        ldd "${INSTALL_DIR}/chrome-linux/chrome" | grep 'not found'
        exit 1
    fi

    # 清理临时文件
    rm -rf /tmp/chromium-install

    echo -e "\n${GREEN}安装成功！运行以下命令测试：${NC}"
    echo "chromium-browser --version"
}

# 选项2: 安装节点
setup_node() {
    mkdir -p "$VOLTIX_DIR"
    
    # 克隆仓库
    if [[ ! -d "$VOLTIX_DIR/.git" ]]; then
        echo -e "${BLUE}克隆 Voltix 仓库...${NC}"
        git clone https://github.com/kylecaisa/voltix.git "$VOLTIX_DIR" || {
            echo -e "${RED}仓库克隆失败${NC}"
            exit 1
        }
    fi
        # 交互式助记词输入（强制重新输入）
    input_mnemonic() {
        echo -e "${YELLOW}>>>> 请按顺序输入12/24个助记词（用空格分隔）<<<<${NC}"
        local mnemonic
        while true; do
            echo -ne "${BLUE}请输入助记词：${NC}"
            read -er
            mnemonic=$REPLY
            count=$(echo "$mnemonic" | wc -w)
            [[ $count -eq 12 || $count -eq 24 ]] && break
            echo -e "${RED}错误：需要12或24个单词，当前输入了$count个${NC}"
        done
        echo "$mnemonic" > "$PHANTOM_KEYS"
        chmod 400 "$PHANTOM_KEYS"
    }

    # 即使文件存在也强制输入
    if [[ -f "$PHANTOM_KEYS" ]]; then
        echo -e "${YELLOW}检测到已有助记词文件：$PHANTOM_KEYS${NC}"
        tail -n 1 "$PHANTOM_KEYS" | awk '{print "当前保存的助记词："$0}'
        read -p "是否重新输入？(y/N) " -n 1 -r
        [[ $REPLY =~ ^[Yy]$ ]] && input_mnemonic
    else
        input_mnemonic
    fi

    # 处理Tmux会话冲突（确保只处理指定会话）
    echo -e "${BLUE}配置 Tmux 会话...${NC}"
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        echo -e "${YELLOW}检测到已有会话 '$TMUX_SESSION'，正在清理..."
        tmux kill-session -t "$TMUX_SESSION"
        sleep 1
    fi

    # 安装依赖
    echo -e "${BLUE}安装项目依赖...${NC}"
    cd "$VOLTIX_DIR"
    if ! npm install > npm_install.log 2>&1; then
        echo -e "${RED}依赖安装失败，最后20行日志：${NC}"
        tail -n 20 npm_install.log
        exit 1
    fi

    # 启动节点进程
    echo -e "${BLUE}启动节点进程...${NC}"
    tmux new-session -d -s "$TMUX_SESSION" "cd $VOLTIX_DIR && node run.js"
    echo -e "${GREEN}节点已在 Tmux 会话 [${TMUX_SESSION}] 中启动${NC}"
    echo -e "查看实时日志：${YELLOW}tmux attach -t ${TMUX_SESSION}${NC}"
    echo -e "（退出日志视图按组合键：${YELLOW}Ctrl+B D${NC}）"

    # 快速检查初始化状态
    echo -e "\n${YELLOW}正在验证节点状态...${NC}"
    sleep 5  # 给节点预留启动时间
    if grep -q "Wallet initialized" "$VOLTIX_DIR/node.log"; then
        echo -e "${GREEN}✔ 节点初始化成功${NC}"
        grep "Current points" "$VOLTIX_DIR/node.log"
    else
        echo -e "${YELLOW}节点启动中，请稍后手动检查日志：${NC}"
        echo -e "日志文件：${YELLOW}$VOLTIX_DIR/node.log${NC}"
        echo -e "实时查看：${YELLOW}tmux attach -t ${TMUX_SESSION}${NC}"
    fi
}

# 选项3: 查看节点
view_node() {
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        echo -e "${GREEN}正在进入节点控制台（按 Ctrl+B D 返回）...${NC}"
        sleep 1
        tmux attach -t "$TMUX_SESSION"
    else
        echo -e "${RED}错误：未找到运行中的节点会话${NC}"
        echo -e "可尝试重新启动节点：${YELLOW}运行安装选项${NC}"
        exit 1
    fi
}

# 主菜单显示函数
show_menu() {
    clear
    echo -e "${GREEN}"
    echo "====================================="
    echo "     Voltix节点管理工具 v2.0      "
    echo "====================================="
    echo -e "${NC}"
    echo "1. 安装Chromium运行环境"
    echo "2. 安装并启动节点"
    echo "3. 查看节点运行状态"
    echo -e "${RED}q. 退出${NC}"
    echo "-------------------------------------"
}

# 菜单处理逻辑
while true; do
    show_menu
    read -p "请选择操作 (1-3/q): " choice
    case $choice in
        1) install_chromium ;;
        2) setup_node ;;
        3) view_node ;;
        q|Q) echo -e "${BLUE}已退出${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
    esac
    read -n 1 -s -p "按任意键返回菜单..."
done