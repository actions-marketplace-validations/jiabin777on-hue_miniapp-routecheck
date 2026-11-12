# 微信小程序路由体检

Miniapp Routecheck 是一个用 MoonBit 编写的命令行工具。它在本地检查微信小程序 `app.json` 中的主包、分包和底部导航配置，并输出 JSON 诊断。改动目录或拆分分包后，可以在提交代码前用它定位失效的路由声明。

## 运行

需要 [MoonBit 工具链](https://www.moonbitlang.com/download/)（本项目用 2026 年 11 月 4 日发布的 `moon` 验证）和 Node.js 22.3 或更新版本。从本项目目录运行，传入包含 `app.json` 的小程序目录。如果项目使用 `miniprogramRoot`，传入它指向的目录。

```sh
moon run cmd --target js -- "<小程序目录>"
```

检查面向原生小程序目录中的 `.js` 和 `.wxml` 文件。使用 TypeScript 或框架生成小程序文件的项目，请传入构建后的目录。运行检查只需读取项目文件，无需 AppID、上传密钥或微信开发者工具。

## 检查范围

- 主包 `pages` 与 `subpackages` 或 `subPackages` 的路径。检查越界路径、重复或仅大小写不同的路由，以及相互嵌套的分包根目录。
- 每条已注册路由所对应的 `.js` 和 `.wxml` 文件是否存在，路径大小写是否一致。
- `entryPagePath` 是否指向已注册的页面，以及 `tabBar.list[].pagePath` 是否引用主包页面。
- `preloadRule` 的触发页面、分包名称或根目录引用，以及 `wifi` 和 `all` 网络选项。

输出为 JSON 数组，每个问题包含 `code`、`location` 和 `detail`，供本地查看或在 CI 中读取。退出码 `0` 表示检查通过，`1` 表示发现配置或路由问题，`2` 表示命令参数或文件系统错误。预下载的体积上限由微信开发者工具在打包时校验。

## 验证

```sh
moon test --target js
moon run cmd --target js -- examples/good
moon run cmd --target js -- examples/broken
```

`examples/good` 预期通过。`examples/broken` 预期报告越界路径、缺失的页面脚本和指向分包的底部导航配置。

路由规则参照[微信小程序全局配置](https://developers.weixin.qq.com/miniprogram/dev/reference/configuration/app.html)和[使用分包](https://developers.weixin.qq.com/miniprogram/dev/framework/subpackages/basic.html)。项目使用 Codex 辅助设计、实现与测试，公开提交前由参赛者审核。
