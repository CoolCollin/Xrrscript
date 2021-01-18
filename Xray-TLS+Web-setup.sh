#!/bin/bash

#安装选项
nginx_version="nginx-1.19.6"
openssl_version="openssl-openssl-3.0.0-alpha10"
nginx_prefix="/usr/local/nginx"
nginx_config="${nginx_prefix}/conf.d/xray.conf"
nginx_service="/etc/systemd/system/nginx.service"
php_version="php-8.0.1"
php_prefix="/usr/local/php"
nextcloud_url="https://download.nextcloud.com/server/prereleases/nextcloud-21.0.0beta6.zip"
xray_config="/usr/local/etc/xray/config.json"
temp_dir="/temp_install_update_xray_tls_web"
nginx_is_installed=""
php_is_installed=""
xray_is_installed=""
is_installed=""
update=""
if [ -e /etc/nginx/conf.d/v2ray.conf ] || [ -e /etc/nginx/conf.d/xray.conf ]; then
    nginx_prefix="/etc/nginx"
    nginx_config="${nginx_prefix}/conf.d/xray.conf"
fi

#配置信息
unset domain_list
unset domainconfig_list
unset pretend_list
#Xray-TCP-TLS使用的协议，0代表禁用，1代表VLESS
protocol_1=""
#Xray-WS-TLS使用的协议，0代表禁用，1代表VLESS，2代表VMess
protocol_2=""
path=""
xid_1=""
xid_2=""

#系统信息
release=""
systemVersion=""
redhat_package_manager=""
redhat_version=""
mem_ok=""
[[ -z "$BASH_SOURCE" ]] && file_script="" || file_script="$(dirname "$BASH_SOURCE")/$(basename "$BASH_SOURCE")"

#定义几个颜色
purple()                           #基佬紫
{
    echo -e "\033[35;1m${@}\033[0m"
}
tyblue()                           #天依蓝
{
    echo -e "\033[36;1m${@}\033[0m"
}
green()                            #水鸭青
{
    echo -e "\033[32;1m${@}\033[0m"
}
yellow()                           #鸭屎黄
{
    echo -e "\033[33;1m${@}\033[0m"
}
red()                              #姨妈红
{
    echo -e "\033[31;1m${@}\033[0m"
}

if [ "$EUID" != "0" ]; then
    red "请用root用户运行此脚本！！"
    exit 1
fi
if [[ ! -f '/etc/os-release' ]]; then
    red "系统版本太老，Xray官方脚本不支持"
    exit 1
fi
if [[ -f /.dockerenv ]] || grep -q 'docker\|lxc' /proc/1/cgroup && [[ "$(type -P systemctl)" ]]; then
    true
elif [[ -d /run/systemd/system ]] || grep -q systemd <(ls -l /sbin/init); then
    true
else
    red "仅支持使用systemd的系统！"
    exit 1
fi
if [[ ! -d /dev/shm ]]; then
    red "/dev/shm不存在，不支持的系统"
    exit 1
fi
if [ "$(cat /proc/meminfo | grep 'MemTotal' | awk '{print $3}' | tr [:upper:] [:lower:])" == "kb" ]; then
    if [ "$(cat /proc/meminfo | grep 'MemTotal' | awk '{print $2}')" -le 400000 ]; then
        mem_ok=0
    else
        mem_ok=1
    fi
else
    mem_ok=2
fi
([ -e $nginx_config ] || [ -e $nginx_prefix/conf.d/v2ray.conf ]) && nginx_is_installed=1 || nginx_is_installed=0
[ -e ${php_prefix}/php-fpm.service.default ] && php_is_installed=1 || php_is_installed=0
[ -e /usr/local/bin/xray ] && xray_is_installed=1 || xray_is_installed=0
([ $xray_is_installed -eq 1 ] && [ $nginx_is_installed -eq 1 ]) && is_installed=1 || is_installed=0

check_important_dependence_installed()
{
    if [ $release == "ubuntu" ] || [ $release == "other-debian" ]; then
        if dpkg -s $1 > /dev/null 2>&1; then
            apt-mark manual $1
        elif ! apt -y --no-install-recommends install $1; then
            apt update
            if ! apt -y --no-install-recommends install $1; then
                red "重要组件\"$1\"安装失败！！"
                exit 1
            fi
        fi
    else
        if rpm -q $2 > /dev/null 2>&1; then
            if [ "$redhat_package_manager" == "dnf" ]; then
                dnf mark install $2
            else
                yumdb set reason user $2
            fi
        elif ! $redhat_package_manager -y install $2; then
            red "重要组件\"$2\"安装失败！！"
            exit 1
        fi
    fi
}
version_ge()
{
    test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" == "$1"
}
#获取系统信息
get_system_info()
{
    if [[ "$(type -P apt)" ]]; then
        if [[ "$(type -P dnf)" ]] || [[ "$(type -P yum)" ]]; then
            red "同时存在apt和yum/dnf"
            red "不支持的系统！"
            exit 1
        fi
        release="other-debian"
        redhat_package_manager="true"
    elif [[ "$(type -P dnf)" ]]; then
        release="other-redhat"
        redhat_package_manager="dnf"
    elif [[ "$(type -P yum)" ]]; then
        release="other-redhat"
        redhat_package_manager="yum"
    else
        red "不支持的系统或apt/yum/dnf缺失"
        exit 1
    fi
    check_important_dependence_installed lsb-release redhat-lsb-core
    if lsb_release -a 2>/dev/null | grep -qi "ubuntu"; then
        release="ubuntu"
    elif lsb_release -a 2>/dev/null | grep -qi "centos"; then
        release="centos"
    elif lsb_release -a 2>/dev/null | grep -qi "fedora"; then
        release="fedora"
    fi
    systemVersion=$(lsb_release -r -s)
    if [ $release == "fedora" ]; then
        if version_ge $systemVersion 28; then
            redhat_version=8
        elif version_ge $systemVersion 19; then
            redhat_version=7
        elif version_ge $systemVersion 12; then
            redhat_version=6
        else
            redhat_version=5
        fi
    else
        redhat_version=$systemVersion
    fi
}

#检查Nginx是否已通过apt/dnf/yum安装
check_nginx_installed_system()
{
    if [[ ! -f /usr/lib/systemd/system/nginx.service ]] && [[ ! -f /lib/systemd/system/nginx.service ]]; then
        return 0
    fi
    red    "------------检测到Nginx已安装，并且会与此脚本冲突------------"
    yellow " 如果您不记得之前有安装过Nginx，那么可能是使用别的一键脚本时安装的"
    yellow " 建议使用纯净的系统运行此脚本"
    echo
    local choice=""
    while [ "$choice" != "y" -a "$choice" != "n" ]
    do
        tyblue "是否尝试卸载？(y/n)"
        read choice
    done
    if [ $choice == "n" ]; then
        exit 0
    fi
    apt -y purge nginx
    $redhat_package_manager -y remove nginx
    if [[ ! -f /usr/lib/systemd/system/nginx.service ]] && [[ ! -f /lib/systemd/system/nginx.service ]]; then
        return 0
    fi
    red "卸载失败！"
    yellow "请尝试更换系统，建议使用Ubuntu最新版系统"
    green  "欢迎进行Bug report(https://github.com/kirin10000/Xray-script/issues)，感谢您的支持"
    exit 1
}

#检查SELinux
check_SELinux()
{
    turn_off_selinux()
    {
        check_important_dependence_installed selinux-utils libselinux-utils
        setenforce 0
        sed -i 's/^[ \t]*SELINUX[ \t]*=[ \t]*enforcing[ \t]*$/SELINUX=disabled/g' /etc/sysconfig/selinux
        $redhat_package_manager -y remove libselinux-utils
        apt -y purge selinux-utils
    }
    if getenforce 2>/dev/null | grep -wqi Enforcing || grep -Eq '^[ '$'\t]*SELINUX[ '$'\t]*=[ '$'\t]*enforcing[ '$'\t]*$' /etc/sysconfig/selinux 2>/dev/null; then
        yellow "检测到SELinux开启，脚本可能无法正常运行"
        choice=""
        while [[ "$choice" != "y" && "$choice" != "n" ]]
        do
            tyblue "尝试关闭SELinux?(y/n)"
            read choice
        done
        if [ $choice == y ]; then
            turn_off_selinux
        else
            exit 0
        fi
    fi
}

#检查80端口和443端口是否被占用
check_port()
{
    local xray_status=0
    local nginx_status=0
    systemctl -q is-active xray && xray_status=1 && systemctl stop xray
    systemctl -q is-active nginx && nginx_status=1 && systemctl stop nginx
    ([ $xray_status -eq 1 ] || [ $nginx_status -eq 1 ]) && sleep 2s
    local check_list=('80' '443')
    local i
    for i in ${!check_list[@]}
    do
        if netstat -tuln | awk '{print $4}'  | awk -F : '{print $NF}' | grep -E "^[0-9]+$" | grep -wq "${check_list[$i]}"; then
            red "${check_list[$i]}端口被占用！"
            yellow "请用 lsof -i:${check_list[$i]} 命令检查"
            exit 1
        fi
    done
    [ $xray_status -eq 1 ] && systemctl start xray
    [ $nginx_status -eq 1 ] && systemctl start nginx
}

#将域名列表转化为一个数组
get_all_domains()
{
    unset all_domains
    for ((i=0;i<${#domain_list[@]};i++))
    do
        [ ${domainconfig_list[i]} -eq 1 ] && all_domains+=("www.${domain_list[i]}")
        all_domains+=("${domain_list[i]}")
    done
}

#配置sshd
check_ssh_timeout()
{
    if grep -q "#This file has been edited by Xray-TLS-Web-setup-script" /etc/ssh/sshd_config; then
        return 0
    fi
    echo -e "\n\n\n"
    tyblue "------------------------------------------"
    tyblue " 安装可能需要比较长的时间(5-40分钟)"
    tyblue " 如果中途断开连接将会很麻烦"
    tyblue " 设置ssh连接超时时间将有效降低断连可能性"
    tyblue "------------------------------------------"
    choice=""
    while [ "$choice" != "y" -a "$choice" != "n" ]
    do
        tyblue "是否设置ssh连接超时时间？(y/n)"
        read choice
    done
    if [ $choice == y ]; then
        sed -i '/^[ \t]*ClientAliveInterval[ \t]/d' /etc/ssh/sshd_config
        sed -i '/^[ \t]*ClientAliveCountMax[ \t]/d' /etc/ssh/sshd_config
        echo >> /etc/ssh/sshd_config
        echo "ClientAliveInterval 30" >> /etc/ssh/sshd_config
        echo "ClientAliveCountMax 60" >> /etc/ssh/sshd_config
        echo "#This file has been edited by Xray-TLS-Web-setup-script" >> /etc/ssh/sshd_config
        service sshd restart
        green  "----------------------配置完成----------------------"
        tyblue " 请重新进行ssh连接(即重新登陆服务器)，并再次运行此脚本"
        yellow " 按回车键退出。。。。"
        read -s
        exit 0
    fi
}

#删除防火墙和阿里云盾
uninstall_firewall()
{
    green "正在删除防火墙。。。"
    ufw disable
    apt -y purge firewalld
    apt -y purge ufw
    systemctl stop firewalld
    systemctl disable firewalld
    $redhat_package_manager -y remove firewalld
    green "正在删除阿里云盾和腾讯云盾 (仅对阿里云和腾讯云服务器有效)。。。"
#阿里云盾
    if [ $release == "ubuntu" ] || [ $release == "other-debian" ]; then
        systemctl stop CmsGoAgent
        systemctl disable CmsGoAgent
        rm -rf /usr/local/cloudmonitor
        rm -rf /etc/systemd/system/CmsGoAgent.service
        systemctl daemon-reload
    else
        systemctl stop cloudmonitor
        /etc/rc.d/init.d/cloudmonitor remove
        rm -rf /usr/local/cloudmonitor
        systemctl daemon-reload
    fi

    systemctl stop aliyun
    systemctl disable aliyun
    rm -rf /etc/systemd/system/aliyun.service
    systemctl daemon-reload
    apt -y purge aliyun-assist
    $redhat_package_manager -y remove aliyun_assist
    rm -rf /usr/local/share/aliyun-assist
    rm -rf /usr/sbin/aliyun_installer
    rm -rf /usr/sbin/aliyun-service
    rm -rf /usr/sbin/aliyun-service.backup

    pkill -9 AliYunDun
    pkill -9 AliHids
    /etc/init.d/aegis uninstall
    rm -rf /usr/local/aegis
    rm -rf /etc/init.d/aegis
    rm -rf /etc/rc2.d/S80aegis
    rm -rf /etc/rc3.d/S80aegis
    rm -rf /etc/rc4.d/S80aegis
    rm -rf /etc/rc5.d/S80aegis
#腾讯云盾
    /usr/local/qcloud/stargate/admin/uninstall.sh
    /usr/local/qcloud/YunJing/uninst.sh
    /usr/local/qcloud/monitor/barad/admin/uninstall.sh
    systemctl daemon-reload
    systemctl stop YDService
    systemctl disable YDService
    rm -rf /lib/systemd/system/YDService.service
    systemctl daemon-reload
    sed -i 's#/usr/local/qcloud#rcvtevyy4f5d#g' /etc/rc.local
    sed -i '/rcvtevyy4f5d/d' /etc/rc.local
    rm -rf $(find /etc/udev/rules.d -iname *qcloud* 2>/dev/null)
    pkill -9 YDService
    pkill -9 YDLive
    pkill -9 sgagent
    pkill -9 /usr/local/qcloud
    pkill -9 barad_agent
    rm -rf /usr/local/qcloud
    rm -rf /usr/local/yd.socket.client
    rm -rf /usr/local/yd.socket.server
    mkdir /usr/local/qcloud
    mkdir /usr/local/qcloud/action
    mkdir /usr/local/qcloud/action/login_banner.sh
    mkdir /usr/local/qcloud/action/action.sh
    if [[ "$(type -P uname)" ]] && uname -a | grep solaris >/dev/null; then
        crontab -l | sed "/qcloud/d" | crontab --
    else
        crontab -l | sed "/qcloud/d" | crontab -
    fi
}

#升级系统组件
doupdate()
{
    updateSystem()
    {
        if ! [[ "$(type -P do-release-upgrade)" ]]; then
            if ! apt -y --no-install-recommends install ubuntu-release-upgrader-core; then
                apt update
                if ! apt -y --no-install-recommends install ubuntu-release-upgrader-core; then
                    red    "脚本出错！"
                    yellow "按回车键继续或者Ctrl+c退出"
                    read -s
                fi
            fi
        fi
        echo -e "\n\n\n"
        tyblue "------------------请选择升级系统版本--------------------"
        tyblue " 1.最新beta版(现在是21.04)(2020.11)"
        tyblue " 2.最新发行版(现在是20.10)(2020.11)"
        tyblue " 3.最新LTS版(现在是20.04)(2020.11)"
        tyblue "-------------------------版本说明-------------------------"
        tyblue " beta版：即测试版"
        tyblue " 发行版：即稳定版"
        tyblue " LTS版：长期支持版本，可以理解为超级稳定版"
        tyblue "-------------------------注意事项-------------------------"
        yellow " 1.升级过程中遇到问话/对话框，如果不明白，选择yes/y/第一个选项"
        yellow " 2.升级系统完成后将会重启，重启后，请再次运行此脚本完成剩余安装"
        yellow " 3.升级系统可能需要15分钟或更久"
        yellow " 4.有的时候不能一次性更新到所选择的版本，可能要更新多次"
        yellow " 5.升级系统后以下配置可能会恢复系统默认配置："
        yellow "     ssh端口   ssh超时时间    bbr加速(恢复到关闭状态)"
        tyblue "----------------------------------------------------------"
        green  " 您现在的系统版本是$systemVersion"
        tyblue "----------------------------------------------------------"
        echo
        choice=""
        while [ "$choice" != "1" -a "$choice" != "2" -a "$choice" != "3" ]
        do
            read -p "您的选择是：" choice
        done
        if ! [[ "$(cat /etc/ssh/sshd_config | grep -i '^[ '$'\t]*port ' | awk '{print $2}')" =~ ^("22"|"")$ ]]; then
            red "检测到ssh端口号被修改"
            red "升级系统后ssh端口号可能恢复默认值(22)"
            yellow "按回车键继续。。。"
            read -s
        fi
        local i
        for ((i=0;i<2;i++))
        do
            sed -i '/^[ \t]*Prompt[ \t]*=/d' /etc/update-manager/release-upgrades
            echo 'Prompt=normal' >> /etc/update-manager/release-upgrades
            case "$choice" in
                1)
                    do-release-upgrade -d
                    do-release-upgrade -d
                    sed -i 's/Prompt=normal/Prompt=lts/' /etc/update-manager/release-upgrades
                    do-release-upgrade -d
                    do-release-upgrade -d
                    sed -i 's/Prompt=lts/Prompt=normal/' /etc/update-manager/release-upgrades
                    do-release-upgrade
                    do-release-upgrade
                    sed -i 's/Prompt=normal/Prompt=lts/' /etc/update-manager/release-upgrades
                    do-release-upgrade
                    do-release-upgrade
                    ;;
                2)
                    do-release-upgrade
                    do-release-upgrade
                    ;;
                3)
                    sed -i 's/Prompt=normal/Prompt=lts/' /etc/update-manager/release-upgrades
                    do-release-upgrade
                    do-release-upgrade
                    ;;
            esac
            if ! version_ge $systemVersion 20.04; then
                sed -i 's/Prompt=lts/Prompt=normal/' /etc/update-manager/release-upgrades
                do-release-upgrade
                do-release-upgrade
            fi
            apt update
            apt -y --auto-remove --purge full-upgrade
        done
    }
    while ((1))
    do
        echo -e "\n\n\n"
        tyblue "-----------------------是否更新系统组件？-----------------------"
        green  " 1. 更新已安装软件，并升级系统 (Ubuntu专享)"
        green  " 2. 仅更新已安装软件"
        red    " 3. 不更新"
        if [ "$release" == "ubuntu" ]; then
            if [ $mem_ok == 2 ]; then
                echo
                yellow "如果要升级系统，请确保服务器的内存>=512MB"
                yellow "否则可能无法开机"
            elif [ $mem_ok == 0 ]; then
                echo
                red "检测到内存过小，升级系统可能导致无法开机，请谨慎选择"
            fi
        fi
        echo
        choice=""
        while [ "$choice" != "1" -a "$choice" != "2" -a "$choice" != "3" ]
        do
            read -p "您的选择是：" choice
        done
        if [ "$release" == "ubuntu" ] || [ $choice -ne 1 ]; then
            break
        fi
        echo
        yellow " 更新系统仅支持Ubuntu！"
        sleep 3s
    done
    if [ $choice -eq 1 ]; then
        updateSystem
        apt -y --purge autoremove
        apt clean
    elif [ $choice -eq 2 ]; then
        tyblue "-----------------------即将开始更新-----------------------"
        yellow " 更新过程中遇到问话/对话框，如果不明白，选择yes/y/第一个选项"
        yellow " 按回车键继续。。。"
        read -s
        $redhat_package_manager -y autoremove
        $redhat_package_manager -y update
        apt update
        apt -y --auto-remove --purge full-upgrade
        apt -y --purge autoremove
        apt clean
        $redhat_package_manager -y autoremove
        $redhat_package_manager clean all
    fi
}

#进入工作目录
enter_temp_dir()
{
    rm -rf "$temp_dir"
    mkdir "$temp_dir"
    cd "$temp_dir"
}

#安装bbr
install_bbr()
{
    #输出：latest_kernel_version 和 your_kernel_version
    get_kernel_info()
    {
        green "正在获取最新版本内核版本号。。。。(60内秒未获取成功自动跳过)"
        local kernel_list
        local kernel_list_temp=($(timeout 60 wget -qO- https://kernel.ubuntu.com/~kernel-ppa/mainline/ | awk -F'\"v' '/v[0-9]/{print $2}' | cut -d '"' -f1 | cut -d '/' -f1 | sort -rV))
        if [ ${#kernel_list_temp[@]} -le 1 ]; then
            latest_kernel_version="error"
            your_kernel_version=$(uname -r | cut -d - -f 1)
            return 1
        fi
        local i=0
        local i2=0
        local i3=0
        local kernel_rc=""
        local kernel_list_temp2
        while ((i2<${#kernel_list_temp[@]}))
        do
            if [[ "${kernel_list_temp[i2]}" =~ "rc" ]] && [ "$kernel_rc" == "" ]; then
                kernel_list_temp2[i3]="${kernel_list_temp[i2]}"
                kernel_rc="${kernel_list_temp[i2]%%-*}"
                ((i3++))
                ((i2++))
            elif [[ "${kernel_list_temp[i2]}" =~ "rc" ]] && [ "${kernel_list_temp[i2]%%-*}" == "$kernel_rc" ]; then
                kernel_list_temp2[i3]=${kernel_list_temp[i2]}
                ((i3++))
                ((i2++))
            elif [[ "${kernel_list_temp[i2]}" =~ "rc" ]] && [ "${kernel_list_temp[i2]%%-*}" != "$kernel_rc" ]; then
                for((i3=0;i3<${#kernel_list_temp2[@]};i3++))
                do
                    kernel_list[i]=${kernel_list_temp2[i3]}
                    ((i++))
                done
                kernel_rc=""
                i3=0
                unset kernel_list_temp2
            elif version_ge "$kernel_rc" "${kernel_list_temp[i2]}"; then
                if [ "$kernel_rc" == "${kernel_list_temp[i2]}" ]; then
                    kernel_list[i]=${kernel_list_temp[i2]}
                    ((i++))
                    ((i2++))
                fi
                for((i3=0;i3<${#kernel_list_temp2[@]};i3++))
                do
                    kernel_list[i]=${kernel_list_temp2[i3]}
                    ((i++))
                done
                kernel_rc=""
                i3=0
                unset kernel_list_temp2
            else
                kernel_list[i]=${kernel_list_temp[i2]}
                ((i++))
                ((i2++))
            fi
        done
        if [ "$kernel_rc" != "" ]; then
            for((i3=0;i3<${#kernel_list_temp2[@]};i3++))
            do
                kernel_list[i]=${kernel_list_temp2[i3]}
                ((i++))
            done
        fi
        latest_kernel_version=${kernel_list[0]}
        your_kernel_version=$(uname -r | cut -d - -f 1)
        check_fake_version()
        {
            local temp=${1##*.}
            if [ ${temp} -eq 0 ]; then
                return 0
            else
                return 1
            fi
        }
        while check_fake_version ${your_kernel_version}
        do
            your_kernel_version=${your_kernel_version%.*}
        done
        if [ $release == "ubuntu" ] || [ $release == "other-debian" ]; then
            local rc_version=$(uname -r | cut -d - -f 2)
            if [[ $rc_version =~ "rc" ]]; then
                rc_version=${rc_version##*'rc'}
                your_kernel_version=${your_kernel_version}-rc${rc_version}
            fi
            uname -r | grep -q xanmod && your_kernel_version="${your_kernel_version}-xanmod"
        else
            latest_kernel_version=${latest_kernel_version%%-*}
        fi
    }
    #卸载多余内核
    remove_other_kernel()
    {
        if [ $release == "ubuntu" ] || [ $release == "other-debian" ]; then
            local kernel_list_image=($(dpkg --list | awk '{print $2}' | grep '^linux-image'))
            local kernel_list_modules=($(dpkg --list | awk '{print $2}' | grep '^linux-modules'))
            local kernel_now=$(uname -r)
            local ok_install=0
            for ((i=${#kernel_list_image[@]}-1;i>=0;i--))
            do
                if [[ "${kernel_list_image[$i]}" =~ "$kernel_now" ]]; then     
                    unset kernel_list_image[$i]
                    ((ok_install++))
                fi
            done
            if [ $ok_install -lt 1 ]; then
                red "未发现正在使用的内核，可能已经被卸载，请先重新启动"
                yellow "按回车键继续。。。"
                read -s
                return 1
            fi
            for ((i=${#kernel_list_modules[@]}-1;i>=0;i--))
            do
                if [[ "${kernel_list_modules[$i]}" =~ "$kernel_now" ]]; then
                    unset kernel_list_modules[$i]
                fi
            done
            if [ ${#kernel_list_modules[@]} -eq 0 ] && [ ${#kernel_list_image[@]} -eq 0 ]; then
                yellow "没有内核可卸载"
                return 0
            fi
            apt -y purge ${kernel_list_image[@]} ${kernel_list_modules[@]}
            apt-mark manual "^grub"
        else
            local kernel_list=($(rpm -qa |grep '^kernel-[0-9]\|^kernel-ml-[0-9]'))
            local kernel_list_devel=($(rpm -qa | grep '^kernel-devel\|^kernel-ml-devel'))
            if version_ge $redhat_version 8; then
                local kernel_list_modules=($(rpm -qa |grep '^kernel-modules\|^kernel-ml-modules'))
                local kernel_list_core=($(rpm -qa | grep '^kernel-core\|^kernel-ml-core'))
            fi
            local kernel_now=$(uname -r)
            local ok_install=0
            for ((i=${#kernel_list[@]}-1;i>=0;i--))
            do
                if [[ "${kernel_list[$i]}" =~ "$kernel_now" ]]; then
                    unset kernel_list[$i]
                    ((ok_install++))
                fi
            done
            if [ $ok_install -lt 1 ]; then
                red "未发现正在使用的内核，可能已经被卸载，请先重新启动"
                yellow "按回车键继续。。。"
                read -s
                return 1
            fi
            for ((i=${#kernel_list_devel[@]}-1;i>=0;i--))
            do
                if [[ "${kernel_list_devel[$i]}" =~ "$kernel_now" ]]; then
                    unset kernel_list_devel[$i]
                fi
            done
            if version_ge $redhat_version 8; then
                ok_install=0
                for ((i=${#kernel_list_modules[@]}-1;i>=0;i--))
                do
                    if [[ "${kernel_list_modules[$i]}" =~ "$kernel_now" ]]; then
                        unset kernel_list_modules[$i]
                        ((ok_install++))
                    fi
                done
                if [ $ok_install -lt 1 ]; then
                    red "未发现正在使用的内核，可能已经被卸载，请先重新启动"
                    yellow "按回车键继续。。。"
                    read -s
                    return 1
                fi
                ok_install=0
                for ((i=${#kernel_list_core[@]}-1;i>=0;i--))
                do
                    if [[ "${kernel_list_core[$i]}" =~ "$kernel_now" ]]; then
                        unset kernel_list_core[$i]
                        ((ok_install++))
                    fi
                done
                if [ $ok_install -lt 1 ]; then
                    red "未发现正在使用的内核，可能已经被卸载，请先重新启动"
                    yellow "按回车键继续。。。"
                    read -s
                    return 1
                fi
            fi
            if ([ ${#kernel_list[@]} -eq 0 ] && [ ${#kernel_list_devel[@]} -eq 0 ]) && (! version_ge $redhat_version 8 || ([ ${#kernel_list_modules[@]} -eq 0 ] && [ ${#kernel_list_core[@]} -eq 0 ])); then
                yellow "没有内核可卸载"
                return 0
            fi
            if version_ge $redhat_version 8; then
                $redhat_package_manager -y remove ${kernel_list[@]} ${kernel_list_modules[@]} ${kernel_list_core[@]} ${kernel_list_devel[@]}
            else
                $redhat_package_manager -y remove ${kernel_list[@]} ${kernel_list_devel[@]}
            fi
        fi
        green "-------------------卸载完成-------------------"
    }
    change_qdisc()
    {
        local list=('fq' 'fq_pie' 'cake' 'fq_codel')
        tyblue "==============请选择你要使用的队列算法=============="
        green  " 1.fq"
        green  " 2.fq_pie"
        tyblue " 3.cake"
        tyblue " 4.fq_codel"
        choice=""
        while [ "$choice" != "1" -a "$choice" != "2" -a "$choice" != "3" -a "$choice" != "4" ]
        do
            read -p "您的选择是：" choice
        done
        local qdisc=${list[((choice-1))]}
        sed -i '/^[ \t]*net.core.default_qdisc[ \t]*=/d' /etc/sysctl.conf
        echo "net.core.default_qdisc = $qdisc" >> /etc/sysctl.conf
        sysctl -p
        sleep 1s
        if [ "$(sysctl net.core.default_qdisc | cut -d = -f 2 | awk '{print $1}')" == "$qdisc" ]; then
            green "更换成功！"
        else
            red "更换失败，内核不支持"
            sed -i '/^[ \t]*net.core.default_qdisc[ \t]*=/d' /etc/sysctl.conf
            echo "net.core.default_qdisc = $default_qdisc" >> /etc/sysctl.conf
            return 1
        fi
    }
    local your_kernel_version
    local latest_kernel_version
    get_kernel_info
    if ! grep -q "#This file has been edited by Xray-TLS-Web-setup-script" /etc/sysctl.conf; then
        echo >> /etc/sysctl.conf
        echo "#This file has been edited by Xray-TLS-Web-setup-script" >> /etc/sysctl.conf
    fi
    while ((1))
    do
        echo -e "\n\n\n"
        tyblue "------------------请选择要使用的bbr版本------------------"
        green  " 1. 升级最新版内核并启用bbr(推荐)"
        green  " 2. 安装xanmod内核并启用bbr(推荐)"
        if version_ge $your_kernel_version 4.9; then
            tyblue " 3. 启用bbr"
        else
            tyblue " 3. 升级内核启用bbr"
        fi
        tyblue " 4. 安装第三方内核并启用bbr2"
        tyblue " 5. 安装第三方内核并启用bbrplus/bbr魔改版/暴力bbr魔改版/锐速"
        tyblue " 6. 卸载多余内核"
        tyblue " 7. 更换队列算法"
        tyblue " 8. 退出bbr安装"
        tyblue "------------------关于安装bbr加速的说明------------------"
        green  " bbr拥塞算法可以大幅提升网络速度，建议启用"
        yellow " 更换第三方内核可能造成系统不稳定，甚至无法开机"
        yellow " 更换/升级内核需重启，重启后，请再次运行此脚本完成剩余安装"
        tyblue "---------------------------------------------------------"
        tyblue " 当前内核版本：${your_kernel_version}"
        tyblue " 最新内核版本：${latest_kernel_version}"
        tyblue " 当前内核是否支持bbr："
        if version_ge $your_kernel_version 4.9; then
            green "     是"
        else
            red "     否，需升级内核"
        fi
        tyblue "   当前拥塞控制算法："
        local tcp_congestion_control=$(sysctl net.ipv4.tcp_congestion_control | cut -d = -f 2 | awk '{print $1}')
        if [[ "$tcp_congestion_control" =~ bbr|nanqinlang|tsunami ]]; then
            if [ $tcp_congestion_control == nanqinlang ]; then
                tcp_congestion_control="${tcp_congestion_control} \033[35m(暴力bbr魔改版)"
            elif [ $tcp_congestion_control == tsunami ]; then
                tcp_congestion_control="${tcp_congestion_control} \033[35m(bbr魔改版)"
            fi
            green  "       ${tcp_congestion_control}"
        else
            tyblue "       ${tcp_congestion_control} \033[31m(bbr未启用)"
        fi
        tyblue "   当前队列算法："
        local default_qdisc=$(sysctl net.core.default_qdisc | cut -d = -f 2 | awk '{print $1}')
        green "       $default_qdisc"
        echo
        choice=""
        while [ "$choice" != "1" -a "$choice" != "2" -a "$choice" != "3" -a "$choice" != "4" -a "$choice" != "5" -a "$choice" != "6" -a "$choice" != "7" -a "$choice" != "8" ]
        do
            read -p "您的选择是：" choice
        done
        if [ $choice -eq 1 ]; then
            sed -i '/^[ \t]*net.core.default_qdisc[ \t]*=/d' /etc/sysctl.conf
            sed -i '/^[ \t]*net.ipv4.tcp_congestion_control[ \t]*=/d' /etc/sysctl.conf
            echo 'net.core.default_qdisc = fq' >> /etc/sysctl.conf
            echo 'net.ipv4.tcp_congestion_control = bbr' >> /etc/sysctl.conf
            sysctl -p
            if ! wget -O update-kernel.sh https://github.com/kirin10000/update-kernel/raw/master/update-kernel.sh; then
                red    "获取内核升级脚本失败"
                yellow "按回车键继续或者按ctrl+c终止"
                read -s
            fi
            chmod +x update-kernel.sh
            ./update-kernel.sh
            if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
                red "开启bbr失败"
                red "如果刚安装完内核，请先重启"
                red "如果重启仍然无效，请尝试选择2选项"
            else
                green "--------------------bbr已安装--------------------"
            fi
        elif [ $choice -eq 2 ]; then
            sed -i '/^[ \t]*net.core.default_qdisc[ \t]*=/d' /etc/sysctl.conf
            sed -i '/^[ \t]*net.ipv4.tcp_congestion_control[ \t]*=/d' /etc/sysctl.conf
            echo 'net.core.default_qdisc = fq' >> /etc/sysctl.conf
            echo 'net.ipv4.tcp_congestion_control = bbr' >> /etc/sysctl.conf
            sysctl -p
            if ! wget -O xanmod-install.sh https://github.com/kirin10000/xanmod-install/raw/main/xanmod-install.sh; then
                red    "获取xanmod内核安装脚本失败"
                yellow "按回车键继续或者按ctrl+c终止"
                read -s
            fi
            chmod +x xanmod-install.sh
            ./xanmod-install.sh
            if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
                red "开启bbr失败"
                red "如果刚安装完内核，请先重启"
                red "如果重启仍然无效，请尝试选择2选项"
            else
                green "--------------------bbr已安装--------------------"
            fi
        elif [ $choice -eq 3 ]; then
            sed -i '/^[ \t]*net.core.default_qdisc[ \t]*=/d' /etc/sysctl.conf
            sed -i '/^[ \t]*net.ipv4.tcp_congestion_control[ \t]*=/d' /etc/sysctl.conf
            echo 'net.core.default_qdisc = fq' >> /etc/sysctl.conf
            echo 'net.ipv4.tcp_congestion_control = bbr' >> /etc/sysctl.conf
            sysctl -p
            sleep 1s
            if ! sysctl net.ipv4.tcp_congestion_control | grep -wq "bbr"; then
                if ! wget -O bbr.sh https://github.com/teddysun/across/raw/master/bbr.sh; then
                    red    "获取bbr脚本失败"
                    yellow "按回车键继续或者按ctrl+c终止"
                    read -s
                fi
                chmod +x bbr.sh
                ./bbr.sh
            else
                green "--------------------bbr已安装--------------------"
            fi
        elif [ $choice -eq 4 ]; then
            tyblue "--------------------即将安装bbr2加速，安装完成后服务器将会重启--------------------"
            tyblue " 重启后，请再次选择这个选项完成bbr2剩余部分安装(开启bbr和ECN)"
            yellow " 按回车键以继续。。。。"
            read -s
            local temp_bbr2
            if [ $release == "ubuntu" ] || [ $release == "other-debian" ]; then
                local temp_bbr2="https://github.com/yeyingorg/bbr2.sh/raw/master/bbr2.sh"
            else
                local temp_bbr2="https://github.com/jackjieYYY/bbr2/raw/master/bbr2.sh"
            fi
            if ! wget -O bbr2.sh $temp_bbr2; then
                red    "获取bbr2脚本失败"
                yellow "按回车键继续或者按ctrl+c终止"
                read -s
            fi
            chmod +x bbr2.sh
            ./bbr2.sh
        elif [ $choice -eq 5 ]; then
            if ! wget -O tcp.sh "https://raw.githubusercontent.com/chiakge/Linux-NetSpeed/master/tcp.sh"; then
                red    "获取脚本失败"
                yellow "按回车键继续或者按ctrl+c终止"
                read -s
            fi
            chmod +x tcp.sh
            ./tcp.sh
        elif [ $choice -eq 6 ]; then
            tyblue " 该操作将会卸载除现在正在使用的内核外的其余内核"
            tyblue "    您正在使用的内核是：$(uname -r)"
            choice=""
            while [[ "$choice" != "y" && "$choice" != "n" ]]
            do
                read -p "是否继续？(y/n)" choice
            done
            if [ $choice == y ]; then
                remove_other_kernel
            fi
        elif [ $choice -eq 7 ]; then
            change_qdisc
        else
            break
        fi
        sleep 3s
    done
}

#读取域名
readDomain()
{
    check_domain()
    {
        local temp=${1%%.*}
        if [ "$temp" == "www" ]; then
            red "域名前面不要带www！"
            return 0
        elif [ "$1" == "" ]; then
            return 0
        else
            return 1
        fi
    }
    local domain
    local domainconfig
    local pretend
    echo -e "\n\n\n"
    tyblue "--------------------请选择域名解析情况--------------------"
    tyblue " 1. 一级域名 和 www.一级域名 都解析到此服务器上"
    green  "    如：123.com 和 www.123.com 都解析到此服务器上"
    tyblue " 2. 仅某个域名解析到此服务器上"
    green  "    如：123.com 或 www.123.com 或 xxx.123.com 中的某一个解析到此服务器上"
    echo
    domainconfig=""
    while [ "$domainconfig" != "1" -a "$domainconfig" != "2" ]
    do
        read -p "您的选择是：" domainconfig
    done
    local queren=""
    while [ "$queren" != "y" ]
    do
        echo
        if [ $domainconfig -eq 1 ]; then
            tyblue '---------请输入一级域名(前面不带"www."、"http://"或"https://")---------'
            read -p "请输入域名：" domain
            while check_domain "$domain"
            do
                read -p "请输入域名：" domain
            done
        else
            tyblue '-------请输入解析到此服务器的域名(前面不带"http://"或"https://")-------'
            read -p "请输入域名：" domain
        fi
        echo
        queren=""
        while [ "$queren" != "y" -a "$queren" != "n" ]
        do
            tyblue "您输入的域名是\"$domain\"，确认吗？(y/n)"
            read queren
        done
    done
    queren=""
    while [ "$queren" != "y" ]
    do
        echo -e "\n\n\n"
        tyblue "------------------------------请选择要伪装的网站页面------------------------------"
        tyblue " 1. 403页面 (模拟网站后台)"
        green  "    说明：大型网站几乎都有使用网站后台，比如bilibili的每个视频都是由"
        green  "    另外一个域名提供的，直接访问那个域名的根目录将返回403或其他错误页面"
        tyblue " 2. 镜像腾讯视频网站"
        green  "    说明：是真镜像站，非链接跳转，默认为腾讯视频，搭建完成后可以自己修改，可能构成侵权"
        tyblue " 3. Nextcloud登陆页面"
        green  "    说明：Nextclound是开源的私人网盘服务，假装你搭建了一个私人网盘(可以换成别的自定义网站)"
        tyblue " 4. Nextcloud(需安装php)"
        green  "    说明：最强伪装，没有之一"
        echo
        pretend=""
        while [[ "$pretend" != "1" && "$pretend" != "2" && "$pretend" != "3" && "$pretend" != "4" ]]
        do
            read -p "您的选择是：" pretend
        done
        if [ $pretend -eq 4 ] && ([ $release == "centos" ] || [ $release == "fedora" ] || [ $release == "other-redhat" ]) && ! version_ge $redhat_version 8; then
            red "不支持在 Red-hat版本<8 的 Red-hat基 系统上安装php"
            yellow "如： CentOS<8 Fedora<30 的版本"
            continue
        fi
        if [ $pretend -eq 4 ] && [ $php_is_installed -eq 0 ]; then
            tyblue "安装Nextcloud需要安装php"
            yellow "编译&&安装php可能需要额外消耗15-60分钟"
            yellow "php将占用一定系统资源，不建议内存<512M的机器使用"
            queren=""
            while [ "$queren" != "y" -a "$queren" != "n" ]
            do
                tyblue "确定选择吗？(y/n)"
                read queren
            done
        else
            queren=y
        fi
    done
    domain_list+=("$domain")
    domainconfig_list+=("$domainconfig")
    pretend_list+=("$pretend")
}

#读取xray_protocol配置
readProtocolConfig()
{
    echo -e "\n\n\n"
    tyblue "---------------------请选择Xray要使用协议---------------------"
    tyblue " 1. (VLESS-TCP+XTLS) + (VMess-WebSocket+TLS) + Web"
    green  "    适合有时使用CDN，且CDN不可信任(如国内CDN)"
    tyblue " 2. (VLESS-TCP+XTLS) + (VLESS-WebSocket+TLS) + Web"
    green  "    适合有时使用CDN，且CDN可信任"
    tyblue " 3. VLESS-TCP+XTLS+Web"
    green  "    适合完全不用CDN"
    tyblue " 4. VMess-WebSocket+TLS+Web"
    green  "    适合一直使用CDN，且CDN不可信任(如国内CDN)"
    tyblue " 5. VLESS-WebSocket+TLS+Web"
    green  "    适合一直使用CDN，且CDN可信任"
    echo
    yellow " 注："
    yellow "   1.各协议理论速度对比：github.com/badO1a5A90/v2ray-doc/blob/main/Xray_test_v1.1.1.md"
    yellow "   2.XTLS完全兼容TLS"
    yellow "   3.WebSocket协议支持CDN，TCP不支持"
    yellow "   4.VLESS协议用于CDN，CDN可以看见传输的明文"
    yellow "   5.若不知CDN为何物，请选3"
    echo
    local mode=""
    while [[ "$mode" != "1" && "$mode" != "2" && "$mode" != "3" && "$mode" != "4" && "$mode" != "5" ]]
    do
        read -p "您的选择是：" mode
    done
    if [ $mode -eq 1 ]; then
        protocol_1=1
        protocol_2=2
    elif [ $mode -eq 2 ]; then
        protocol_1=1
        protocol_2=1
    elif [ $mode -eq 3 ]; then
        protocol_1=1
        protocol_2=0
    elif [ $mode -eq 4 ]; then
        protocol_1=0
        protocol_2=2
    elif [ $mode -eq 5 ]; then
        protocol_1=0
        protocol_2=1
    fi
}

#检查Nginx更新
check_nginx_update()
{
    local nginx_version_now="nginx-$(${nginx_prefix}/sbin/nginx -V 2>&1 | grep "^nginx version:" | cut -d / -f 2)"
    local openssl_version_now="openssl-openssl-$(${nginx_prefix}/sbin/nginx -V 2>&1 | grep "^built with OpenSSL" | awk '{print $4}')"
    if [ "$nginx_version_now" == "$nginx_version" ] && [ "$openssl_version_now" == "$openssl_version" ]; then
        return 1
    else
        return 0
    fi
}

#检查php更新
check_php_update()
{
    local php_version_now="php-$(${php_prefix}/bin/php -v | head -n 1 | awk '{print $2}')"
    [ "$php_version_now" == "$php_version" ] && return 1
    return 0
}

#备份域名伪装网站
backup_domains_web()
{
    local i
    mkdir "${temp_dir}/domain_backup"
    for i in ${!domain_list[@]}
    do
        if [ "$1" == "cp" ]; then
            cp -rf ${nginx_prefix}/html/${domain_list[i]} "${temp_dir}/domain_backup" 2>/dev/null
        else
            mv ${nginx_prefix}/html/${domain_list[i]} "${temp_dir}/domain_backup" 2>/dev/null
        fi
    done
}

#卸载xray和nginx
remove_xray()
{
    if ! bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) remove --purge; then
        systemctl stop xray
        systemctl disable xray
        rm -rf /usr/local/bin/xray
        rm -rf /usr/local/etc/xray
        rm -rf /etc/systemd/system/xray.service
        rm -rf /etc/systemd/system/xray@.service
        rm -rf /var/log/xray
        systemctl daemon-reload
    fi
}
remove_nginx()
{
    systemctl stop nginx
    ${nginx_prefix}/sbin/nginx -s stop
    pkill -9 nginx
    systemctl disable nginx
    rm -rf $nginx_service
    systemctl daemon-reload
    rm -rf ${nginx_prefix}
    nginx_prefix="/usr/local/nginx"
    nginx_config="${nginx_prefix}/conf.d/xray.conf"
}
remove_php()
{
    systemctl stop php-fpm
    systemctl disable php-fpm
    pkill -9 php-fpm
    rm -rf /etc/systemd/system/php-fpm.service
    systemctl daemon-reload
    rm -rf ${php_prefix}
}

#编译安装nignx
compile_nginx()
{
    green "正在编译Nginx。。。。"
    if ! wget -O ${nginx_version}.tar.gz https://nginx.org/download/${nginx_version}.tar.gz; then
        red    "获取nginx失败"
        yellow "按回车键继续或者按ctrl+c终止"
        read -s
    fi
    tar -zxf ${nginx_version}.tar.gz
    if ! wget -O ${openssl_version}.tar.gz https://github.com/openssl/openssl/archive/${openssl_version#*-}.tar.gz; then
        red    "获取openssl失败"
        yellow "按回车键继续或者按ctrl+c终止"
        read -s
    fi
    tar -zxf ${openssl_version}.tar.gz
    cd ${nginx_version}
    sed -i "s/OPTIMIZE[ \t]*=>[ \t]*'-O'/OPTIMIZE          => '-O3'/g" src/http/modules/perl/Makefile.PL
    ./configure --prefix=/usr/local/nginx --with-openssl=../$openssl_version --with-openssl-opt="enable-ec_nistp_64_gcc_128 shared threads zlib-dynamic sctp" --with-mail=dynamic --with-mail_ssl_module --with-stream=dynamic --with-stream_ssl_module --with-stream_realip_module --with-stream_geoip_module=dynamic --with-stream_ssl_preread_module --with-http_ssl_module --with-http_v2_module --with-http_realip_module --with-http_addition_module --with-http_xslt_module=dynamic --with-http_image_filter_module=dynamic --with-http_geoip_module=dynamic --with-http_sub_module --with-http_dav_module --with-http_flv_module --with-http_mp4_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_auth_request_module --with-http_random_index_module --with-http_secure_link_module --with-http_degradation_module --with-http_slice_module --with-http_stub_status_module --with-http_perl_module=dynamic --with-pcre --with-libatomic --with-compat --with-cpp_test_module --with-google_perftools_module --with-file-aio --with-threads --with-poll_module --with-select_module --with-cc-opt="-Wno-error -g0 -O3"
    if ! make; then
        red    "Nginx编译失败！"
        green  "欢迎进行Bug report(https://github.com/kirin10000/Xray-script/issues)，感谢您的支持"
        yellow "在Bug修复前，建议使用Ubuntu最新版系统"
        exit 1
    fi
    cd -
}
config_service_nginx()
{
    systemctl --now disable nginx
    rm -rf $nginx_service
cat > $nginx_service << EOF
[Unit]
Description=The NGINX HTTP and reverse proxy server
After=syslog.target network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
User=root
ExecStartPre=/bin/rm -rf /dev/shm/nginx_unixsocket
ExecStartPre=/bin/mkdir /dev/shm/nginx_unixsocket
ExecStartPre=/bin/chmod 711 /dev/shm/nginx_unixsocket
ExecStartPre=/bin/rm -rf /dev/shm/nginx_tcmalloc
ExecStartPre=/bin/mkdir /dev/shm/nginx_tcmalloc
ExecStartPre=/bin/chmod 0777 /dev/shm/nginx_tcmalloc
ExecStart=${nginx_prefix}/sbin/nginx
ExecStop=${nginx_prefix}/sbin/nginx -s stop
ExecStopPost=/bin/rm -rf /dev/shm/nginx_tcmalloc
ExecStopPost=/bin/rm -rf /dev/shm/nginx_unixsocket
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 $nginx_service
    systemctl daemon-reload
    systemctl enable nginx
}
install_nginx_part1()
{
    green "正在安装Nginx。。。"
    cd ${nginx_version}
    make install
    cd -
}
install_nginx_part2()
{
    mkdir ${nginx_prefix}/conf.d
    touch $nginx_config
    mkdir ${nginx_prefix}/certs
    mkdir ${nginx_prefix}/html/issue_certs
cat > ${nginx_prefix}/conf/issue_certs.conf << EOF
events {
    worker_connections  1024;
}
http {
    server {
        listen [::]:80 ipv6only=off;
        root ${nginx_prefix}/html/issue_certs;
    }
}
EOF
cat > ${nginx_prefix}/conf.d/nextcloud.conf <<EOF
    client_max_body_size 0;
    fastcgi_buffers 64 4K;
    gzip on;
    gzip_vary on;
    gzip_comp_level 4;
    gzip_min_length 256;
    gzip_proxied expired no-cache no-store private no_last_modified no_etag auth;
    gzip_types application/atom+xml application/javascript application/json application/ld+json application/manifest+json application/rss+xml application/vnd.geo+json application/vnd.ms-fontobject application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/plain text/vcard text/vnd.rim.location.xloc text/vtt text/x-component text/x-cross-domain-policy;
    add_header Referrer-Policy                      "no-referrer"   always;
    add_header X-Content-Type-Options               "nosniff"       always;
    add_header X-Download-Options                   "noopen"        always;
    add_header X-Frame-Options                      "SAMEORIGIN"    always;
    add_header X-Permitted-Cross-Domain-Policies    "none"          always;
    add_header X-Robots-Tag                         "none"          always;
    add_header X-XSS-Protection                     "1; mode=block" always;
    fastcgi_hide_header X-Powered-By;
    index index.php index.html /index.php\$request_uri;
    expires 1m;
    location = / {
        if ( \$http_user_agent ~ ^DavClnt ) {
            return 302 /remote.php/webdav/\$is_args\$args;
        }
    }
    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }
    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/)  { return 404; }
    location ~ ^/(?:\\.|autotest|occ|issue|indie|db_|console)              { return 404; }
    location ~ \\.php(?:$|/) {
        include fastcgi.conf;
        fastcgi_param REMOTE_ADDR 127.0.0.1;
        fastcgi_split_path_info ^(.+?\\.php)(/.*)$;
        set \$path_info \$fastcgi_path_info;
        try_files \$fastcgi_script_name =404;
        fastcgi_param PATH_INFO \$path_info;
        fastcgi_param HTTPS on;
        fastcgi_param modHeadersAvailable true;         # Avoid sending the security headers twice
        fastcgi_param front_controller_active true;     # Enable pretty urls
        fastcgi_pass unix:/dev/shm/php-fpm_unixsocket/php.sock;
        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;
    }
    location ~ \\.(?:css|js|svg|gif)$ {
        try_files \$uri /index.php\$request_uri;
        expires 6M;         # Cache-Control policy borrowed from \`.htaccess\`
        access_log off;     # Optional: Don't log access to assets
    }
    location ~ \\.woff2?$ {
        try_files \$uri /index.php\$request_uri;
        expires 7d;         # Cache-Control policy borrowed from \`.htaccess\`
        access_log off;     # Optional: Don't log access to assets
    }
    location / {
        try_files \$uri \$uri/ /index.php\$request_uri;
    }
EOF
    config_service_nginx
}

#编译&&安装php
compile_php()
{
    local swap="$(free -b | tail -n 1 | awk '{print $2}')"
    local use_swap=0
    swap_on()
    {
        if (($(free -m | sed -n 2p | awk '{print $2}')+$(free -m | tail -n 1 | awk '{print $2}')<1800)); then
            tyblue "内存不足2G，自动申请swap。。"
            use_swap=1
            swapoff -a
            if ! dd if=/dev/zero of=${temp_dir}/swap bs=1M count=$((1800-$(free -m | sed -n 2p | awk '{print $2}'))); then
                red   "开启swap失败！"
                yellow "可能是机器内存和硬盘空间都不足"
                green  "欢迎进行Bug report(https://github.com/kirin10000/Xray-script/issues)，感谢您的支持"
                yellow "按回车键继续或者Ctrl+c退出"
                read -s
            fi
            chmod 0600 ${temp_dir}/swap
            mkswap ${temp_dir}/swap
            swapon ${temp_dir}/swap
        fi
    }
    swap_off()
    {
        if [ $use_swap -eq 1 ]; then
            tyblue "恢复swap。。。"
            swapoff -a
            [ "$swap" -ne '0' ] && swapon -a
        fi
    }
    green "正在编译php。。。。"
    if ! wget -O "${php_version}.tar.xz" "https://www.php.net/distributions/${php_version}.tar.xz"; then
        red    "获取php失败"
        yellow "按回车键继续或者按ctrl+c终止"
        read -s
    fi
    tar -xJf "${php_version}.tar.xz"
    cd "${php_version}"
    sed -i 's#db$THIS_VERSION/db_185.h include/db$THIS_VERSION/db_185.h include/db/db_185.h#& include/db_185.h#' configure
    if [ $release == "ubuntu" ] || [ $release == "other-debian" ]; then
        sed -i 's#if test -f $THIS_PREFIX/$PHP_LIBDIR/lib$LIB\.a || test -f $THIS_PREFIX/$PHP_LIBDIR/lib$LIB\.$SHLIB_SUFFIX_NAME#& || true#' configure
        sed -i 's#if test ! -r "$PDO_FREETDS_INSTALLATION_DIR/$PHP_LIBDIR/libsybdb\.a" && test ! -r "$PDO_FREETDS_INSTALLATION_DIR/$PHP_LIBDIR/libsybdb\.so"#& \&\& false#' configure
        ./configure --prefix=${php_prefix} --enable-embed=shared --enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data --with-fpm-systemd --with-fpm-acl --with-fpm-apparmor --disable-phpdbg --with-layout=GNU --with-openssl --with-kerberos --with-external-pcre --with-pcre-jit --with-zlib --enable-bcmath --with-bz2 --enable-calendar --with-curl --enable-dba --with-qdbm --with-db4 --with-db1 --with-tcadb --with-lmdb --with-enchant --enable-exif --with-ffi --enable-ftp --enable-gd --with-external-gd --with-webp --with-jpeg --with-xpm --with-freetype --enable-gd-jis-conv --with-gettext --with-gmp --with-mhash --with-imap --with-imap-ssl --enable-intl --with-ldap --with-ldap-sasl --enable-mbstring --with-mysqli --with-mysql-sock --with-unixODBC --enable-pcntl --with-pdo-dblib --with-pdo-mysql --with-zlib-dir --with-pdo-odbc=unixODBC,/usr --with-pdo-pgsql --with-pgsql --with-pspell --with-libedit --with-mm --enable-shmop --with-snmp --enable-soap --enable-sockets --with-sodium --with-password-argon2 --enable-sysvmsg --enable-sysvsem --enable-sysvshm --with-tidy --with-xsl --with-zip --enable-mysqlnd --with-pear CPPFLAGS="-g0 -O3" CFLAGS="-g0 -O3" CXXFLAGS="-g0 -O3"
    else
        ./configure --prefix=${php_prefix} --with-libdir=lib64 --enable-embed=shared --enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data --with-fpm-systemd --with-fpm-acl --disable-phpdbg --with-layout=GNU --with-openssl --with-kerberos --with-external-pcre --with-pcre-jit --with-zlib --enable-bcmath --with-bz2 --enable-calendar --with-curl --enable-dba --with-gdbm --with-db4 --with-db1 --with-tcadb --with-lmdb --with-enchant --enable-exif --with-ffi --enable-ftp --enable-gd --with-external-gd --with-webp --with-jpeg --with-xpm --with-freetype --enable-gd-jis-conv --with-gettext --with-gmp --with-mhash --with-imap --with-imap-ssl --enable-intl --with-ldap --with-ldap-sasl --enable-mbstring --with-mysqli --with-mysql-sock --with-unixODBC --enable-pcntl --with-pdo-dblib --with-pdo-mysql --with-zlib-dir --with-pdo-odbc=unixODBC,/usr --with-pdo-pgsql --with-pgsql --with-pspell --with-libedit --enable-shmop --with-snmp --enable-soap --enable-sockets --with-sodium --with-password-argon2 --enable-sysvmsg --enable-sysvsem --enable-sysvshm --with-tidy --with-xsl --with-zip --enable-mysqlnd --with-pear CPPFLAGS="-g0 -O3" CFLAGS="-g0 -O3" CXXFLAGS="-g0 -O3"
    fi
    swap_on
    if ! make; then
        swap_off
        red    "php编译失败！"
        green  "欢迎进行Bug report(https://github.com/kirin10000/Xray-script/issues)，感谢您的支持"
        yellow "在Bug修复前，建议使用Ubuntu最新版系统"
        exit 1
    fi
    swap_off
    cd ..
}
install_php_part1()
{
    green "正在安装php。。。。"
    cd "${php_version}"
    make install
    cp sapi/fpm/php-fpm.service ${php_prefix}/php-fpm.service.default
    cd ..
}
instal_php_imagick()
{
    if ! git clone https://github.com/Imagick/imagick; then
        yellow "获取php-imagick源码失败"
        yellow "按回车键继续或者按ctrl+c终止"
        read -s
    fi
    cd imagick
    ${php_prefix}/bin/phpize
    ./configure --with-php-config=${php_prefix}/bin/php-config CFLAGS="-g0 -O3"
    if ! make; then
        yellow "php-imagick编译失败"
        green  "欢迎进行Bug report(https://github.com/kirin10000/Xray-script/issues)，感谢您的支持"
        yellow "在Bug修复前，建议使用Ubuntu最新版系统"
        yellow "按回车键继续或者按ctrl+c终止"
        read -s
    fi
    local php_lib="$(${php_prefix}/bin/php -i | grep "^extension_dir" | awk '{print $3}')"
    mv modules/imagick.so "$php_lib"
    cd ..
}
install_php_part2()
{
    useradd -r -s /bin/bash www-data
    cp ${php_prefix}/etc/php-fpm.conf.default ${php_prefix}/etc/php-fpm.conf
    cp ${php_prefix}/etc/php-fpm.d/www.conf.default ${php_prefix}/etc/php-fpm.d/www.conf
    sed -i '/^[ \t]*listen[ \t]*=/d' ${php_prefix}/etc/php-fpm.d/www.conf
    echo "listen = /dev/shm/php-fpm_unixsocket/php.sock" >> ${php_prefix}/etc/php-fpm.d/www.conf
    sed -i '/^[ \t]*env\[PATH\][ \t]*=/d' ${php_prefix}/etc/php-fpm.d/www.conf
    echo "env[PATH] = $PATH" >> ${php_prefix}/etc/php-fpm.d/www.conf
    instal_php_imagick
cat > ${php_prefix}/etc/php.ini << EOF
[PHP]
memory_limit=-1
upload_max_filesize=-1
extension=imagick.so
zend_extension=opcache.so
opcache.enable=1
EOF
    systemctl --now disable php-fpm
    rm -rf /etc/systemd/system/php-fpm.service
    cp ${php_prefix}/php-fpm.service.default /etc/systemd/system/php-fpm.service
cat >> /etc/systemd/system/php-fpm.service <<EOF

[Service]
ProtectSystem=false
ExecStartPre=/bin/rm -rf /dev/shm/php-fpm_unixsocket
ExecStartPre=/bin/mkdir /dev/shm/php-fpm_unixsocket
ExecStartPre=/bin/chmod 711 /dev/shm/php-fpm_unixsocket
ExecStopPost=/bin/rm -rf /dev/shm/php-fpm_unixsocket
EOF
    systemctl daemon-reload
}

#安装/更新Xray
install_update_xray()
{
    green "正在安装/更新Xray。。。。"
    if ! bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root --without-geodata && ! bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root --without-geodata; then
        red    "安装/更新Xray失败"
        yellow "按回车键继续或者按ctrl+c终止"
        read -s
        return 1
    fi
}

#获取证书 参数: domain domainconfig
get_cert()
{
    mv $xray_config $xray_config.bak
    echo "{}" > $xray_config
    if [ $2 -eq 1 ]; then
        local temp="-d www.$1"
    else
        local temp=""
    fi
    if ! $HOME/.acme.sh/acme.sh --issue -d $1 $temp -w ${nginx_prefix}/html/issue_certs -k ec-256 -ak ec-256 --pre-hook "mv ${nginx_prefix}/conf/nginx.conf ${nginx_prefix}/conf/nginx.conf.bak && cp ${nginx_prefix}/conf/issue_certs.conf ${nginx_prefix}/conf/nginx.conf && sleep 2s && systemctl restart nginx" --post-hook "mv ${nginx_prefix}/conf/nginx.conf.bak ${nginx_prefix}/conf/nginx.conf && sleep 2s && systemctl restart nginx" --ocsp; then
        $HOME/.acme.sh/acme.sh --issue -d $1 $temp -w ${nginx_prefix}/html/issue_certs -k ec-256 -ak ec-256 --pre-hook "mv ${nginx_prefix}/conf/nginx.conf ${nginx_prefix}/conf/nginx.conf.bak && cp ${nginx_prefix}/conf/issue_certs.conf ${nginx_prefix}/conf/nginx.conf && sleep 2s && systemctl restart nginx" --post-hook "mv ${nginx_prefix}/conf/nginx.conf.bak ${nginx_prefix}/conf/nginx.conf && sleep 2s && systemctl restart nginx" --ocsp --debug
    fi
    if ! $HOME/.acme.sh/acme.sh --installcert -d $1 --key-file ${nginx_prefix}/certs/${1}.key --fullchain-file ${nginx_prefix}/certs/${1}.cer --reloadcmd "sleep 2s && systemctl restart xray" --ecc; then
        $HOME/.acme.sh/acme.sh --remove --domain $1 --ecc
        rm -rf $HOME/.acme.sh/${1}_ecc
        rm -rf "${nginx_prefix}/certs/${1}.key" "${nginx_prefix}/certs/${1}.cer"
        mv $xray_config.bak $xray_config
        return 1
    fi
    mv $xray_config.bak $xray_config
    return 0
}
get_all_certs()
{
    local i
    for ((i=0;i<${#domain_list[@]};i++))
    do
        if ! get_cert ${domain_list[$i]} ${domainconfig_list[$i]}; then
            red    "域名\"${domain_list[$i]}\"证书安装失败！"
            yellow "请检查："
            yellow "    1.域名是否解析正确"
            yellow "    2.vps防火墙80端口是否开放"
            yellow "并在安装完成后，使用脚本主菜单\"重置域名\"选项修复"
            yellow "按回车键继续。。。"
            read -s
        fi
    done
}

#配置nginx
config_nginx_init()
{
cat > ${nginx_prefix}/conf/nginx.conf <<EOF

user  root root;
worker_processes  auto;

#error_log  logs/error.log;
#error_log  logs/error.log  notice;
#error_log  logs/error.log  info;

#pid        logs/nginx.pid;
google_perftools_profiles /dev/shm/nginx_tcmalloc/tcmalloc;

events {
    worker_connections  1024;
}


http {
    include       mime.types;
    default_type  application/octet-stream;

    #log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
    #                  '\$status \$body_bytes_sent "\$http_referer" '
    #                  '"\$http_user_agent" "\$http_x_forwarded_for"';

    #access_log  logs/access.log  main;

    sendfile        on;
    #tcp_nopush     on;

    #keepalive_timeout  0;
    keepalive_timeout  65;

    #gzip  on;

    include       $nginx_config;
    #server {
        #listen       80;
        #server_name  localhost;

        #charset koi8-r;

        #access_log  logs/host.access.log  main;

        #location / {
        #    root   html;
        #    index  index.html index.htm;
        #}

        #error_page  404              /404.html;

        # redirect server error pages to the static page /50x.html
        #
        #error_page   500 502 503 504  /50x.html;
        #location = /50x.html {
        #    root   html;
        #}

        # proxy the PHP scripts to Apache listening on 127.0.0.1:80
        #
        #location ~ \\.php\$ {
        #    proxy_pass   http://127.0.0.1;
        #}

        # pass the PHP scripts to FastCGI server listening on 127.0.0.1:9000
        #
        #location ~ \\.php\$ {
        #    root           html;
        #    fastcgi_pass   127.0.0.1:9000;
        #    fastcgi_index  index.php;
        #    fastcgi_param  SCRIPT_FILENAME  /scripts\$fastcgi_script_name;
        #    include        fastcgi_params;
        #}

        # deny access to .htaccess files, if Apache's document root
        # concurs with nginx's one
        #
        #location ~ /\\.ht {
        #    deny  all;
        #}
    #}


    # another virtual host using mix of IP-, name-, and port-based configuration
    #
    #server {
    #    listen       8000;
    #    listen       somename:8080;
    #    server_name  somename  alias  another.alias;

    #    location / {
    #        root   html;
    #        index  index.html index.htm;
    #    }
    #}


    # HTTPS server
    #
    #server {
    #    listen       443 ssl;
    #    server_name  localhost;

    #    ssl_certificate      cert.pem;
    #    ssl_certificate_key  cert.key;

    #    ssl_session_cache    shared:SSL:1m;
    #    ssl_session_timeout  5m;

    #    ssl_ciphers  HIGH:!aNULL:!MD5;
    #    ssl_prefer_server_ciphers  on;

    #    location / {
    #        root   html;
    #        index  index.html index.htm;
    #    }
    #}

}
EOF
}
config_nginx()
{
    config_nginx_init
    local i
    get_all_domains
cat > $nginx_config<<EOF
server {
    listen 80 reuseport default_server;
    listen [::]:80 reuseport default_server;
    return 301 https://${all_domains[0]};
}
server {
    listen 80;
    listen [::]:80;
    server_name ${all_domains[@]};
    return 301 https://\$host\$request_uri;
}
server {
    listen unix:/dev/shm/nginx_unixsocket/default.sock default_server;
    listen unix:/dev/shm/nginx_unixsocket/h2.sock http2 default_server;
    return 301 https://${all_domains[0]};
}
EOF
    for ((i=0;i<${#domain_list[@]};i++))
    do
cat >> $nginx_config<<EOF
server {
    listen unix:/dev/shm/nginx_unixsocket/default.sock;
    listen unix:/dev/shm/nginx_unixsocket/h2.sock http2;
EOF
        if [ ${domainconfig_list[i]} -eq 1 ]; then
            echo "    server_name www.${domain_list[i]} ${domain_list[i]};" >> $nginx_config
        else
            echo "    server_name ${domain_list[i]};" >> $nginx_config
        fi
        echo '    add_header Strict-Transport-Security "max-age=63072000; includeSubdomains; preload" always;' >> $nginx_config
        if [ ${pretend_list[i]} -eq 1 ]; then
            echo "    return 403;" >> $nginx_config
        elif [ ${pretend_list[i]} -eq 2 ]; then
cat >> $nginx_config<<EOF
    location / {
        proxy_pass https://v.qq.com;
        proxy_set_header referer "https://v.qq.com";
    }
EOF
        else
            echo "    root ${nginx_prefix}/html/${domain_list[i]};" >> $nginx_config
            [ ${pretend_list[i]} -eq 4 ] && echo "    include ${nginx_prefix}/conf.d/nextcloud.conf;" >> $nginx_config
        fi
        echo "}" >> $nginx_config
    done
}

#配置xray
config_xray()
{
    local i
cat > $xray_config <<EOF
{
    "log": {
        "loglevel": "none"
    },
    "inbounds": [
        {
            "port": 443,
            "protocol": "vless",
            "settings": {
EOF
    if [ $protocol_1 -eq 1 ]; then
cat >> $xray_config <<EOF
                "clients": [
                    {
                        "id": "$xid_1",
                        "flow": "xtls-rprx-direct"
                    }
                ],
EOF
    fi
    echo '                "decryption": "none",' >> $xray_config
    echo '                "fallbacks": [' >> $xray_config
    if [ $protocol_2 -ne 0 ]; then
cat >> $xray_config <<EOF
                    {
                        "path": "$path",
                        "dest": "@/dev/shm/xray/ws.sock"
                    },
EOF
    fi
cat >> $xray_config <<EOF
                    {
                        "alpn": "h2",
                        "dest": "/dev/shm/nginx_unixsocket/h2.sock"
                    },
                    {
                        "dest": "/dev/shm/nginx_unixsocket/default.sock"
                    }
                ]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "xtls",
                "xtlsSettings": {
                    "alpn": [
                        "h2",
                        "http/1.1"
                    ],
                    "minVersion": "1.2",
                    "cipherSuites": "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256:TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
                    "certificates": [
EOF
    for ((i=0;i<${#domain_list[@]};i++))
    do
cat >> $xray_config <<EOF
                        {
                            "certificateFile": "${nginx_prefix}/certs/${domain_list[i]}.cer",
                            "keyFile": "${nginx_prefix}/certs/${domain_list[i]}.key",
                            "ocspStapling": 3600
EOF
        if (($i==${#domain_list[@]}-1)); then
            echo "                        }" >> $xray_config
        else
            echo "                        }," >> $xray_config
        fi
    done
cat >> $xray_config <<EOF
                    ]
                }
            }
EOF
    if [ $protocol_2 -ne 0 ]; then
        echo '        },' >> $xray_config
        echo '        {' >> $xray_config
        echo '            "listen": "@/dev/shm/xray/ws.sock",' >> $xray_config
        if [ $protocol_2 -eq 2 ]; then
            echo '            "protocol": "vmess",' >> $xray_config
        else
            echo '            "protocol": "vless",' >> $xray_config
        fi
        echo '            "settings": {' >> $xray_config
        echo '                "clients": [' >> $xray_config
        echo '                    {' >> $xray_config
        echo "                        \"id\": \"$xid_2\"" >> $xray_config
        echo '                    }' >> $xray_config
        if [ $protocol_2 -eq 2 ]; then
            echo '                ]' >> $xray_config
        else
            echo '                ],' >> $xray_config
            echo '                "decryption": "none"' >> $xray_config
        fi
cat >> $xray_config <<EOF
            },
            "streamSettings": {
                "network": "ws",
                "wsSettings": {
                    "path": "$path"
                }
            }
EOF
    fi
cat >> $xray_config <<EOF
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom"
        }
    ]
}
EOF
}

#下载nextcloud模板，用于伪装    参数: domain pretend
get_web()
{
    ([ $2 -eq 1 ] || [ $2 -eq 2 ]) && return 0
    local url
    [ $2 -eq 4 ] && url="${nextcloud_url}"
    [ $2 -eq 3 ] && url="https://github.com/CoolCollin/Xray-script/raw/main/soccer.zip"
    local info
    [ $2 -eq 4 ] && info="Nextcloud"
    [ $2 -eq 3 ] && info="网站模板"
    if ! wget -O "${nginx_prefix}/html/Website.zip" "$url"; then
        red    "获取${info}失败"
        yellow "按回车键继续或者按ctrl+c终止"
        read -s
    fi
    rm -rf "${nginx_prefix}/html/$1"
    if [ $2 -eq 3 ]; then
        mkdir "${nginx_prefix}/html/$1"
        unzip -q -d "${nginx_prefix}/html/$1" "${nginx_prefix}/html/Website.zip"
    else
        unzip -q -d "${nginx_prefix}/html" "${nginx_prefix}/html/Website.zip"
        mv "${nginx_prefix}/html/nextcloud" "${nginx_prefix}/html/$1"
        chown -R www-data:www-data "${nginx_prefix}/html/$1"
    fi
    rm -rf "${nginx_prefix}/html/Website.zip"
}
get_all_webs()
{
    local i
    for ((i=0;i<${#domain_list[@]};i++))
    do
        get_web ${domain_list[i]} ${pretend_list[i]}
    done
}

turn_on_off_php()
{
    local need_php=0
    local i
    for i in ${!pretend_list[@]}
    do
        [ ${pretend_list[$i]} -eq 4 ] && need_php=1 && break
    done
    if [ $need_php -eq 1 ]; then
        systemctl --now enable php-fpm
    else
        systemctl --now disable php-fpm
    fi
}

#参数 1:域名在列表中的位置
let_init_nextcloud()
{
    local temp_domain="${domain_list[$1]}"
    [ ${domainconfig_list[$1]} -eq 1 ] && temp_domain="www.${temp_domain}"
    echo -e "\n\n"
    yellow "请立即打开\"https://${temp_domain}\"进行Nextcloud初始化设置："
    tyblue " 1.自定义管理员的用户名和密码"
    tyblue " 2.数据库类型选择SQLite"
    tyblue " 3.建议不勾选\"安装推荐的应用\"，因为进去之后还能再安装"
    sleep 15s
    echo -e "\n\n"
    yellow "请在确认完成初始化后，再按两次回车键以继续。。。"
    read -s
    read -s
    cd "${nginx_prefix}/html/${domain_list[$1]}"
    sudo -u www-data ${php_prefix}/bin/php occ db:add-missing-indices
    cd -
}

echo_end()
{
    get_all_domains
    echo -e "\n\n\n"
    if [ $protocol_1 -ne 0 ]; then
        tyblue "---------------------- Xray-TCP+XTLS+Web (不走CDN) ---------------------"
        tyblue " 服务器类型            ：VLESS"
        tyblue " address(地址)         ：服务器ip"
        purple "  (Qv2ray:主机)"
        tyblue " port(端口)            ：443"
        tyblue " id(用户ID/UUID)       ：${xid_1}"
        tyblue " flow(流控)            ：使用XTLS ：Linux/安卓/路由器:xtls-rprx-splice\033[32m(推荐)\033[36m或xtls-rprx-direct"
        tyblue "                                    其它:xtls-rprx-direct"
        tyblue "                         使用TLS  ：空"
        tyblue " encryption(加密)      ：none"
        tyblue " ---Transport/StreamSettings(底层传输方式/流设置)---"
        tyblue "  network(传输协议)             ：tcp"
        purple "   (Shadowrocket:传输方式:none)"
        tyblue "  type(伪装类型)                ：none"
        purple "   (Qv2ray:协议设置-类型)"
        tyblue "  security(传输层加密)          ：xtls\033[32m(推荐)\033[36m或tls \033[35m(此选项将决定是使用XTLS还是TLS)"
        purple "   (V2RayN(G):底层传输安全;Qv2ray:TLS设置-安全类型)"
        if [ ${#all_domains[@]} -eq 1 ]; then
            tyblue "  serverName(验证服务端证书域名)：${all_domains[@]}"
        else
            tyblue "  serverName(验证服务端证书域名)：${all_domains[@]} \033[35m(任选其一)"
        fi
        purple "   (V2RayN(G):伪装域名;Qv2ray:TLS设置-服务器地址;Shadowrocket:Peer 名称)"
        tyblue "  allowInsecure                 ：false"
        purple "   (Qv2ray:允许不安全的证书(不打勾);Shadowrocket:允许不安全(关闭))"
        tyblue " ------------------------其他-----------------------"
        tyblue "  Mux(多路复用)                 ：使用XTLS必须关闭;不使用XTLS也建议关闭"
        tyblue "  Sniffing(流量探测)            ：建议开启"
        purple "   (Qv2ray:首选项-入站设置-SOCKS设置-嗅探)"
        tyblue "------------------------------------------------------------------------"
        echo
        green  " 目前支持支持XTLS的图形化客户端："
        green  "   Windows    ：Qv2ray       v2.7.0-pre1+    V2RayN  v3.26+"
        green  "   Android    ：V2RayNG      v1.4.8+"
        green  "   Linux/MacOS：Qv2ray       v2.7.0-pre1+"
        green  "   IOS        ：Shadowrocket v2.1.67+"
    fi
    if [ $protocol_2 -ne 0 ]; then
        echo
        tyblue "-------------- Xray-WebSocket+TLS+Web (如果有CDN，会走CDN) -------------"
        if [ $protocol_2 -eq 1 ]; then
            tyblue " 服务器类型            ：VLESS"
        else
            tyblue " 服务器类型            ：VMess"
        fi
        if [ ${#all_domains[@]} -eq 1 ]; then
            tyblue " address(地址)         ：${all_domains[@]}"
        else
            tyblue " address(地址)         ：${all_domains[@]} \033[35m(任选其一)"
        fi
        purple "  (Qv2ray:主机)"
        tyblue " port(端口)            ：443"
        tyblue " id(用户ID/UUID)       ：${xid_2}"
        if [ $protocol_2 -eq 1 ]; then
            tyblue " flow(流控)            ：空"
            tyblue " encryption(加密)      ：none"
        else
            tyblue " alterId(额外ID)       ：0"
            tyblue " security(加密方式)    ：使用CDN，推荐auto;不使用CDN，推荐none"
            purple "  (Qv2ray:安全选项;Shadowrocket:算法)"
        fi
        tyblue " ---Transport/StreamSettings(底层传输方式/流设置)---"
        tyblue "  network(传输协议)             ：ws"
        purple "   (Shadowrocket:传输方式:websocket)"
        tyblue "  path(路径)                    ：${path}"
        tyblue "  Host                          ：空"
        purple "   (V2RayN(G):伪装域名;Qv2ray:协议设置-请求头)"
        tyblue "  security(传输层加密)          ：tls"
        purple "   (V2RayN(G):底层传输安全;Qv2ray:TLS设置-安全类型)"
        tyblue "  serverName(验证服务端证书域名)：空"
        purple "   (V2RayN(G):伪装域名;Qv2ray:TLS设置-服务器地址;Shadowrocket:Peer 名称)"
        tyblue "  allowInsecure                 ：false"
        purple "   (Qv2ray:允许不安全的证书(不打勾);Shadowrocket:允许不安全(关闭))"
        tyblue " ------------------------其他-----------------------"
        tyblue "  Mux(多路复用)                 ：建议关闭"
        tyblue "  Sniffing(流量探测)            ：建议开启"
        purple "   (Qv2ray:首选项-入站设置-SOCKS设置-嗅探)"
        tyblue "------------------------------------------------------------------------"
    fi
    echo
    yellow " 若使用VMess，请尽快将客户端升级至 Xray 或 V2Ray v4.28.0+ 以启用VMessAEAD"
    yellow " 若使用VLESS，请确保客户端为 Xray 或 V2Ray v4.30.0+"
    yellow " 若使用XTLS，请确保客户端为 Xray 或 V2Ray v4.31.0至v4.32.1"
    yellow " 若使用xtls-rprx-splice，请确保客户端为 Xray v1.1.0+"
    echo
    tyblue " 如果要更换被镜像的伪装网站"
    tyblue " 修改$nginx_config"
    tyblue " 将v.qq.com修改为你要镜像的网站"
    echo
    tyblue " 脚本最后更新时间：2020.12.01"
    echo
    red    " 此脚本仅供交流学习使用，请勿使用此脚本行违法之事。网络非法外之地，行非法之事，必将接受法律制裁!!!!"
    tyblue " 2020.11"
}

#删除所有域名
remove_all_domains()
{
    for i in ${!domain_list[@]}
    do
        rm -rf ${nginx_prefix}/html/${domain_list[$i]}
    done
    unset domain_list
    unset domainconfig_list
    unset pretend_list
}

#获取配置信息 protocol_1 xid_1 protocol_2 xid_2 path
get_base_information()
{
    if [ $(grep '"clients"' $xray_config | wc -l) -eq 2 ] || [ $(grep -E '"(vmess|vless)"' $xray_config | wc -l) -eq 1 ]; then
        protocol_1=1
        xid_1=$(grep '"id"' $xray_config | head -n 1)
        xid_1=${xid_1##*' '}
        xid_1=${xid_1#*'"'}
        xid_1=${xid_1%'"'*}
    else
        protocol_1=0
        xid_1=""
    fi
    if [ $(grep -E '"(vmess|vless)"' $xray_config | wc -l) -eq 2 ]; then
        grep -q '"vmess"' $xray_config && protocol_2=2 || protocol_2=1
        path=$(grep '"path"' $xray_config)
        path=${path##*' '}
        path=${path#*'"'}
        path=${path%'"'*}
        xid_2=$(grep '"id"' $xray_config | tail -n 1)
        xid_2=${xid_2##*' '}
        xid_2=${xid_2#*'"'}
        xid_2=${xid_2%'"'*}
    else
        protocol_2=0
        path=""
        xid_2=""
    fi
}

#获取域名列表
get_domainlist()
{
    unset domain_list
    unset domainconfig_list
    unset pretend_list
    domain_list=($(grep '^[ '$'\t]*server_name[ '$'\t].*;' $nginx_config | cut -d ';' -f 1 | awk 'NR>1 {print $NF}'))
    local line
    local i
    for i in ${!domain_list[@]}
    do
        line=$(grep -n "server_name www.${domain_list[i]} ${domain_list[i]};" $nginx_config | tail -n 1 | awk -F : '{print $1}')
        if [ "$line" == "" ]; then
            line=$(grep -n "server_name ${domain_list[i]};" $nginx_config | tail -n 1 | awk -F : '{print $1}')
            domainconfig_list[i]=2
        else
            domainconfig_list[i]=1
        fi
        if awk 'NR=='"$(($line+2))"' {print $0}' $nginx_config | grep -q "return 403"; then
            pretend_list[i]=1
        elif awk 'NR=='"$(($line+2))"' {print $0}' $nginx_config | grep -q "location / {"; then
            pretend_list[i]=2
        elif awk 'NR=='"$(($line+3))"' {print $0}' $nginx_config | grep -qw "nextcloud.conf"; then
            pretend_list[i]=4
        else
            pretend_list[i]=3
        fi
    done
}

install_dependence()
{
    if [ $release == "ubuntu" ] || [ $release == "other-debian" ]; then
        if ! apt -y --no-install-recommends install $@; then
            apt update
            if ! apt -y --no-install-recommends install $@; then
                yellow "依赖安装失败！！"
                green  "欢迎进行Bug report(https://github.com/kirin10000/Xray-script/issues)，感谢您的支持"
                yellow "按回车键继续或者ctrl+c退出"
                read -s
            fi
        fi
    else
        if $redhat_package_manager --help | grep -q "\-\-enablerepo="; then
            local temp_redhat_install="$redhat_package_manager -y --enablerepo="
        else
            local temp_redhat_install="$redhat_package_manager -y --enablerepo "
        fi
        if ! $redhat_package_manager -y install $@; then
            if [ "$release" == "centos" ] && version_ge $systemVersion 8 && $temp_redhat_install"epel,PowerTools" install $@;then
                return 0
            fi
            if $temp_redhat_install'*' install $@; then
                return 0
            fi
            yellow "依赖安装失败！！"
            green  "欢迎进行Bug report(https://github.com/kirin10000/Xray-script/issues)，感谢您的支持"
            yellow "按回车键继续或者ctrl+c退出"
            read -s
        fi
    fi
}
install_base_dependence()
{
    if [ $release == "centos" ] || [ $release == "fedora" ] || [ $release == "other-redhat" ]; then
        install_dependence wget unzip curl openssl crontabs gcc gcc-c++ make
    else
        install_dependence wget unzip curl openssl cron gcc g++ make
    fi
}
install_nginx_dependence()
{
    if [ $release == "centos" ] || [ $release == "fedora" ] || [ $release == "other-redhat" ]; then
        install_dependence gperftools-devel libatomic_ops-devel pcre-devel libxml2-devel libxslt-devel zlib-devel gd-devel perl-ExtUtils-Embed perl-Data-Dumper perl-IPC-Cmd geoip-devel lksctp-tools-devel
    else
        install_dependence libgoogle-perftools-dev libatomic-ops-dev libperl-dev libxml2-dev libxslt1-dev zlib1g-dev libpcre3-dev libgeoip-dev libgd-dev libsctp-dev
    fi
}
install_php_dependence()
{
    if [ $release == "centos" ] || [ $release == "fedora" ] || [ $release == "other-redhat" ]; then
        install_dependence pkgconf-pkg-config libxml2-devel sqlite-devel systemd-devel libacl-devel openssl-devel krb5-devel pcre2-devel zlib-devel bzip2-devel libcurl-devel gdbm-devel libdb-devel tokyocabinet-devel lmdb-devel enchant-devel libffi-devel libpng-devel gd-devel libwebp-devel libjpeg-turbo-devel libXpm-devel freetype-devel gmp-devel libc-client-devel libicu-devel openldap-devel oniguruma-devel unixODBC-devel freetds-devel libpq-devel aspell-devel libedit-devel net-snmp-devel libsodium-devel libargon2-devel libtidy-devel libxslt-devel libzip-devel autoconf git ImageMagick-devel sudo
    else
        install_dependence pkg-config libxml2-dev libsqlite3-dev libsystemd-dev libacl1-dev libapparmor-dev libssl-dev libkrb5-dev libpcre2-dev zlib1g-dev libbz2-dev libcurl4-openssl-dev libqdbm-dev libdb-dev libtokyocabinet-dev liblmdb-dev libenchant-dev libffi-dev libpng-dev libgd-dev libwebp-dev libjpeg-dev libxpm-dev libfreetype6-dev libgmp-dev libc-client2007e-dev libicu-dev libldap2-dev libsasl2-dev libonig-dev unixodbc-dev freetds-dev libpq-dev libpspell-dev libedit-dev libmm-dev libsnmp-dev libsodium-dev libargon2-dev libtidy-dev libxslt1-dev libzip-dev autoconf git libmagickwand-dev sudo
    fi
}
#安装xray_tls_web
install_update_xray_tls_web()
{
    check_port
    apt -y -f install
    get_system_info
    check_important_dependence_installed ca-certificates ca-certificates
    check_nginx_installed_system
    check_SELinux
    check_ssh_timeout
    uninstall_firewall
    doupdate
    enter_temp_dir
    install_bbr
    apt -y -f install

#读取信息
    if [ $update == 0 ]; then
        readProtocolConfig
        readDomain
    else
        get_base_information
        get_domainlist
    fi

    local install_php
    if [ $update -eq 0 ]; then
        [ ${pretend_list[0]} -eq 4 ] && install_php=1 || install_php=0
    else
        install_php=$php_is_installed
    fi

    green "正在安装依赖。。。。"
    install_base_dependence
    install_nginx_dependence
    [ $install_php -eq 1 ] && install_php_dependence
    apt clean
    $redhat_package_manager clean all

    local use_existed_php=0
    if [ $install_php -eq 1 ]; then
        if [ $update -eq 1 ]; then
            if check_php_update; then
                choice=""
                while [ "$choice" != "y" ] && [ "$choice" != "n" ]
                do
                    tyblue "检测到php有新版本，是否更新?(y/n)"
                    read choice
                done
                [ $choice == n ] && use_existed_php=1
            else
                green "php已经是最新版本，不更新"
                use_existed_php=1
            fi
        elif [ $php_is_installed -eq 1 ]; then
            tyblue "---------------检测到php已存在---------------"
            tyblue " 1. 使用现有php"
            tyblue " 2. 卸载现有php并重新编译安装"
            echo
            yellow " 若安装完成后php无法启动，请卸载并重新安装"
            echo
            choice=""
            while [ "$choice" != "1" ] && [ "$choice" != "2" ]
            do
                read -p "您的选择是：" choice
            done
            [ $choice -eq 1 ] && use_existed_php=1
        fi
    fi

    local use_existed_nginx=0
    if [ $update -eq 1 ]; then
        if check_nginx_update; then
            choice=""
            while [ "$choice" != "y" ] && [ "$choice" != "n" ]
            do
                tyblue "检测到Nginx有新版本，是否更新?(y/n)"
                read choice
            done
            [ $choice == n ] && use_existed_nginx=1
        else
            green "Nginx已经是最新版本，不更新"
            use_existed_nginx=1
        fi
    elif [ $nginx_is_installed -eq 1 ]; then
        tyblue "---------------检测到Nginx已存在---------------"
        tyblue " 1. 使用现有Nginx"
        tyblue " 2. 卸载现有Nginx并重新编译安装"
        echo
        choice=""
        while [ "$choice" != "1" ] && [ "$choice" != "2" ]
        do
            read -p "您的选择是：" choice
        done
        [ $choice -eq 1 ] && use_existed_nginx=1
    fi

    #编译&&安装php
    if [ $install_php -eq 1 ]; then
        if [ $use_existed_php -eq 0 ]; then
            compile_php
            remove_php
            install_php_part1
        else
            systemctl --now disable php-fpm
        fi
        install_php_part2
    fi

    #编译&&安装Nginx
    if [ $use_existed_nginx -eq 0 ]; then
        compile_nginx
        [ $update -eq 1 ] && backup_domains_web
        remove_nginx
        install_nginx_part1
    else
        systemctl --now disable nginx
        rm -rf ${nginx_prefix}/conf.d
        rm -rf ${nginx_prefix}/certs
        rm -rf ${nginx_prefix}/html/issue_certs
        rm -rf ${nginx_prefix}/conf/issue_certs.conf
        cp ${nginx_prefix}/conf/nginx.conf.default ${nginx_prefix}/conf/nginx.conf
    fi
    install_nginx_part2
    if [ $update == 1 ]; then
        [ $use_existed_nginx -eq 0 ] && mv "${temp_dir}/domain_backup/"* ${nginx_prefix}/html 2>/dev/null
    else
        get_all_webs
    fi

    #安装Xray
    remove_xray
    install_update_xray

    green "正在获取证书。。。。"
    if [ $update -eq 0 ]; then
        [ -e $HOME/.acme.sh/acme.sh ] && $HOME/.acme.sh/acme.sh --uninstall
        rm -rf $HOME/.acme.sh
        curl https://get.acme.sh | sh
    fi
    $HOME/.acme.sh/acme.sh --upgrade --auto-upgrade
    get_all_certs

    #配置Nginx和Xray
    if [ $update == 0 ]; then
        path="/$(cat /dev/urandom | head -c 8 | md5sum | head -c 7)"
        xid_1="$(cat /proc/sys/kernel/random/uuid)"
        xid_2="$(cat /proc/sys/kernel/random/uuid)"
    fi
    config_nginx
    config_xray
    sleep 2s
    systemctl restart xray nginx
    turn_on_off_php
    [ $update -eq 0 ] && [ $install_php -eq 1 ] && let_init_nextcloud "0"
    if [ $update == 1 ]; then
        green "-------------------升级完成-------------------"
    else
        green "-------------------安装完成-------------------"
    fi
    echo_end
    rm -rf "$temp_dir"
}

#开始菜单
start_menu()
{
    check_script_update()
    {
        if [[ -z "$file_script" ]]; then
            red "脚本不是文件，无法检查更新"
            exit 1
        fi
        [ "$(md5sum "$file_script" | awk '{print $1}')" == "$(md5sum <(wget -O - "https://github.com/kirin10000/Xray-script/raw/main/Xray-TLS+Web-setup.sh") | awk '{print $1}')" ] && return 1 || return 0
    }
    update_script()
    {
        if [[ -z "$file_script" ]]; then
            red "脚本不是文件，无法更新"
            return 1
        fi
        rm -rf "$file_script"
        if ! wget -O "$file_script" "https://github.com/kirin10000/Xray-script/raw/main/Xray-TLS+Web-setup.sh" && ! wget -O "$file_script" "https://github.com/kirin10000/Xray-script/raw/main/Xray-TLS+Web-setup.sh"; then
            red "获取脚本失败！"
            yellow "按回车键继续或Ctrl+c中止"
            read -s
        fi
        chmod +x "$file_script"
    }
    full_install_php()
    {
        install_base_dependence
        install_php_dependence
        compile_php
        remove_php
        install_php_part1
        install_php_part2
    }
    change_protocol()
    {
        get_base_information
        local protocol_1_old=$protocol_1
        local protocol_2_old=$protocol_2
        readProtocolConfig
        if [ $protocol_1_old -eq $protocol_1 ] && [ $protocol_2_old -eq $protocol_2 ]; then
            red "传输协议未更换"
            return 0
        fi
        [ $protocol_1_old -eq 0 ] && [ $protocol_1 -ne 0 ] && xid_1=$(cat /proc/sys/kernel/random/uuid)
        if [ $protocol_2_old -eq 0 ] && [ $protocol_2 -ne 0 ]; then
            path="/$(cat /dev/urandom | head -c 8 | md5sum | head -c 7)"
            xid_2=$(cat /proc/sys/kernel/random/uuid)
        fi
        get_domainlist
        config_xray
        systemctl restart xray
        green "更换成功！！"
        echo_end
    }
    simplify_system()
    {
        if [ $release == "centos" ] || [ $release == "fedora" ] || [ $release == "other-redhat" ]; then
            yellow "该功能仅对Debian基系统(Ubuntu Debian deepin等)开放"
            return 0
        fi
        if systemctl -q is-active xray || systemctl -q is-active nginx || systemctl -q is-active php-fpm; then
            yellow "请先停止Xray-TLS+Web"
            return 0
        fi
        yellow "警告：如果服务器上有运行别的程序，可能会被误删"
        tyblue "建议在纯净系统下使用此功能"
        local choice=""
        while [ "$choice" != "y" ] && [ "$choice" != "n" ]
        do
            tyblue "是否继续?(y/n)"
            read choice
        done
        [ $choice == n ] && return 0
        apt -y --autoremove purge openssl snapd kdump-tools fwupd flex open-vm-tools make automake '^cloud-init' libffi-dev pkg-config
        apt -y -f install
        get_system_info
        check_important_dependence_installed ca-certificates ca-certificates
        [ $nginx_is_installed -eq 1 ] && install_nginx_dependence
        [ $php_is_installed -eq 1 ] && install_php_dependence
        [ $is_installed -eq 1 ] && install_base_dependence
    }
    change_dns()
    {
        red    "注意！！"
        red    "1.部分云服务商(如阿里云)使用本地服务器作为软件包源，修改dns后需要换源！！"
        red    "  如果不明白，那么请在安装完成后再修改dns，并且修改完后不要重新安装"
        red    "2.Ubuntu系统重启后可能会恢复原dns"
        tyblue "此操作将修改dns服务器为1.1.1.1和1.0.0.1(cloudflare公共dns)"
        choice=""
        while [ "$choice" != "y" -a "$choice" != "n" ]
        do
            tyblue "是否要继续?(y/n)"
            read choice
        done
        if [ $choice == y ]; then
            if ! grep -q "#This file has been edited by Xray-TLS-Web-setup-script" /etc/resolv.conf; then
                sed -i 's/^[ \t]*nameserver[ \t][ \t]*/#&/' /etc/resolv.conf
                echo >> /etc/resolv.conf
                echo 'nameserver 1.1.1.1' >> /etc/resolv.conf
                echo 'nameserver 1.0.0.1' >> /etc/resolv.conf
                echo '#This file has been edited by Xray-TLS-Web-setup-script' >> /etc/resolv.conf
            fi
            green "修改完成！！"
        fi
    }
    local xray_status
    [ $xray_is_installed -eq 1 ] && xray_status="\033[32m已安装" || xray_status="\033[31m未安装"
    systemctl -q is-active xray && xray_status+="                \033[32m运行中" || xray_status+="                \033[31m未运行"
    local nginx_status
    [ $nginx_is_installed -eq 1 ] && nginx_status="\033[32m已安装" || nginx_status="\033[31m未安装"
    systemctl -q is-active nginx && nginx_status+="                \033[32m运行中" || nginx_status+="                \033[31m未运行"
    local php_status
    [ $php_is_installed -eq 1 ] && php_status="\033[32m已安装" || php_status="\033[31m未安装"
    systemctl -q is-active php-fpm && php_status+="                \033[32m运行中" || php_status+="                \033[31m未运行"
    tyblue "---------------------- Xray-TLS(1.3)+Web 搭建/管理脚本 ---------------------"
    echo
    tyblue "            Xray  ：           ${xray_status}"
    echo
    tyblue "            Nginx ：           ${nginx_status}"
    echo
    tyblue "            php   ：           ${php_status}"
    echo
    tyblue "       官网：https://github.com/kirin10000/Xray-script"
    echo
    tyblue "----------------------------------注意事项----------------------------------"
    yellow " 1. 此脚本需要一个解析到本服务器的域名"
    tyblue " 2. 此脚本安装时间较长，详细原因见："
    tyblue "       https://github.com/kirin10000/Xray-script#安装时长说明"
    green  " 3. 建议使用纯净的系统 (VPS控制台-重置系统)"
    green  " 4. 推荐使用Ubuntu最新版系统"
    tyblue "----------------------------------------------------------------------------"
    echo
    echo
    tyblue " -----------安装/升级/卸载-----------"
    if [ $is_installed -eq 0 ]; then
        green  "   1. 安装Xray-TLS+Web"
    else
        green  "   1. 重新安装Xray-TLS+Web"
    fi
    purple "         流程：[升级系统组件]->[安装bbr]->[安装php]->安装Nginx->安装Xray->申请证书->配置文件"
    green  "   2. 升级Xray-TLS+Web"
    purple "         流程：升级脚本->[升级系统组件]->[升级bbr]->[升级php]->[升级Nginx]->升级Xray->升级证书->更新配置文件"
    tyblue "   3. 检查更新/升级脚本"
    tyblue "   4. 升级系统组件"
    tyblue "   5. 安装/检查更新/升级bbr"
    purple "         包含：bbr2/bbrplus/bbr魔改版/暴力bbr魔改版/锐速"
    tyblue "   6. 安装/检查更新/升级php"
    tyblue "   7. 安装/升级Xray"
    red    "   8. 卸载Xray-TLS+Web"
    echo
    tyblue " --------------启动/停止-------------"
    tyblue "   9. 启动/重启Xray-TLS+Web"
    tyblue "  10. 停止Xray-TLS+Web"
    echo
    tyblue " ----------------管理----------------"
    tyblue "  11. 查看配置信息"
    tyblue "  12. 重置域名"
    purple "         将删除所有域名配置，安装过程中域名输错了造成Xray无法启动可以用此选项修复"
    tyblue "  13. 添加域名"
    tyblue "  14. 删除域名"
    tyblue "  15. 修改id(用户ID/UUID)"
    tyblue "  16. 修改path(路径)"
    tyblue "  17. 修改Xray传输协议(TCP/WebSocket)"
    echo
    tyblue " ----------------其它----------------"
    tyblue "  18. 尝试修复退格键无法使用的问题"
    tyblue "  19. 精简系统"
    purple "         删除不必要的系统组件"
    tyblue "  20. 修改dns"
    yellow "  21. 退出脚本"
    echo
    echo
    local choice=""
    while [[ "$choice" != "1" && "$choice" != "2" && "$choice" != "3" && "$choice" != "4" && "$choice" != "5" && "$choice" != "6" && "$choice" != "7" && "$choice" != "8" && "$choice" != "9" && "$choice" != "10" && "$choice" != "11" && "$choice" != "12" && "$choice" != "13" && "$choice" != "14" && "$choice" != "15" && "$choice" != "16" && "$choice" != "17" && "$choice" != "18" && "$choice" != "19" && "$choice" != "20" && "$choice" != "21" ]]
    do
        read -p "您的选择是：" choice
    done
    if [ $choice -eq 9 ] || ((11<=$choice&&$choice<=14)); then
        get_base_information
        get_domainlist
    fi
    if [ $choice -eq 1 ]; then
        install_update_xray_tls_web
    elif [ $choice -eq 2 ]; then
        if [ $is_installed == 0 ]; then
            red "请先安装Xray-TLS+Web！！"
            exit 1
        fi
        yellow "升级bbr/系统可能需要重启，重启后请再次选择'升级Xray-TLS+Web'"
        yellow "按回车键继续，或者Ctrl+c中止"
        read -s
        apt -y -f install
        get_system_info
        check_important_dependence_installed ca-certificates ca-certificates
        update_script && "$file_script" --update
    elif [ $choice -eq 3 ]; then
        apt -y -f install
        get_system_info
        check_important_dependence_installed ca-certificates ca-certificates
        if check_script_update; then
            green "脚本可升级！"
            while [ "$choice" != "y" ] && [ "$choice" != "n" ]
            do
                tyblue "是否升级脚本？(y/n)"
                read choice
            done
            [ $choice == y ] && update_script && green "脚本更新完成"
        else
            green "脚本已经是最新版本"
        fi
    elif [ $choice -eq 4 ]; then
        apt -y -f install
        get_system_info
        doupdate
    elif [ $choice -eq 5 ]; then
        apt -y -f install
        get_system_info
        check_important_dependence_installed ca-certificates ca-certificates
        enter_temp_dir
        install_bbr
        apt -y -f install
        rm -rf "$temp_dir"
    elif [ $choice -eq 6 ]; then
        if [ $php_is_installed -eq 0 ]; then
            while [ "$choice" != "y" ] && [ "$choice" != "n" ]
            do
                tyblue "是否安装php?(y/n)"
                read choice
            done
            [ $choice == n ] && return 0
        fi
        apt -y -f install
        get_system_info
        check_important_dependence_installed ca-certificates ca-certificates
        check_script_update && red "脚本可升级，请先更新脚本" && exit 1
        if [ $php_is_installed -eq 1 ]; then
            if check_php_update; then
                green "检测到php有新版本！"
                choice=""
                while [ "$choice" != "y" ] && [ "$choice" != "n" ]
                do
                    tyblue "是否更新?(y/n)"
                    read choice
                done
                [ $choice == n ] && return 0
                if [ $is_installed -eq 1 ]; then
                    get_base_information
                    get_domainlist
                fi
            else
                green "php已经是最新版本" && return 0
            fi
        fi
        enter_temp_dir
        full_install_php
        [ $is_installed -eq 1 ] && turn_on_off_php
        green "安装完成！"
        rm -rf "$temp_dir"
    elif [ $choice -eq 7 ]; then
        install_update_xray && green "Xray安装/升级完成！"
    elif [ $choice -eq 8 ]; then
        while [ "$choice" != "y" -a "$choice" != "n" ]
        do
            yellow "确定要删除吗?(y/n)"
            read choice
        done
        if [ "$choice" == "n" ]; then
            exit 0
        fi
        remove_xray
        remove_nginx
        remove_php
        $HOME/.acme.sh/acme.sh --uninstall
        rm -rf $HOME/.acme.sh
        green "删除完成！"
    elif [ $choice -eq 9 ]; then
        local need_php=0
        local i
        for i in ${!pretend_list[@]}
        do
            [ ${pretend_list[$i]} -eq 4 ] && need_php=1 && break
        done
        systemctl restart xray nginx
        [ $need_php -eq 1 ] && systemctl restart php-fpm || systemctl stop php-fpm
        sleep 1s
        if ! systemctl -q is-active xray; then
            red "Xray启动失败！！"
        elif ! systemctl -q is-active nginx; then
            red "Nginx启动失败！！"
        elif [ $need_php -eq 1 ] && ! systemctl -q is-active php-fpm; then
            red "php启动失败！！"
        else
            green "重启/启动成功！！"
        fi
    elif [ $choice -eq 10 ]; then
        systemctl stop xray nginx
        [ $php_is_installed -eq 1 ] && systemctl stop php-fpm
        green "已停止！"
    elif [ $choice -eq 11 ]; then
        echo_end
    elif [ $choice -eq 12 ]; then
        if [ $is_installed == 0 ]; then
            red "请先安装Xray-TLS+Web！！"
            exit 1
        fi
        yellow "重置域名将删除所有现有域名(包括域名证书、伪装网站等)"
        while [[ "$choice" != "y" && "$choice" != "n" ]]
        do
            tyblue "是否继续？(y/n)"
            read choice
        done
        if [ $choice == n ]; then
            return 0
        fi
        green "重置域名中。。。"
        apt -y -f install
        get_system_info
        check_important_dependence_installed ca-certificates ca-certificates
        $HOME/.acme.sh/acme.sh --uninstall
        rm -rf $HOME/.acme.sh
        curl https://get.acme.sh | sh
        $HOME/.acme.sh/acme.sh --upgrade --auto-upgrade
        remove_all_domains
        readDomain
        local new_install_php=0
        if [ ${pretend_list[0]} -eq 4 ] && [ $php_is_installed -eq 0 ]; then
            enter_temp_dir
            full_install_php
            new_install_php=1
        fi
        get_all_certs
        get_all_webs
        config_nginx
        config_xray
        sleep 2s
        systemctl restart xray nginx
        turn_on_off_php
        [ ${pretend_list[0]} -eq 4 ] && let_init_nextcloud "0"
        green "域名重置完成！！"
        echo_end
        [ ${new_install_php} -eq 1 ] && rm -rf "$temp_dir"
    elif [ $choice -eq 13 ]; then
        if [ $is_installed == 0 ]; then
            red "请先安装Xray-TLS+Web！！"
            exit 1
        fi
        apt -y -f install
        get_system_info
        check_important_dependence_installed ca-certificates ca-certificates
        readDomain
        local new_install_php=0
        if [ ${pretend_list[-1]} -eq 4 ] && [ $php_is_installed -eq 0 ]; then
            enter_temp_dir
            full_install_php
            new_install_php=1
        fi
        if ! get_cert ${domain_list[-1]} ${domainconfig_list[-1]}; then
            red "申请证书失败！！"
            red "域名添加失败"
            [ ${new_install_php} -eq 1 ] && rm -rf "$temp_dir"
            return 1
        fi
        get_web ${domain_list[-1]} ${pretend_list[-1]}
        config_nginx
        config_xray
        sleep 2s
        systemctl restart xray nginx
        turn_on_off_php
        [ ${pretend_list[-1]} -eq 4 ] && let_init_nextcloud "-1"
        green "域名添加完成！！"
        echo_end
        [ ${new_install_php} -eq 1 ] && rm -rf "$temp_dir"
    elif [ $choice -eq 14 ]; then
        if [ $is_installed == 0 ]; then
            red "请先安装Xray-TLS+Web！！"
            exit 1
        fi
        if [ ${#domain_list[@]} -le 1 ]; then
            red "只有一个域名"
            exit 1
        fi
        local i
        tyblue "-----------------------请选择要删除的域名-----------------------"
        for i in ${!domain_list[@]}
        do
            if [ ${domainconfig_list[i]} -eq 1 ]; then
                tyblue " ${i}. www.${domain_list[i]} ${domain_list[i]}"
            else
                tyblue " ${i}. ${domain_list[i]}"
            fi
        done
        yellow " ${#domain_list[@]}. 不删除"
        local delete=""
        while ! [[ "$delete" =~ ^([1-9][0-9]*|0)$ ]] || [ $delete -gt ${#domain_list[@]} ]
        do
            read -p "你的选择是：" delete
        done
        if [ $delete -eq ${#domain_list[@]} ]; then
            exit 0
        fi
        $HOME/.acme.sh/acme.sh --remove --domain ${domain_list[$delete]} --ecc
        rm -rf $HOME/.acme.sh/${domain_list[$delete]}_ecc
        rm -rf "${nginx_prefix}/certs/${domain_list[$delete]}.key" "${nginx_prefix}/certs/${domain_list[$delete]}.cer"
        rm -rf ${nginx_prefix}/html/${domain_list[$delete]}
        unset domain_list[$delete]
        unset domainconfig_list[$delete]
        unset pretend_list[$delete]
        domain_list=(${domain_list[@]})
        domainconfig_list=(${domainconfig_list[@]})
        pretend_list=(${pretend_list[@]})
        config_nginx
        config_xray
        systemctl restart xray nginx
        turn_on_off_php
        green "域名删除完成！！"
        echo_end
    elif [ $choice -eq 15 ]; then
        if [ $is_installed == 0 ]; then
            red "请先安装Xray-TLS+Web！！"
            exit 1
        fi
        get_base_information
        if [ $protocol_1 -ne 0 ] && [ $protocol_2 -ne 0 ]; then
            tyblue "-------------请输入你要修改的id-------------"
            tyblue " 1. Xray-TCP+XTLS 的id"
            tyblue " 2. Xray-WebSocket+TLS 的id"
            echo
            local flag=""
            while [ "$flag" != "1" -a "$flag" != "2" ]
            do
                read -p "您的选择是：" flag
            done
        elif [ $protocol_1 -ne 0 ]; then
            local flag=1
        else
            local flag=2
        fi
        local xid="xid_$flag"
        tyblue "您现在的id是：${!xid}"
        choice=""
        while [ "$choice" != "y" -a "$choice" != "n" ]
        do
            tyblue "是否要继续?(y/n)"
            read choice
        done
        if [ $choice == "n" ]; then
            exit 0
        fi
        tyblue "-------------请输入新的id-------------"
        read xid
        [ $flag -eq 1 ] && xid_1="$xid" || xid_2="$xid"
        get_domainlist
        config_xray
        systemctl restart xray
        green "更换成功！！"
        echo_end
    elif [ $choice -eq 16 ]; then
        if [ $is_installed == 0 ]; then
            red "请先安装Xray-TLS+Web！！"
            exit 1
        fi
        get_base_information
        if [ $protocol_2 -eq 0 ]; then
            red "Xray-TCP+XTLS+Web模式没有path!!"
            exit 0
        fi
        tyblue "您现在的path是：$path"
        choice=""
        while [ "$choice" != "y" -a "$choice" != "n" ]
        do
            tyblue "是否要继续?(y/n)"
            read choice
        done
        if [ $choice == "n" ]; then
            exit 0
        fi
        local temp_old_path="$path"
        tyblue "---------------请输入新的path(带\"/\")---------------"
        read path
        get_domainlist
        config_xray
        systemctl restart xray
        green "更换成功！！"
        echo_end
    elif [ $choice -eq 17 ]; then
        if [ $is_installed == 0 ]; then
            red "请先安装Xray-TLS+Web！！"
            exit 1
        fi
        change_protocol
    elif [ $choice -eq 18 ]; then
        echo
        yellow "尝试修复退格键异常问题，退格键正常请不要修复"
        yellow "按回车键继续或按Ctrl+c退出"
        read -s
        if stty -a | grep -q 'erase = ^?'; then
            stty erase '^H'
        elif stty -a | grep -q 'erase = ^H'; then
            stty erase '^?'
        fi
        green "修复完成！！"
        sleep 3s
        start_menu
    elif [ $choice -eq 19 ]; then
        apt -y -f install
        get_system_info
        simplify_system
    elif [ $choice -eq 20 ]; then
        change_dns
    fi
}

if ! [ "$1" == "--update" ]; then
    update=0
    start_menu
else
    update=1
    install_update_xray_tls_web
fi
