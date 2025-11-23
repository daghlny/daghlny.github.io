# Hexo 博客使用指南

这是一份详细的 Hexo 博客使用指南，帮助你快速上手博客的日常管理。

## 目录
- [创建新文章](#创建新文章)
- [删除文章](#删除文章)
- [编辑文章](#编辑文章)
- [本地预览](#本地预览)
- [发布到 GitHub Pages](#发布到-github-pages)
- [常用命令](#常用命令)
- [文章格式说明](#文章格式说明)

---

## 创建新文章

### 方法一：使用 Hexo 命令（推荐）

```bash
cd blog
hexo new "文章标题"
```

**示例**：
```bash
hexo new "我的第一篇技术博客"
```

这会在 `blog/source/_posts/` 目录下创建一个新的 Markdown 文件：
- 文件名：`我的第一篇技术博客.md`
- 自动包含 Front Matter（文章元数据）

### 方法二：手动创建

直接在 `blog/source/_posts/` 目录下创建 `.md` 文件：

```bash
cd blog/source/_posts
touch my-new-post.md
```

然后手动添加 Front Matter：

```markdown
---
title: 我的新文章
date: 2025-11-23 22:00:00
tags:
  - 技术
  - 学习
categories:
  - 编程
---

这里是文章内容...
```

### 创建草稿

如果你想先写草稿，不立即发布：

```bash
hexo new draft "草稿标题"
```

草稿会保存在 `blog/source/_drafts/` 目录，不会被生成到网站中。

发布草稿：
```bash
hexo publish "草稿标题"
```

---

## 删除文章

### 步骤 1：删除源文件

找到并删除 `blog/source/_posts/` 目录下的对应 `.md` 文件：

```bash
cd blog/source/_posts
rm 文章文件名.md
```

**示例**：
```bash
# 删除 "Hello World" 文章
rm hello-world.md
```

### 步骤 2：重新生成网站

```bash
cd blog
hexo clean    # 清理缓存
hexo generate # 重新生成
```

### 步骤 3：复制到根目录并提交

```bash
cp -r public/* ..
cd ..
git add .
git commit -m "Delete: 删除某篇文章"
git push origin main
```

---

## 编辑文章

### 1. 找到文章文件

文章位于 `blog/source/_posts/` 目录：

```bash
cd blog/source/_posts
ls  # 查看所有文章
```

### 2. 编辑文章

使用任何文本编辑器打开 `.md` 文件：

```bash
# 使用 VSCode
code First-blog-from-yinuo.md

# 或使用 vim
vim First-blog-from-yinuo.md
```

### 3. 保存并重新生成

编辑完成后：

```bash
cd blog
hexo clean
hexo generate
cp -r public/* ..
```

---

## 本地预览

在发布前，你可以在本地预览博客效果：

```bash
cd blog
hexo server
```

然后在浏览器访问：`http://localhost:4000`

**常用选项**：
```bash
hexo server -p 5000        # 使用 5000 端口
hexo server --draft        # 同时预览草稿
hexo server --debug        # 调试模式
```

停止服务器：按 `Ctrl + C`

---

## 发布到 GitHub Pages

### 完整流程

```bash
# 1. 进入 blog 目录
cd blog

# 2. 清理旧文件
hexo clean

# 3. 生成静态文件
hexo generate

# 4. 复制到根目录
cp -r public/* ..

# 5. 返回根目录
cd ..

# 6. 提交到 Git
git add .
git commit -m "Update: 更新博客内容"
git push origin main
```

### 一键脚本

你可以创建一个脚本来简化这个过程：

创建 `deploy.sh`：
```bash
#!/bin/bash
cd blog
hexo clean
hexo generate
cp -r public/* ..
cd ..
git add .
git commit -m "Update blog: $(date '+%Y-%m-%d %H:%M:%S')"
git push origin main
echo "博客已发布！"
```

使用：
```bash
chmod +x deploy.sh  # 第一次需要添加执行权限
./deploy.sh         # 运行脚本
```

---

## 常用命令

### Hexo 命令

```bash
hexo init [folder]      # 初始化一个新的 Hexo 项目
hexo new [layout] <title>  # 创建新文章
hexo generate           # 生成静态文件（简写：hexo g）
hexo server             # 启动本地服务器（简写：hexo s）
hexo deploy             # 部署网站（简写：hexo d）
hexo clean              # 清理缓存文件
hexo publish <filename> # 发布草稿
hexo list <type>        # 列出网站资料
hexo version            # 显示版本信息
```

### 组合命令

```bash
hexo clean && hexo generate  # 清理并生成
hexo g -d                    # 生成并部署
hexo s -g                    # 生成并启动服务器
```

---

## 文章格式说明

### Front Matter（文章头部）

每篇文章开头的 YAML 格式元数据：

```markdown
---
title: 文章标题          # 必需
date: 2025-11-23 22:00:00  # 发布日期
updated: 2025-11-24 10:00:00  # 更新日期（可选）
tags:                    # 标签（可选）
  - JavaScript
  - 前端
  - 教程
categories:              # 分类（可选）
  - 编程
  - Web开发
description: 文章摘要    # 摘要（可选）
comments: true           # 是否开启评论（可选）
---

这里开始是文章正文...
```

### Markdown 语法

```markdown
# 一级标题
## 二级标题
### 三级标题

**粗体文字**
*斜体文字*
~~删除线~~

- 无序列表项 1
- 无序列表项 2

1. 有序列表项 1
2. 有序列表项 2

[链接文字](https://example.com)

![图片描述](图片URL)

`行内代码`

​```javascript
// 代码块
function hello() {
  console.log("Hello World!");
}
​```

> 引用文字

---  # 分隔线
```

### 插入图片

**方法一：使用外部链接**
```markdown
![图片描述](https://example.com/image.jpg)
```

**方法二：使用本地图片**

1. 在 `blog/_config.yml` 中设置：
```yaml
post_asset_folder: true
```

2. 创建文章时会自动创建同名文件夹：
```bash
hexo new "我的文章"
# 会创建：
# - source/_posts/我的文章.md
# - source/_posts/我的文章/ （放图片的文件夹）
```

3. 在文章中引用：
```markdown
![图片描述](我的文章/image.jpg)
```

### 文章摘要

使用 `<!-- more -->` 标记摘要结束位置：

```markdown
---
title: 我的文章
---

这是文章摘要，会显示在首页。

<!-- more -->

这是文章的详细内容，只有点击"阅读更多"后才能看到。
```

---

## 高级技巧

### 1. 设置文章永久链接

在 `blog/_config.yml` 中配置：

```yaml
permalink: :year/:month/:day/:title/
# 或
permalink: posts/:title/
# 或
permalink: :category/:title/
```

### 2. 添加标签页和分类页

```bash
hexo new page tags
hexo new page categories
```

编辑生成的页面，添加 type：

`source/tags/index.md`:
```markdown
---
title: 标签
type: tags
---
```

`source/categories/index.md`:
```markdown
---
title: 分类
type: categories
---
```

### 3. 批量操作

**查找所有文章**：
```bash
find blog/source/_posts -name "*.md"
```

**批量修改标签**：
使用脚本或文本编辑器的批量替换功能。

---

## 常见问题

### Q: 文章不显示？
A: 检查：
1. 文件是否在 `source/_posts/` 目录
2. Front Matter 格式是否正确
3. 是否运行了 `hexo clean && hexo generate`

### Q: 修改后没有效果？
A: 运行 `hexo clean` 清理缓存后重新生成。

### Q: 如何修改主题？
A: 
1. 下载主题到 `blog/themes/` 目录
2. 修改 `blog/_config.yml` 中的 `theme` 配置
3. 重新生成

### Q: 如何备份博客？
A: 整个 `blog/` 目录就是你的博客源文件，定期备份即可。

---

## 快速参考

### 创建文章
```bash
cd blog && hexo new "文章标题"
```

### 删除文章
```bash
rm blog/source/_posts/文章文件.md
cd blog && hexo clean && hexo generate
```

### 本地预览
```bash
cd blog && hexo server
```

### 发布
```bash
cd blog && hexo clean && hexo generate && cp -r public/* .. && cd .. && git add . && git commit -m "Update" && git push
```

---

## 更多资源

- [Hexo 官方文档](https://hexo.io/zh-cn/docs/)
- [Hexo 主题列表](https://hexo.io/themes/)
- [Hexo 插件列表](https://hexo.io/plugins/)
- [Markdown 语法指南](https://www.markdownguide.org/)

---

**提示**：建议将这份指南保存在项目根目录，方便随时查阅！
