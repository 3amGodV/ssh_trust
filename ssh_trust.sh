#!/bin/bash
# CentOS7 SSH互信配置脚本（交互式增强版）
# 功能：1. 动态输入主机信息 2. 自动接受密钥 3. 灵活控制密码登录

# 颜色定义
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'
BLUE='\033[34m'; CYAN='\033[36m'; NC='\033[0m'

# 检查root权限
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}错误：此脚本必须使用root用户执行！${NC}"
    exit 1
fi

# 交互式输入主机信息
echo -e "${CYAN}=== SSH互信配置向导 ===${NC}"
read -p "请输入需要配置的主机数量: " HOST_COUNT

HOSTS=()
for ((i=1; i<=$HOST_COUNT; i++)); do
    while true; do
        read -p "请输入第${i}台主机的IP地址: " IP
        if [[ $IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            HOSTS+=("$IP")
            break
        else
            echo -e "${RED}错误：请输入有效的IP地址${NC}"
        fi
    done
done

# 交互式输入密码
while true; do
    read -s -p "请输入所有主机的root密码: " ROOT_PASSWORD
    echo
    read -s -p "请再次确认密码: " PASSWORD_CONFIRM
    echo
    
    if [ "$ROOT_PASSWORD" = "$PASSWORD_CONFIRM" ]; then
        break
    else
        echo -e "${RED}错误：两次输入的密码不一致！${NC}"
    fi
done

# 配置选项
echo -e "\n${CYAN}=== 配置选项 ===${NC}"
read -p "SSH端口（默认22）: " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

read -p "是否临时允许密码登录？（yes/no, 默认no）: " TEMP_PASSWORD_LOGIN
TEMP_PASSWORD_LOGIN=${TEMP_PASSWORD_LOGIN:-no}

# 安装必要组件
echo -e "\n${CYAN}[1/5] 正在检查环境...${NC}"
if ! command -v sshpass &> /dev/null; then
    echo -e "${YELLOW}正在安装sshpass...${NC}"
    yum install -y epel-release > /dev/null && yum install -y sshpass > /dev/null || {
        echo -e "${RED}sshpass安装失败！${NC}"
        exit 1
    }
fi

# 生成主控机密钥
echo -e "${CYAN}[2/5] 正在准备密钥...${NC}"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
[ ! -f ~/.ssh/id_rsa ] && {
    ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa > /dev/null || {
        echo -e "${RED}密钥生成失败！${NC}"
        exit 1
    }
}

# 配置SSH连接函数（自动接受密钥）
ssh_auto() {
    sshpass -p "$ROOT_PASSWORD" ssh -o StrictHostKeyChecking=no \
                                   -o UserKnownHostsFile=/dev/null \
                                   -p $SSH_PORT root@$1 "$2"
}

scp_auto() {
    sshpass -p "$ROOT_PASSWORD" scp -o StrictHostKeyChecking=no \
                                   -o UserKnownHostsFile=/dev/null \
                                   -P $SSH_PORT $1 root@$2:$3
}

# 主机配置函数
configure_host() {
    local host=$1
    echo -e "\n${BLUE}▶ 正在处理 ${host}${NC}"
    
    # 检查连通性
    echo -n "检查连通性..."
    if ! ping -c 1 -W 1 $host &> /dev/null; then
        echo -e "${RED}失败${NC}"
        return 1
    fi
    echo -e "${GREEN}通过${NC}"

    # 临时允许密码登录
    if [ "$TEMP_PASSWORD_LOGIN" = "yes" ]; then
        echo -n "配置临时密码登录..."
        ssh_auto $host "
            sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
            sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
            systemctl restart sshd
        " && echo -e "${GREEN}完成${NC}" || {
            echo -e "${RED}失败${NC}"
            return 1
        }
    fi

    # 确保SSH服务正常
    echo -n "检查SSH服务..."
    ssh_auto $host "
        yum install -y openssh-server openssh-clients >/dev/null 2>&1
        systemctl enable --now sshd >/dev/null 2>&1
    " && echo -e "${GREEN}正常${NC}" || {
        echo -e "${RED}异常${NC}"
        return 1
    }

    # 生成密钥对
    echo -n "生成密钥对..."
    ssh_auto $host "
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        [ ! -f ~/.ssh/id_rsa ] && ssh-keygen -t rsa -b 4096 -N \"\" -f ~/.ssh/id_rsa >/dev/null 2>&1
    " && echo -e "${GREEN}完成${NC}" || {
        echo -e "${RED}失败${NC}"
        return 1
    }

    # 收集公钥
    echo -n "收集公钥..."
    scp_auto "$host:~/.ssh/id_rsa.pub" "/tmp/$host.pub" && {
        echo -e "${GREEN}成功${NC}"
        return 0
    } || {
        echo -e "${RED}失败${NC}"
        return 1
    }
}

# 主流程
echo -e "\n${CYAN}[3/5] 正在收集公钥...${NC}"
ALL_PUB_KEYS=()
for host in "${HOSTS[@]}"; do
    if configure_host $host; then
        ALL_PUB_KEYS+=("/tmp/$host.pub")
    else
        echo -e "${YELLOW}警告：将跳过主机 ${host}${NC}"
    fi
done

# 合并公钥
echo -e "\n${CYAN}[4/5] 创建授权文件...${NC}"
cat "${ALL_PUB_KEYS[@]}" 2>/dev/null | sort -u > /tmp/authorized_keys
if [ ! -s /tmp/authorized_keys ]; then
    echo -e "${RED}错误：未收集到有效公钥，请检查主机连通性和密码是否正确！${NC}"
    exit 1
fi
echo -e "已收集 ${#ALL_PUB_KEYS[@]}/${#HOSTS[@]} 台主机的公钥"

# 分发配置
echo -e "\n${CYAN}[5/5] 分发配置...${NC}"
SUCCESS_COUNT=0
for host in "${HOSTS[@]}"; do
    echo -e "\n${BLUE}▶ 正在配置 ${host}${NC}"
    echo -n "上传授权文件..."
    scp_auto "/tmp/authorized_keys" "$host" "~/.ssh/" && {
        echo -e "${GREEN}成功${NC}"
        echo -n "配置SSH服务..."
        ssh_auto $host "
            chmod 600 ~/.ssh/authorized_keys
            sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/g' /etc/ssh/sshd_config
            systemctl restart sshd
        " && {
            echo -e "${GREEN}成功${NC}"
            ((SUCCESS_COUNT++))
        } || echo -e "${RED}失败${NC}"
    } || echo -e "${RED}失败${NC}"
done

# 安全清理
rm -f /tmp/*.pub /tmp/authorized_keys
unset ROOT_PASSWORD PASSWORD_CONFIRM

# 结果报告
echo -e "\n${CYAN}=== 执行结果 ===${NC}"
echo -e "成功配置: ${GREEN}${SUCCESS_COUNT}${NC}/${#HOSTS[@]} 台主机"
echo -e "当前密码登录状态: ${YELLOW}${TEMP_PASSWORD_LOGIN}${NC}"

if [ "$TEMP_PASSWORD_LOGIN" = "yes" ]; then
    echo -e "\n${YELLOW}安全提醒：${NC}"
    echo "1. 您已启用密码登录，建议完成后手动禁用："
    echo "   sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/g' /etc/ssh/sshd_config"
    echo "   systemctl restart sshd"
fi

echo -e "\n${GREEN}✔ 配置完成！测试命令：ssh -p ${SSH_PORT} root@${HOSTS[0]}${NC}"