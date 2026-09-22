<h1 align="center">Luau Decompiler</h1>

<p align="center">Luau Bytecode → 结构化 Luau 源码</p>

<p align="center">
  <a href="decompiler.lua"><img src="https://img.shields.io/badge/Version-0.1.3-94a3b8?style=flat-square&amp;labelColor=161b22" alt="Version 0.1.3"></a>
  <a href="https://www.lua.org/manual/5.1/"><img src="https://img.shields.io/badge/Lua-5.1-818cf8?style=flat-square&amp;logo=lua&amp;logoColor=white&amp;labelColor=161b22" alt="Written in Lua 5.1"></a>
  <a href="https://luau.org/"><img src="https://img.shields.io/badge/Output-Luau-38bdf8?style=flat-square&amp;labelColor=161b22" alt="Output Luau"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-34d399?style=flat-square&amp;labelColor=161b22" alt="License MIT"></a>
</p>

<p align="center">
  <a href="#quick-start">快速开始</a> ·
  <a href="#output">输出示例</a> ·
  <a href="#api">模块 API</a> ·
  <a href="#scope">支持范围</a>
</p>

---

**Lua 5.1 / Luau · 各自单文件 · 无第三方依赖。** 还原控制流、闭包、上值与多返回值，不执行输入字节码。

<a id="quick-start"></a>

## 快速开始

### Lua 5.1

下载 [`decompiler.lua`](decompiler.lua)，运行：

```sh
lua5.1 decompiler.lua input.luac -o output.luau
```

输入为**原始二进制 Luau Bytecode**，不是 Lua 5.1 的 `luac` 文件。已有输出默认不覆盖；确认覆盖时加 `--force`。

<details>
<summary>命令行参数</summary>

| 参数 | 用途 |
| :--- | :--- |
| `-o <path>` | 保存源码；省略或使用 `-` 时输出到 stdout |
| `--opcodes auto\|plain\|roblox` | 指令编码，默认自动识别 |
| `--no-header` | 不生成文件头 |
| `--strict-trailing` | 拒绝尾部附加数据 |
| `--force` | 允许覆盖已有输出 |

</details>

### Luau

使用提供 `readfile`、`setclipboard` 等接口的宿主，加载独立入口 [`decompiler.luau`](decompiler.luau)：

```lua
input = [==[在这里输入需要反编译的脚本路径]==]
-- 输出默认保存在剪贴板，也可改为工作区文件
saveMode = "cl" -- cl 或 file

-- 加载主模块
loadstring(game:HttpGet("https://raw.githubusercontent.com/Luaunveil/luau-decompiler/refs/heads/main/decompiler.luau"))()
```

`input` 是**工作区内原始 Luau 字节码文件的相对路径**，例如 `scripts/input.luac`；不是源代码，也不是 `game.…` 实例路径。路径不会作为代码执行。

`cl` 使用 `setclipboard`；`file` 默认写入工作区根目录的 `input.decompiled.luau`（名称取自输入文件），需要 `readfile`、`writefile`、`isfile`。可设置 `outputPath = "result.luau"`；已有文件默认拒绝覆盖，明确设置 `overwriteOutput = true` 才允许覆盖。无需下载另一份核心，也不调用宿主自带的 `decompile`。

<a id="output"></a>

## 输出示例

```lua
local local_1 = game:GetService("Players").LocalPlayer
if local_1.PlayerGui:FindFirstChild("DoNotPush") then
    local_1.PlayerGui.DoNotPush:Destroy()
end
```

**不猜变量名。** 全局、字段、方法和可靠调试名称保留原样；无法恢复或存在绑定冲突的局部变量统一为 `local_X`。

<a id="api"></a>

## 模块 API

`bytes` 为宿主提供的原始字节串；返回源码和字节码元信息，失败时抛出错误。

```lua
local decompiler = require("decompiler") -- Lua 5.1
-- Luau: require("./decompiler")，目录中只放 decompiler.luau
local source, info = decompiler.decompile(bytes, { header = false })
print(source)
```

没有文件 API 的 Luau 宿主，由调用方提供字节串并保存返回值。两个入口使用相同核心；不要将同名 `.lua` / `.luau` 放在同一模块搜索目录。通过 `loadstring` 仅加载 API 时，使用 `loadstring(moduleSource)("module")`，不会触发全局 `input` 的自动运行。

<details>
<summary><strong>高级配置</strong></summary>

```lua
local source, info = decompiler.decompile(bytes, {
    header = false,
    expression_if = false,   -- 不生成 Luau if 表达式
    strict_trailing = true,
    max_bytes = 8 * 1024 * 1024,
    max_output_bytes = 8 * 1024 * 1024,
    max_work = 20000000,
})
```

默认输入、输出上限均为 **16 MiB**，工作预算为 **50,000,000**。超限会拒绝处理；预算不是实际时间或内存配额。

`opcode_multiplier` 可指定奇数解码乘数；`upvalue_names` 提供根函数的实际外部上值名；`vector_constructor` / `integer_constructor` 指定宿主构造器，仅接受合格标识符路径。完整配置与硬上限见 [`decompiler.lua`](decompiler.lua)。

低层接口：`parse(bytes, options)` 解析容器，`decode(chunk, options)` 解码 `parse` 返回的结果；不要传入不可信的任意 Lua 表。

</details>

<a id="scope"></a>

## 支持范围

**v0.1.3 · 实验性。** 识别版本 **3–14** 的已知容器布局，支持常见分支、循环与函数结构；不代表覆盖全部指令或保证行为等价。

暂不支持外层加密／压缩、任意 opcode 映射、类指令、`NATIVECALL`、`CMPPROTO` 及无法结构化的控制流。已被移除的注释、类型和原始排版不可恢复。

仅向可信目录写入输出；两种文件接口都不能消除路径竞争。Luau 的 `readfile` 会整文件读取，`writefile` 不保证原子写入；显式覆盖失败时仅能尝试恢复旧内容。服务端接入仍需进程级资源限制。默认接受带警告的 24 字节不透明尾部，不验证签名；严格处理时使用 `--strict-trailing`。

---

[MIT License](LICENSE) · Copyright © 2026 LuaUnVeil
