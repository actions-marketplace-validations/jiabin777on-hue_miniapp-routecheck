# 规则参考

每条诊断都有固定的 `code`、级别和位置。源码文件中的问题给出 `文件:行:列`，配置文件中的问题给出 JSON 路径（如 `$.usingComponents["thumb"]`）。

级别含义：

- **error**：编译、打包会失败，或运行时跳转/加载必然失败。默认退出码 `1`。
- **warning**：真机上大概率出错，或是明确的隐患，项目仍能编译。加 `--strict` 时也会导致退出码 `1`。
- **info**：优化建议，不影响退出码。

## 分包边界（依赖图规则）

依据：[使用分包](https://developers.weixin.qq.com/miniprogram/dev/framework/subpackages/basic.html)、[独立分包](https://developers.weixin.qq.com/miniprogram/dev/framework/subpackages/independent.html)、[分包异步化](https://developers.weixin.qq.com/miniprogram/dev/framework/subpackages/async.html)。

| code | 级别 | 触发条件 |
| --- | --- | --- |
| `main-package-references-subpackage` | error | 主包内的文件通过 require / import / 组件 / WXML import·include / WXS / WXSS @import / 图片引用了分包内的文件。主包启动时分包尚未下载。 |
| `cross-subpackage-reference` | error | 分包 A 的文件引用了分包 B 的文件。分包之间只能通过主包共享代码。 |
| `independent-subpackage-dependency` | error | 独立分包引用了主包或其他分包的任何文件。独立分包运行时主包可能未加载。 |

`require.async(...)` 以及在 `componentPlaceholder` 中声明了占位组件的跨包组件属于分包异步化，不报告。判断依据是每条依赖边两端文件所属的包：包归属由 `app.json` 中最长匹配的分包 `root` 决定。

## 页面跳转

依据：[wx.navigateTo](https://developers.weixin.qq.com/miniprogram/dev/api/route/wx.navigateTo.html)、[wx.switchTab](https://developers.weixin.qq.com/miniprogram/dev/api/route/wx.switchTab.html)、[navigator](https://developers.weixin.qq.com/miniprogram/dev/component/navigator.html)。

检查对象：JS 中 `wx.navigateTo / redirectTo / reLaunch / switchTab({ url })`，以及 WXML 中 `<navigator url open-type>`。`url` 为字符串字面量，或 `?` 之前不含 `${}` 的模板字符串时才检查；查询参数会被去掉。相对路径按所在页面的路由解析；非页面文件（如 `utils/`）中的相对路径因为无法确定当前页面而跳过。

| code | 级别 | 触发条件 |
| --- | --- | --- |
| `unknown-navigation-target` | error | 目标路由未在 `pages` 或任何分包的 `pages` 中注册。 |
| `invalid-navigation-target` | error | 目标路径越出小程序根目录或为空。 |
| `navigate-to-tab-page` | error | `navigateTo`/`redirectTo`（或 `open-type` 为 `navigate`/`redirect`）打开了 tabBar 页面。 |
| `switch-tab-to-non-tab-page` | error | `switchTab` 打开了不在 `tabBar.list` 中的页面。 |

## 模块与引用解析

解析规则：`/a/b` 相对小程序根目录；`./`、`../` 相对当前文件目录；裸路径先在当前目录及各级父目录的 `miniprogram_npm` 中查找，再按相对当前目录处理。JS 会补全 `.js` 和 `/index.js`；组件以 `.json` 定位，可补全 `/index.json`。网络地址、`plugin://`、`cloud://`、`data:` 和包含 `{{ }}` 的值视为外部引用，不检查。

| code | 级别 | 触发条件 |
| --- | --- | --- |
| `unresolved-module` | error | `require` / `import` / `export ... from` 的目标不存在。 |
| `unresolved-component` | error | `usingComponents` 或 `componentGenerics.*.default` 的组件不存在。 |
| `unresolved-wxml-reference` | error | `<import src>`、`<include src>`、`<wxs src>` 的目标不存在。 |
| `unresolved-style-import` | error | WXSS `@import` 的目标不存在。 |
| `missing-asset` | error | `<image>`、`<cover-image>`、`<video>`、`<audio>` 的本地 `src` 不存在。 |
| `missing-config-file` | error | `sitemapLocation`、`themeLocation` 指向的文件不存在。 |
| `missing-custom-tab-bar` | error | `tabBar.custom` 为 `true`，但没有 `custom-tab-bar/index` 组件。 |

## 组件

依据：[自定义组件](https://developers.weixin.qq.com/miniprogram/dev/framework/custom-component/)。

| code | 级别 | 触发条件 |
| --- | --- | --- |
| `missing-component-flag` | error | 被当作组件引用的 JSON 中缺少 `"component": true`。 |
| `incomplete-component` | error | 组件缺少 `.js` 或 `.wxml`。 |
| `invalid-component-path` | error | `usingComponents` 不是对象，或值不是字符串。 |
| `unused-component` | warning | 页面或组件声明了组件，但其 WXML 及其 import / include 的 WXML 中都没有使用该标签，也没有作为 `generic:*` 的值使用。未使用的组件仍会被打包和初始化。`app.json` 中的全局组件不检查。 |

## WXML / WXS / WXSS

依据：[WXML 引用](https://developers.weixin.qq.com/miniprogram/dev/reference/wxml/import.html)、[WXS 模块](https://developers.weixin.qq.com/miniprogram/dev/reference/wxs/01wxs-module.html)、[WXSS](https://developers.weixin.qq.com/miniprogram/dev/framework/view/wxss.html)。

| code | 级别 | 触发条件 |
| --- | --- | --- |
| `wxml-syntax-error` | error | 未闭合或错配的标签、未闭合的注释、属性值或 `{{ }}`、重复属性、文本中多余的 `<`。WXML 要求标签严格闭合。 |
| `unknown-template` | error | `<template is="x">` 中的 `x` 既不在本文件定义，也不在本文件直接 import 的文件中定义。import 不具传递性；被 include 的文件可以使用 include 方可见的模板。`is` 为数据绑定时跳过。 |
| `wxs-missing-module` | error | `<wxs>` 缺少 `module` 属性。 |
| `wxs-requires-non-wxs` | error | WXS 中 `require` 了非 `.wxs` 文件。 |
| `local-wxss-resource` | warning | WXSS 中的 `url()` 指向本地文件。WXSS 背景图只支持网络图片、base64 或改用 `<image>`，本地路径在真机上无法加载。 |
| `script-syntax-error` | warning | JS / WXS 词法错误：未闭合的字符串、模板字符串、正则或注释，非法转义。 |
| `wxss-syntax-error` | warning | WXSS 中未闭合的注释、字符串或 `url()`。 |

## 模块循环

| code | 级别 | 触发条件 |
| --- | --- | --- |
| `require-cycle` | warning | 同步 `require` / `import` 构成环（含自引用）。CommonJS 循环中先加载的一方会拿到未初始化完的 `module.exports`。每个强连通分量只报告一次。 |

## 体积与清理建议

依据：分包文档中"单个分包/主包大小不能超过 2M，整个小程序所有分包大小不超过 20M"。体积按源文件字节数估算，不含开发者工具的压缩和 `packOptions.ignore`，`project.config.json`、`package.json`、`.md`、`.ts` 和以 `.` 开头的路径不计入。

| code | 级别 | 触发条件 |
| --- | --- | --- |
| `package-size-exceeded` | error | 主包或某个分包超过 `--max-package-kb`（默认 2048）。 |
| `total-size-exceeded` | error | 所有包合计超过 `--max-total-kb`（默认 20480）。 |
| `move-to-subpackage` | info | 主包中的文件不被主包的任何入口同步引用，只被一个分包使用。移入该分包可直接减小主包体积。 |
| `unreferenced-file` | info | 可打包的文件（代码、配置、图片）不被任何入口引用。`miniprogram_npm/` 和 `workers/` 下的文件不检查。动态拼接路径引用的图片也会出现在这里，需人工确认。 |

## app.json 配置

| code | 级别 | 触发条件 |
| --- | --- | --- |
| `invalid-json` / `invalid-manifest` | error | `app.json` 不是合法 JSON 对象，或存在重复键。 |
| `invalid-pages` / `invalid-route` | error | 页面列表为空，或路径不可移植（越界、绝对路径、带扩展名、Windows 保留名等）。 |
| `duplicate-route` / `route-case-collision` | error | 页面重复注册，或仅大小写不同。 |
| `main-route-inside-subpackage` | error | 主包页面位于分包根目录下。 |
| `overlapping-subpackage-root` | error | 分包根目录相互嵌套。 |
| `missing-page-file` / `page-file-case-mismatch` | error | 页面缺少 `.js` / `.wxml`，或文件名大小写不一致。 |
| `unknown-entry-route` | error | `entryPagePath` 未注册。 |
| `tab-route-not-in-main-package` / `invalid-tab-count` | error | tabBar 页面不在主包，或数量不在 2–5 之间。 |
| `missing-tab-icon-file` | error | tabBar 图标文件不存在。 |
| `unknown-preload-route` / `unknown-preload-package` | error | `preloadRule` 引用了未注册的页面或不存在的分包。 |
| `unreadable-file` | error | 文件不是 UTF-8 文本。 |

## 已知局限

- JS 分析基于词法，不做数据流：`const url = '/pages/a'; wx.navigateTo({ url })` 不检查。
- 只分析构建后的小程序目录。TypeScript、Taro、uni-app 等项目请传入编译输出目录。
- 体积是源文件字节的近似值，用于在开发阶段提前发现问题，最终以开发者工具的上传结果为准。
