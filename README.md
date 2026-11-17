# 微信小程序路由体检（miniapp-routecheck）

用 MoonBit 编写的微信小程序**依赖图与分包边界分析器**。它读取构建后的小程序目录，用自带的 WXML、JS、WXSS 解析器提取每个文件的引用，建立"页面 → 组件 → 脚本 / 模板 / 样式 / 图片"的完整依赖图。在此基础上，它检查分包边界、页面跳转、模板作用域、模块循环和包体积，并给出把主包文件挪进分包的瘦身建议。

这些问题平时要到真机运行、上传代码或用户点击时才暴露。例如主包 `require` 了分包里的工具函数、`navigateTo` 打开了 tabBar 页面、独立分包悄悄依赖了主包的请求封装。本工具在提交前、在 CI 里一次性指出问题，每条诊断都带 `文件:行:列`。

```text
$ moon run cmd --target js -- --format text examples/shop-broken
error   pages/me/index.wxml:1:1  [wxml-syntax-error] <view> is never closed.
warning packageGoods/detail/index.wxss:2:27  [local-wxss-resource] WXSS cannot load local file /images/logo.png on devices; ...
error   pages/index/index.wxml:3:3  [unknown-template] Template 'bannr' is not defined in this file or in a file it imports.
warning pages/index/index.json $.usingComponents["coupon"]  [unused-component] <coupon> is declared but never used ...
error   packageOrder/confirm/index.json $.usingComponents["thumb"]  [cross-subpackage-reference] subpackage order cannot use packageGoods/components/thumb/index ...
error   pages/cart/index.js:1:26  [main-package-references-subpackage] The main package cannot use packageGoods/utils/sku.js ...
error   packageActivity/landing/index.js:1:29  [independent-subpackage-dependency] Independent subpackage activity must not depend on utils/request.js ...
error   pages/me/index.js:3:26  [navigate-to-tab-page] wx.navigateTo cannot open tabBar page pages/cart/index; use wx.switchTab.
error   pages/me/index.js:6:25  [switch-tab-to-non-tab-page] wx.switchTab can only open tabBar pages; ...
error   components/goods-card/index.js:5:28  [unknown-navigation-target] wx.navigateTo opens 'packageGoods/detial/index', which is not registered in app.json.
warning utils/cache.js:1:23  [require-cycle] Modules require each other: utils/cache.js -> utils/store.js. ...
info    utils/legacy-share.js  [unreferenced-file] Nothing references this file (36 bytes); ...
info    utils/chart.js  [move-to-subpackage] Only subpackage goods uses this file; moving it under packageGoods/ would take 94 bytes out of the main package.

Packages:
  main      3.8 KiB     of 2048.0 KiB  35 files
  goods     0.8 KiB     of 2048.0 KiB  10 files  (0.1 KiB movable from main)
  order     0.4 KiB     of 2048.0 KiB  3 files
  activity  0.1 KiB     of 2048.0 KiB  2 files  (independent)

8 errors, 3 warnings, 2 notes.
```

## 架构

```text
cmd/        CLI：参数、Node.js 文件枚举与按需读取、输出与退出码
  │
  ▼
routecheck  分析核心（纯 MoonBit，无 I/O，全部可用内存样例测试）
  audit.mbt / preload.mbt / tab_assets.mbt   app.json 结构校验
  graph.mbt     工作队列遍历 app → 页面 → 组件 → 源文件，生成带位置的类型化依赖边
  resolve.mbt   模块解析：相对 / 根路径 / miniprogram_npm 逐级查找、扩展名与 index 补全
  rules.mbt     模板作用域、未用组件、分包边界、跳转语义、Tarjan 循环检测、可达性、体积与迁移建议
  report.mbt    JSON / 文本 / SARIF 2.1.0 / Graphviz DOT
  │
  ├── wxml/     WXML 解析器：元素树、严格闭合检查与错误恢复、{{ }} 感知、<wxs> 原文跳过
  ├── jsscan/   JS 词法分析器（正则 / 除号判定、模板字符串嵌套、转义解码）+ 依赖与跳转提取
  ├── wxss/     WXSS 扫描器：@import 与 url()，跳过注释和字符串
  └── scan/     共享游标：字符位置、行列号、BOM 处理
```

三个解析器都是为这个工具从零写的，没有依赖第三方解析库。它们都会在出错后继续扫描，一个未闭合的字符串不会让后面的依赖丢失。核心分析不做任何 I/O：文件内容通过 `Project` 中的读取闭包按需提供，因此每条规则都能用内存中的小程序样例做单元测试。

## 运行

需要 [MoonBit 工具链](https://www.moonbitlang.com/download/)和 Node.js 22.3 或更新版本。传入包含 `app.json` 的小程序目录，或包含 `project.config.json` 的项目目录（按 `miniprogramRoot` 查找源码）。

```sh
moon run cmd --target js -- examples/shop                      # JSON 报告
moon run cmd --target js -- --format text examples/shop-broken # 终端阅读
moon run cmd --target js -- --format sarif <目录> > routecheck.sarif
moon run cmd --target js -- --format dot <目录> | dot -Tsvg > deps.svg
moon run cmd --target js -- --strict --max-package-kb 1800 <目录>
```

| 选项 | 说明 |
| --- | --- |
| `--format json\|text\|sarif\|dot` | 默认 `json`。`sarif` 可直接上传到 GitHub Code Scanning；`dot` 按包分簇输出依赖图，违规边标红，异步边为虚线。 |
| `--strict` | warning 也视为失败。 |
| `--max-package-kb <n>` | 单包上限，默认 2048。 |
| `--max-total-kb <n>` | 总体积上限，默认 20480。 |

退出码：`0` 无 error；`1` 有 error（`--strict` 下含 warning）；`2` 参数或文件系统错误。

JSON 报告结构：

```json
{
  "summary": { "errors": 8, "warnings": 3, "infos": 2, "files": 51, "edges": 28 },
  "packages": [{ "name": "goods", "root": "packageGoods", "independent": false, "files": 10, "bytes": 841, "movableBytes": 94 }],
  "findings": [{ "code": "main-package-references-subpackage", "severity": "error", "file": "pages/cart/index.js", "line": 1, "column": 26, "detail": "..." }]
}
```

## 检查范围

完整规则、级别和依据见 [docs/rules.md](docs/rules.md)。概要：

- **分包边界**：主包引用分包、分包之间互相引用、独立分包依赖主包。覆盖 require / import、组件、WXML import·include、WXS、WXSS @import 和图片，识别 `require.async` 与 `componentPlaceholder` 两种合法的分包异步化写法。
- **页面跳转**：`wx.navigateTo / redirectTo / reLaunch / switchTab` 与 `<navigator>` 的目标是否已注册，tabBar 页面与普通页面是否用对了 API，相对路径按当前页面解析。
- **引用解析**：模块、组件（含 npm 构建产物）、模板、WXS、样式和图片是否存在。
- **组件与模板**：`"component": true`、组件文件完整性、声明却未使用的组件、`<template is>` 的作用域（import 不传递、include 继承包含方）。
- **语法**：WXML 标签闭合与错配、JS/WXS/WXSS 词法错误、WXSS 中真机不支持的本地背景图。
- **模块循环**：Tarjan 强连通分量（迭代实现，深链不会栈溢出）。
- **体积**：各包体积与限额，不被引用的文件，只被单个分包使用、可以移出主包的文件。
- **app.json**：页面与分包路径、重复与大小写冲突、`entryPagePath`、tabBar、图标与 `preloadRule`。

## 验证

```sh
moon test --target js           # 48 个单元测试：三个解析器、解析器边界情况、每类规则、Tarjan
node --test test/cli.test.cjs   # 11 个端到端测试：样例、SARIF、DOT、--strict、体积限额、编码、参数
```

`examples/shop` 是一个包含 3 个 tab 页、普通分包、独立分包、全局组件、WXS、模板和 npm 风格引用的商城小程序，预期零诊断。`examples/shop-broken` 在它的基础上为每类规则注入一个缺陷，端到端测试逐条核对诊断代码与行列号。`examples/good` 与 `examples/broken` 是早期的 app.json 配置样例。

## 已知局限

JS 分析基于词法而非数据流，变量传入的 `url` 不检查。工具只分析编译后的小程序目录，体积为源文件字节的近似值。详见 [docs/rules.md](docs/rules.md#已知局限)。

规则依据[微信小程序全局配置](https://developers.weixin.qq.com/miniprogram/dev/reference/configuration/app.html)、[使用分包](https://developers.weixin.qq.com/miniprogram/dev/framework/subpackages/basic.html)、[独立分包](https://developers.weixin.qq.com/miniprogram/dev/framework/subpackages/independent.html)与[分包异步化](https://developers.weixin.qq.com/miniprogram/dev/framework/subpackages/async.html)。项目使用 AI 辅助设计、实现与测试，所有规则和测试由参赛者审核。
