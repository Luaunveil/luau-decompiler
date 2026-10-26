<h1 align="center">Luau Decompiler</h1>

<p align="center">Luau Bytecode → 结构化 Luau 源码</p>

<p align="center">
  <a href="decompiler.lua"><img src="https://img.shields.io/badge/Version-0.1.14-94a3b8?style=flat-square&amp;labelColor=161b22" alt="Version 0.1.14"></a>
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

**Lua 5.1 / Luau · 各自单文件 · 无第三方依赖。** 还原控制流、闭包、上值与多返回值，不执行输入字节码；支持 Luau 类形状常量，并在非类运行时中降级为可执行表结构。

0.1.14 改进表初始化的还原：将安全的连续数字键赋值合并为数组字面量，支持闭包值捕获、嵌套表与函数参数，并保留字符串、数字和布尔键的区别。重叠索引和多返回值后续写入会保留必要的独立语句，避免改变覆盖顺序或丢失返回值。

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

```lua
input = [==[ 在这里填写输入脚本路径 ]==]
-- 默认复制到剪贴板；file 保存到执行器工作区
saveMode = "cl" -- cl 或 file

-- 加载主模块
loadstring(game:HttpGet("https://raw.githubusercontent.com/Luaunveil/luau-decompiler/refs/heads/main/decompiler.luau"))()
```

`input` 是游戏中的**脚本实例路径**：支持 `Workspace.LocalScript`、`game.Workspace.LocalScript`、`game:GetService("Players").LocalPlayer.PlayerScripts["294Client"]`、`Workspace["带空格的脚本名"]`，也可直接传入脚本 Instance。`GetService` 仅接受字符串字面量；`LocalPlayer` 等实例属性正常解析，不执行路径文本或目标脚本。

文件直接保存到执行器工作区根目录，命名为 **`{ScriptName}{yyyymmddss}{Number}.lua`**。日期使用宿主本地时间，`ss` 是两位秒数；`Number` 从 1 递增并跳过已有文件，不覆盖旧输出。脚本名中无法用于文件名的字符替换为 `_`。

<a id="output"></a>

## 输出示例

```lua
local local_1 = game:GetService("Players").LocalPlayer
if local_1.PlayerGui:FindFirstChild("DoNotPush") then
    local_1.PlayerGui.DoNotPush:Destroy()
end
```

**不猜变量名。** 全局、字段、方法和可靠调试名称保留原样；无法恢复或存在绑定冲突的局部变量统一为 `local_X`。

命名字段保留为 `{ a = "123456", b = "123456", c = "123456" }`；数字键 `1, 2, 3` 的安全初始化可还原为 `{ "123456", "123456", "123456" }`。数字键与命名字段不会相互猜测转换；稀疏或乱序数字键保留显式下标。字节码不保留原始排版，输出不保证与源码逐字相同。

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
})
```

**默认不设资源上限。** 不再因字符串长度、输入／输出大小、分析工作量或嵌套深度触发内置配额。仅在调用主动提供 `max_*` 数值时启用对应限制；`false` 关闭该项。字节码格式检查仍保留。

`opcode_multiplier` 可指定奇数解码乘数；自动识别失败时会回滚第一次尝试的分析缓存和工作量，再尝试 Roblox 编码；`upvalue_names` 提供根函数的实际外部上值名；`vector_constructor` / `integer_constructor` 指定宿主构造器，仅接受合格标识符路径。完整配置见 [`decompiler.lua`](decompiler.lua)。

Luau 类形状会在 `info.warnings` 中报告降级，因为标准 Lua 5.1/Luau 运行时没有统一的类对象 ABI；类名和成员写入会保留在生成源码中，但继承关系与运行时类检查无法恢复。

CLI 文件输出会优先使用 `os.tmpname()`；当宿主禁用临时文件 API 时，自动在目标文件同目录创建碰撞检查后的临时文件，不会因此放弃输出。

低层接口：`parse(bytes, options)` 解析容器，`decode(chunk, options)` 解码 `parse` 返回的结果；不要传入不可信的任意 Lua 表。

</details>

<a id="scope"></a>

[MIT License](LICENSE) · Copyright © 2026 LuaUnVeil
