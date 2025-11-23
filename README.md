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

## 更多信息

- [Hexo 官方文档](https://hexo.io/zh-cn/docs/)
- [Hexo 主题](https://hexo.io/themes/)
- [Hexo 插件](https://hexo.io/plugins/)
