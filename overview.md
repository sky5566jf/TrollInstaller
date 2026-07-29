# 图标优化 + 版本号角标 — 完成概览

## 做了什么

### 1. 图标体积优化（-70%）

| 项目 | 之前 | 之后 | 变化 |
|------|------|------|------|
| AppIcon.png | **1.28 MB** (RGBA, 1024×1024) | **~379 KB** (RGB→256色调色板) | **-70%** |
| 整个 .tipa | ~1.38 MB | **~460 KB** | **-67%** |

**为什么能压这么多？**
- 图标 alpha 通道全不透明（extrema=255,255），RGBA 是纯浪费 → 丢掉
- 类照片内容（四小人吉祥物+水花）zlib 压不动，但 256 色调色板量化对图标级显示（主屏 ~180px）完全无损
- 仓库源图已替换为优化版，git 历史也减重了

### 2. 每次编译自动画版本号角标

新增 `make_icon.py`，CI 打包时自动执行：

```
python3 make_icon.py --in AppIcon.png --out stage/.../AppIcon.png --version 1.1
```

效果：图标右下角出现半透明深色圆角胶囊 + 白字 `v1.1`。每次编译版本号自动递增（bump_version.py +0.1），角标跟着变。

### 改动文件

| 文件 | 改动 |
|------|------|
| `AppIcon.png` | 替换为 256 色优化版（399KB） |
| `make_icon.py` | **新文件**：角标绘制 + 调色板压缩 |
| `.github/workflows/build.yml` | cp → pip install Pillow + make_icon.py --version |

## 编译结果

- Commit `ecc4b4b` → CI 成功
- 产物：`E:\lmp\ipa\M巨魔助手1.1.tipa`（460 KB）
- 验证通过：双二进制 arm64 ✅、AppIcon 379KB ✅、带 v1.1 角标 ✅
