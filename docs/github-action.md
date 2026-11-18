# 在 GitHub Actions 中使用

仓库根目录的 `action.yml` 是一个组合 Action：安装 MoonBit、把 routecheck 编译为 JavaScript、分析小程序、把结果写入任务摘要并以 SARIF 上传到 GitHub Code Scanning。诊断会出现在 Pull Request 的改动行上，以及仓库的 Security → Code scanning 页面中。

## 示例工作流

在小程序仓库中新建 `.github/workflows/routecheck.yml`：

```yaml
name: routecheck

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read
  security-events: write # 上传 SARIF 需要

jobs:
  routecheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: jiabin777on-hue/miniapp-routecheck@v0.3.0
        with:
          path: . # 含 app.json 的目录，或含 project.config.json 的项目目录
```

私有仓库使用 Code Scanning 需要开通 GitHub Advanced Security；未开通时设 `upload-sarif: "false"`，结果仍会出现在任务摘要中，并在有错误时让检查失败。来自 fork 的 Pull Request 没有 `security-events: write` 权限，同样应关闭上传。

## 输入

| 输入 | 默认值 | 说明 |
| --- | --- | --- |
| `path` | `.` | 小程序目录或项目目录，相对工作区。 |
| `strict` | `false` | 警告也导致失败。 |
| `max-package-kb` | `2048` | 单个包体积上限（KiB）。 |
| `max-total-kb` | `20480` | 总体积上限（KiB）。 |
| `sarif-file` | `routecheck.sarif` | SARIF 报告的写入位置。 |
| `upload-sarif` | `true` | 是否上传到 Code Scanning。 |
| `fail-on-findings` | `true` | 有错误（或 `strict` 下有警告）时让步骤失败。上传在失败之前完成。 |

## 输出

| 输出 | 说明 |
| --- | --- |
| `sarif-file` | SARIF 报告路径，可交给其他步骤，例如作为 artifact 保存。 |
| `exit-code` | `0` 无问题，`1` 有导致失败的诊断，`2` 无法分析（此时步骤总是失败）。 |

## 路径

CLI 默认输出相对小程序根目录的路径。Action 传入 `--sarif-base "$GITHUB_WORKSPACE"`，SARIF 中的路径因此相对仓库根目录，即使源码位于 `miniprogramRoot` 指定的子目录（如 `miniprogram/`），Code Scanning 也能定位到文件。本地生成 SARIF 时同样可用：

```sh
moon run cmd --target js -- --format sarif --sarif-base . miniprogram > routecheck.sarif
```

## 环境

Action 只使用 `bash`、`curl` 和 Node.js，已在 `ubuntu-latest` 上测试。运行器上的 Node.js 低于 22.3 时会自动安装 Node.js 22。本仓库的 CI 中 `action` 任务以 `uses: ./` 运行该 Action，分别检查正常示例通过、错误示例输出的 SARIF 路径相对仓库根目录。
