# Luau Decompiler

纯 Lua 5.1 编写的单文件 Luau 字节码反编译器。将二进制 Luau Bytecode 转换为结构化 Luau 源代码，不执行输入程序，不依赖原生模块、位运算库或 `string.unpack`。

当前版本：**0.1.2（实验性）**。分发和使用只需要 `decompiler.lua`；输出语言是 Luau，输入不是 Lua 5.1 的 `luac` 字节码。

## 使用

```sh
lua5.1 decompiler.lua input.luac -o output.luau
lua5.1 decompiler.lua input.luac --opcodes roblox -o output.luau
lua5.1 decompiler.lua input.luac --no-header --strict-trailing
```

输入或输出路径为 `-` 时使用标准输入或标准输出。默认尝试普通 opcode，再尝试解码乘数为 203 的编码；`--opcodes plain` 只接受普通指令。只转换 opcode 字节，不修改 AUX 或操作数字节。失败返回非零退出码，诊断中的控制字符会转义，过长诊断会截断。

**默认不覆盖已有文件。** 覆盖已有输出必须明确使用 `--force`：

```sh
lua5.1 decompiler.lua input.luac -o output.luau --force
```

CLI 拒绝明显的输入/输出路径别名；即使指定 `--force`，输出内容与输入字节完全相同时仍保守拒绝。输出先写入目标目录中的临时文件，关闭成功后再重命名替换目标。生成、写入或重命名失败不会主动截断旧输出。强制替换在 POSIX 上替换目标目录项，而不是写入符号链接指向的文件。

文件输出需要宿主提供 `io`、`os.tmpname`、`os.remove` 和 `os.rename`。**只应输出到可信、不可被其他不可信用户修改的目录**：标准 Lua 5.1 没有可移植的 `lstat`、独占创建或原子“不覆盖”接口，路径检查和创建之间仍存在竞争窗口。进程被强制终止时可能遗留临时文件；没有承诺断电持久性。不同平台的重命名、权限和临时文件语义可能不同。

## 模块 API

Lua 5.1：

```lua
local decompiler = require("decompiler")
local file = assert(io.open("input.luac", "rb"))
local bytes = file:read(16 * 1024 * 1024 + 1)
file:close()
local ok, source, info = pcall(decompiler.decompile, bytes)
if not ok then error(source) end
print(source)
```

Luau 宿主：

```lua
local decompiler = require("./decompiler")
-- bytes 由宿主提供，必须是原始二进制字符串。
local source, info = decompiler.decompile(bytes)
```

没有文件 API 的宿主只使用 `decompile`，自行提供字节串并保存结果。库的核心路径不调用 `io`、`os`、`debug`、`loadstring` 或字节码执行器。

```lua
local source, info = decompiler.decompile(bytes, options)
local chunk = decompiler.parse(bytes, options)
local decoded = decompiler.decode(chunk, options)
```

`decode` 是供开发者操作 `parse` 返回值的低层接口；不要把任意外部 Lua 表当作合法解析结果传入。解析结果和配置表都应由可信调用代码管理。

`info` 包含 `version`、`type_version`、`prototypes`、`instruction_words`、`opcode_multiplier`、`trailing_bytes`、`warnings`、`decompiler_version`，以及本次请求消耗的 `work_units` 和 `intermediate_nodes`。后两项是内部预算计数，不是时间或内存测量值。

## 名称与输出

不能可靠恢复的绑定统一命名为 `local_X`，不从服务名、字段名、函数用途或 `require` 参数猜测局部变量名。可确认的全局、字段、方法、导入路径和可靠调试名称保留原始拼写与大小写。调试名称存在绑定冲突时退回 `local_X`。

```lua
local local_1 = game:GetService("Players").LocalPlayer
if local_1.PlayerGui:FindFirstChild("DoNotPush") then
    local_1.PlayerGui.DoNotPush:Destroy()
end
```

常见控制流会恢复为 `if/elseif/else`、`while`、`repeat/until`、数值或泛型 `for`、`break`、`continue`，而不是输出寄存器分派器。也处理闭包、上值、可变参数、表构造和多返回值。部分开放 `SETLIST` 会生成小型辅助函数，以保留 `nil` 空洞和返回值数量。

## 配置

```lua
local source = decompiler.decompile(bytes, {
    header = false,
    expression_if = false,
    strict_trailing = true,
    opcode_multiplier = 1,
    max_bytes = 8 * 1024 * 1024,
    max_work = 20000000,
    max_nodes = 100000,
    max_output_bytes = 8 * 1024 * 1024,
})
```

`header` 控制生成头；`expression_if` 控制 Luau if 表达式优化；`indent` 只允许至多 16 个空格或制表符。`opcode_multiplier` 必须是 1–255 的奇整数。`upvalue_names` 可为具有外部上值的根函数提供无重复、连续排列的实际名称。

`vector_constructor` 默认为 `vector.create`；`integer_constructor` 用于需要宿主整数构造器的常量。两者只允许 `Namespace.constructor` 形式的合格标识符，不接受任意 Lua 表达式。`vector_size` 为 3 或 4。

所有数值限制必须是有限正整数，且不能超过下表硬上限。每次调用使用独立预算；失败不会污染后续请求。

| 选项 | 默认值 | 硬上限 | 作用 |
|---|---:|---:|---|
| `max_bytes` | 16,777,216 | 67,108,864 | 输入字节数 |
| `max_strings` | 100,000 | 1,000,000 | 字符串表项 |
| `max_string_bytes` | 1,048,576 | 16,777,216 | 单个字符串长度 |
| `max_protos` | 10,000 | 100,000 | 函数原型数量 |
| `max_instructions` | 250,000 | 4,000,000 | 总指令字数，含 AUX |
| `max_constants` | 100,000 | 1,000,000 | 全部原型的常量总数 |
| `max_table_entries` | 200,000 | 1,000,000 | 表模板项目总数 |
| `max_debug_entries` | 200,000 | 1,000,000 | 调试局部变量项目总数 |
| `max_nodes` | 250,000 | 1,000,000 | 中间节点及常量展开预算 |
| `max_work` | 50,000,000 | 500,000,000 | 解析、分析和生成工作预算 |
| `max_depth` | 64 | 128 | 函数/结构化控制流深度 |
| `max_expression_depth` | 128 | 256 | 表达式遍历深度 |
| `max_function_expansions` | 10,000 | 100,000 | 闭包源码展开次数 |
| `max_output_bytes` | 16,777,216 | 67,108,864 | 输出及中间渲染大小 |
| `max_scope_locals` | 180 | 200 | 单层作用域局部变量目标上限 |

预算不是精确运行时配额。数据流分析有保守的二次复杂度预估，大型合法函数也可能触发限制。处理不可信输入的服务还应在宿主层限制并发、内存、CPU 时间和输入流读取时间；不要仅依靠 Lua 内部计数保护整个服务。

## 支持范围与限制

解析器识别版本 3–14 的已知容器布局，包括版本 11 的反馈槽和版本 12 起的原型长度边界。识别布局不代表覆盖该版本全部指令组合。版本 100 的类字节码、类常量、`NEWCLASS`、`NEWCLASSMEMBER`、`NATIVECALL`、`CMPPROTO` 等不支持，遇到时拒绝。

已解码指令（包括不可达指令）会检查寄存器、常量引用、跳转边界和主要标志字段。检查不是官方虚拟机验证器的完整替代。无法结构化的控制流、无法确定的开放多返回值和资源预算溢出会报错，而不是生成空实现假装成功。

不自动解密或解压外层容器，不提供任意自定义 opcode 映射。默认仅容忍 24 字节的不透明尾部，并产生警告；这不是签名验证。`--strict-trailing` / `strict_trailing=true` 拒绝所有尾部数据。`allow_trailing=true` 仅用于调用方明确允许其他尾部格式的情况。

字节码不包含的信息不能凭空恢复：注释、已擦除的类型注解、原始排版和被移除的变量名不在恢复承诺内。生成源码不构成完全行为等价保证；官方 Luau、Roblox 宿主和不同操作系统的兼容性应由接入方独立确认。

## 许可证

MIT，见 `LICENSE`。单文件内亦保留许可证文本。
