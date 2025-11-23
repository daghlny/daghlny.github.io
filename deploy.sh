#!/bin/bash

# Hexo 博客一键部署脚本
# 使用方法：./deploy.sh "提交信息"

echo "======================================"
echo "  Hexo 博客部署脚本"
echo "======================================"
echo ""

# 检查是否提供了提交信息
if [ -z "$1" ]; then
    COMMIT_MSG="Update blog: $(date '+%Y-%m-%d %H:%M:%S')"
else
    COMMIT_MSG="$1"
fi

echo "📝 提交信息: $COMMIT_MSG"
echo ""

# 进入 blog 目录
echo "📂 进入 blog 目录..."
cd blog || { echo "❌ 错误: blog 目录不存在"; exit 1; }

# 清理缓存
echo "🧹 清理缓存..."
/opt/homebrew/lib/node_modules/hexo-cli/bin/hexo clean

# 生成静态文件
echo "🔨 生成静态文件..."
/opt/homebrew/lib/node_modules/hexo-cli/bin/hexo generate

if [ $? -ne 0 ]; then
    echo "❌ 生成失败，请检查错误信息"
    exit 1
fi

# 复制到根目录
echo "📋 复制文件到根目录..."
cp -r public/* ..

# 返回根目录
cd ..

# Git 操作
echo "📤 提交到 Git..."
git add .
git commit -m "$COMMIT_MSG"

if [ $? -eq 0 ]; then
    echo "🚀 推送到 GitHub..."
    git push origin main
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "======================================"
        echo "  ✅ 博客发布成功！"
        echo "======================================"
        echo ""
        echo "🌐 访问: https://daghlny.github.io"
        echo "⏰ 请等待 1-2 分钟让 GitHub Pages 更新"
        echo ""
    else
        echo "❌ 推送失败，请检查网络连接和 Git 配置"
        exit 1
    fi
else
    echo "ℹ️  没有需要提交的更改"
fi
