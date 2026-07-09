# idcsmart_hd

魔方财务上游信息检测工具。输入目标站点后，本地程序会尝试访问目标站 `/cart` 页面识别产品 ID，然后请求：

```text
https://你的域名/api/product/prodetail?pids[0]=产品ID
```

并检查接口响应中是否存在 `upstream_product_shopping_url`。

## 特点

- 不需要 PHP
- 不需要 Node.js
- 不需要 Python
- Windows 电脑双击 `启动.bat` 即可打开网页使用
- 支持输入域名后自动尝试识别 `/cart` 下的全部商品分类
- 会逐个分类页提取产品 ID，合并去重后一次任务扫完整个产品列表
- 检测过程中会显示分类发现进度、产品扫描进度和已扫描数量
- 自动识别失败时，也支持手动输入产品 ID

## 兼容性

当前版本定位为 Windows 通用版：

- Windows 10 / Windows 11：推荐使用
- Windows 7 / Windows Server：系统带 PowerShell 3.0+ 时可用
- 不需要安装 PHP、Node.js、Python
- macOS / Linux 不能直接运行 `.bat`，需要单独做对应系统的启动脚本

如果电脑策略禁用了 PowerShell，右键 `启动.bat` 以管理员身份运行；仍不行则说明该电脑被安全策略限制。

## 使用方法

1. 下载或克隆本项目。
2. 双击 `启动.bat`。
3. 浏览器会自动打开本地页面。
4. 输入你要检测的目标站点域名或地址。

5. 点击“开始检测”。

如果没有自动识别到产品 ID，可以手动填写：

```text
1,2,3
```

## 文件说明

```text
idcsmart_hd/
├─ 启动.bat          Windows 中文启动脚本
├─ start.bat         Windows 英文启动脚本
├─ server.ps1        本地 PowerShell 服务，请求目标接口
└─ web/
   └─ index.html     查询网页界面
```

## 为什么不是直接打开 HTML

浏览器直接打开 HTML 时，请求其他域名接口通常会被 CORS 跨域策略拦截。

所以本项目使用 Windows 自带的 PowerShell 在本机启动一个只监听 `127.0.0.1` 的本地服务：

```text
浏览器页面 -> 本机 PowerShell 服务 -> 目标站点接口
```

这样不需要部署服务器，也不需要安装 PHP。

## 注意事项

本工具只适合用于你自己的网站、授权测试环境或安全研究复现。请勿用于未授权目标。