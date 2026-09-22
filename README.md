# Luau Decompiler

纯 Lua 5.1 编写的单文件 Luau 字节码反编译器。版本 0.1.1，实验性。

```sh
lua5.1 decompiler.lua input.luac -o output.luau
```

Lua 5.1 使用 `require("decompiler")`，Luau 使用 `require("./decompiler")`，随后调用 `decompiler.decompile(bytes)`。输入必须是原始二进制 Luau Bytecode，不是 Lua 5.1 luac 文件。没有文件 API 的宿主自行提供输入字节串并保存结果。

核心不执行输入字节码，不依赖第三方模块。输出为结构化 Luau 源代码；无法结构化或不支持的指令会报错。字节码中被移除的注释、类型和原始排版不能恢复。

未知绑定使用 `local_X`，不推测局部变量名称；保留可确认的全局、字段、方法和可靠调试名称。

MIT 许可证，见 `LICENSE`。
