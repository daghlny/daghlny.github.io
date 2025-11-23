# Yinuo's Blog

这是一个使用 Hexo 框架搭建的个人博客，托管在 GitHub Pages 上。

## 博客地址

https://daghlny.github.io

## 本地开发

### 环境要求

- Node.js (v25.2.1 或更高版本)
- npm (v11.6.2 或更高版本)

### 安装依赖

```bash
cd blog
npm install
```

### 本地预览

```bash
cd blog
hexo server
```

然后在浏览器中访问 `http://localhost:4000`

### 创建新文章

```bash
cd blog
hexo new "文章标题"
```

新文章将在 `blog/source/_posts/` 目录下创建。

### 生成静态文件

```bash
cd blog
hexo generate
```

生成的静态文件将保存在 `blog/public/` 目录。

### 部署到 GitHub Pages

1. 生成静态文件：
```bash
cd blog
hexo generate
```

2. 将生成的文件复制到根目录：
```bash
cp -r public/* ..
```

3. 提交并推送到 GitHub：
```bash
cd ..
git add .
git commit -m "Update blog"
git push origin main
```

### 重要说明

- 项目中包含 `.nojekyll` 文件，用于告诉 GitHub Pages 不要使用 Jekyll 构建
- 这个文件位于 `blog/source/.nojekyll`，每次生成时会自动复制到输出目录
- 如果遇到 GitHub Pages 构建错误，请确保根目录和 `blog/source/` 目录都有 `.nojekyll` 文件

## 目录结构

```
.
├── blog/              # Hexo 源文件目录
│   ├── _config.yml    # Hexo 配置文件
│   ├── source/        # 源文件（文章、页面等）
│   ├── themes/        # 主题文件
│   └── public/        # 生成的静态文件
├── index.html         # 博客首页
├── archives/          # 归档页面
├── css/               # 样式文件
├── js/                # JavaScript 文件
└── 2025/              # 按年份组织的文章
```

## 配置说明

博客的主要配置在 `blog/_config.yml` 文件中，包括：

- 网站标题、描述、作者等基本信息
- URL 配置
- 主题设置
- 部署配置

## 主题

当前使用的是 Hexo 默认主题 `landscape`。你可以在 [Hexo 主题列表](https://hexo.io/themes/) 中选择其他主题。

## 快速开始

### 使用一键部署脚本（推荐）

```bash
# 使用默认提交信息
./deploy.sh

# 或使用自定义提交信息
./deploy.sh "添加新文章：我的技术博客"
```

### 手动部署

详细步骤请查看 [HEXO_GUIDE.md](HEXO_GUIDE.md)

## 文档

- 📖 [Hexo 使用指南](HEXO_GUIDE.md) - 详细的博客管理教程
  - 如何创建新文章
  - 如何删除文章
  - 如何编辑文章
  - 本地预览
  - 发布流程
  - 常用命令
  - Markdown 语法

## 更多资源

- [Hexo 官方文档](https://hexo.io/zh-cn/docs/)
- [Hexo 主题](https://hexo.io/themes/)
- [Hexo 插件](https://hexo.io/plugins/)
