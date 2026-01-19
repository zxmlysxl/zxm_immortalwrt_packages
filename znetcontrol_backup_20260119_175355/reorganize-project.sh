#!/bin/bash
# 佐罗上网管控项目结构整理脚本
# 将项目整理成标准ImmortalWrt/LuCI应用结构

set -e  # 遇到错误退出

echo "=============================================="
echo "佐罗上网管控项目结构整理脚本"
echo "=============================================="
echo "当前目录: $(pwd)"
echo ""

# 检查是否在项目根目录
if [ ! -f "Makefile" ]; then
    echo "错误：请在项目根目录运行此脚本"
    exit 1
fi

# 备份原始文件
echo "1. 创建备份..."
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="../znetcontrol_backup_$TIMESTAMP"
mkdir -p "$BACKUP_DIR"
cp -r . "$BACKUP_DIR"
echo "   备份已创建到: $BACKUP_DIR"

# 检查当前结构
echo ""
echo "2. 分析当前项目结构..."
if [ -d "files" ]; then
    echo "   找到 files/ 目录"
    FILES_EXIST=1
else
    echo "   未找到 files/ 目录"
    FILES_EXIST=0
fi

if [ -d "root" ]; then
    echo "   找到 root/ 目录"
    ROOT_EXIST=1
else
    echo "   未找到 root/ 目录"
    ROOT_EXIST=0
fi

# 检查是否有重复的znetcontrol.sh文件
DUPLICATE_FILES=0
if [ -f "files/znetcontrol.sh" ] && [ -f "root/usr/bin/znetcontrol.sh" ]; then
    echo "   发现重复文件: files/znetcontrol.sh 和 root/usr/bin/znetcontrol.sh"
    DUPLICATE_FILES=1
fi

echo ""
echo "3. 开始整理结构..."

# 方案选择
echo ""
echo "请选择整理方案:"
echo "  1) 标准结构 (删除files/, 使用root/为主)"
echo "  2) 保留files/ (移动文件到files/, 清空root/)"
echo "  3) 自定义选择"
echo ""
read -p "请输入选择 (1-3): " CHOICE

case $CHOICE in
    1)
        echo "选择方案1: 标准结构"
        
        if [ $DUPLICATE_FILES -eq 1 ]; then
            echo "   检查重复文件差异..."
            diff -q files/znetcontrol.sh root/usr/bin/znetcontrol.sh > /dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo "   ⚠ 两个文件内容不同！"
                echo "   文件差异:"
                diff -u files/znetcontrol.sh root/usr/bin/znetcontrol.sh | head -20
                echo ""
                read -p "   使用哪个文件？ (1=files/, 2=root/usr/bin/): " FILE_CHOICE
                if [ "$FILE_CHOICE" = "1" ]; then
                    echo "   使用 files/znetcontrol.sh"
                    cp files/znetcontrol.sh root/usr/bin/znetcontrol.sh
                else
                    echo "   使用 root/usr/bin/znetcontrol.sh"
                fi
            else
                echo "   文件内容相同，保留 root/usr/bin/znetcontrol.sh"
            fi
        fi
        
        # 删除files目录
        if [ $FILES_EXIST -eq 1 ]; then
            echo "   删除 files/ 目录..."
            rm -rf files
        fi
        
        # 更新Makefile
        echo "   更新Makefile..."
        sed -i 's|\./files/znetcontrol\.sh|\./root/usr/bin/znetcontrol\.sh|g' Makefile
        
        ;;
        
    2)
        echo "选择方案2: 保留files/结构"
        
        # 创建必要的目录
        mkdir -p files
        
        # 移动文件到files/
        if [ $ROOT_EXIST -eq 1 ]; then
            echo "   移动文件到 files/..."
            
            # 移动脚本
            if [ -f "root/usr/bin/znetcontrol.sh" ]; then
                mv root/usr/bin/znetcontrol.sh files/
                echo "     移动 root/usr/bin/znetcontrol.sh -> files/znetcontrol.sh"
            fi
            
            # 可以添加其他需要移动的文件
            
            # 清空或删除root目录（根据情况）
            echo "   清理 root/ 目录..."
            rm -rf root
            mkdir -p root
        fi
        
        # 更新Makefile
        echo "   更新Makefile..."
        # 如果Makefile中已经是 ./files/znetcontrol.sh，则不需要修改
        ;;
        
    3)
        echo "选择方案3: 自定义整理"
        
        echo ""
        echo "需要移动的文件:"
        echo "  a) znetcontrol.sh 脚本"
        echo "  b) 其他配置文件"
        echo ""
        
        # 询问每个文件
        if [ $DUPLICATE_FILES -eq 1 ]; then
            read -p "移动 znetcontrol.sh 到哪个目录？ (1=files/, 2=root/usr/bin/): " MOVE_CHOICE
            if [ "$MOVE_CHOICE" = "1" ]; then
                echo "   移动到 files/"
                mkdir -p files
                cp root/usr/bin/znetcontrol.sh files/znetcontrol.sh
                rm root/usr/bin/znetcontrol.sh
            else
                echo "   保留在 root/usr/bin/"
                rm files/znetcontrol.sh
            fi
        fi
        
        # 询问是否删除空目录
        read -p "删除空的 files/ 目录？ (y/n): " DEL_FILES
        if [ "$DEL_FILES" = "y" ]; then
            if [ -d "files" ] && [ -z "$(ls -A files)" ]; then
                rm -rf files
                echo "   删除空的 files/ 目录"
            fi
        fi
        
        ;;
        
    *)
        echo "无效选择，退出"
        exit 1
        ;;
esac

# 清理工作
echo ""
echo "4. 清理工作..."

# 删除可能的空目录
find . -type d -empty -not -name "." -not -name ".git" -exec echo "   删除空目录: {}" \; -exec rmdir {} \;

# 验证结构
echo ""
echo "5. 验证最终结构..."
echo "当前项目结构:"
find . -type f -name "*.lua" -o -name "*.sh" -o -name "*.htm" -o -name "Makefile" -o -name "*.json" | sort | sed 's/^/  /'

# 检查Makefile中的安装路径
echo ""
echo "检查Makefile安装路径:"
if grep -q "files/znetcontrol.sh" Makefile; then
    echo "  Makefile引用: files/znetcontrol.sh"
    if [ ! -f "files/znetcontrol.sh" ]; then
        echo "  ⚠ 警告: files/znetcontrol.sh 不存在！"
    fi
fi

if grep -q "root/usr/bin/znetcontrol.sh" Makefile; then
    echo "  Makefile引用: root/usr/bin/znetcontrol.sh"
    if [ ! -f "root/usr/bin/znetcontrol.sh" ]; then
        echo "  ⚠ 警告: root/usr/bin/znetcontrol.sh 不存在！"
    fi
fi

# 创建标准的目录结构（如果缺失）
echo ""
echo "6. 创建标准目录结构..."
mkdir -p root/etc/config
mkdir -p root/etc/init.d
mkdir -p root/etc/uci-defaults
mkdir -p root/usr/bin
mkdir -p root/usr/share/luci/menu.d
mkdir -p root/usr/share/luci/applications.d
mkdir -p root/usr/share/rpcd/acl.d

mkdir -p luasrc/controller
mkdir -p luasrc/model/cbi/znetcontrol
mkdir -p luasrc/view/znetcontrol

echo "   目录结构创建完成"

# 生成README说明
echo ""
echo "7. 生成整理说明..."
cat > REORGANIZE_NOTES.md << EOF
# 项目结构整理说明

## 整理时间
$(date)

## 选择的方案
方案 $CHOICE: $(case $CHOICE in
    1) echo "标准结构 (删除files/, 使用root/为主)" ;;
    2) echo "保留files/ (移动文件到files/, 清空root/)" ;;
    3) echo "自定义整理" ;;
esac)

## 项目结构
\`\`\`
$(find . -type f | sort | sed 's/^/  /')
\`\`\`

## 验证结果
- Makefile安装路径: $(grep -o "znetcontrol\.sh" Makefile | head -1)
- 主要脚本位置: $(find . -name "znetcontrol.sh" -type f | head -1)

## 注意事项
1. 原始文件备份在: $BACKUP_DIR
2. 如果需要恢复，请从备份复制
3. 编译前请测试Makefile是否正确

## 下一步
1. 运行 \`make clean\`
2. 运行 \`make package/luci-app-znetcontrol/compile V=s\`
3. 测试安装包是否正常工作
EOF

echo ""
echo "=============================================="
echo "整理完成！"
echo "=============================================="
echo "✓ 备份已创建: $BACKUP_DIR"
echo "✓ 项目结构已整理"
echo "✓ 整理说明已保存到: REORGANIZE_NOTES.md"
echo ""
echo "请检查以下文件是否存在："
if [ -f "root/usr/bin/znetcontrol.sh" ]; then
    echo "  ✓ root/usr/bin/znetcontrol.sh"
else
    echo "  ✗ root/usr/bin/znetcontrol.sh (缺失)"
fi

if [ -f "root/etc/config/znetcontrol" ]; then
    echo "  ✓ root/etc/config/znetcontrol"
else
    echo "  ✗ root/etc/config/znetcontrol (缺失)"
fi

echo ""
echo "运行以下命令测试："
echo "  make clean"
echo "  make package/luci-app-znetcontrol/compile V=s"
echo ""
