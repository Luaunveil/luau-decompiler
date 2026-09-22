--[=[
MIT License

Copyright (c) 2026 LuaUnVeil

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]=]

-- Luau bytecode decompiler. Runtime syntax: Lua 5.1; output syntax: Luau.
-- MIT License. No native modules, bit library, string.unpack or input execution.
local D = { version = "0.1.4" }
local floor, concat, insert = math.floor, table.concat, table.insert
local function fail(message)
    -- Bytecode error chunks and file names are untrusted diagnostic text.
    message = tostring(message)
    local truncated = #message > 1024
    message = message:sub(1, 1024):gsub('[%z\1-\31\127-\255]', function(c)
        return string.format("\\%03d", c:byte())
    end)
    error("luau-decompiler: " .. message .. (truncated and " [truncated]" or ""), 0)
end
local function check(test, message) if not test then fail(message) end end
local function copy(t) local o = {}; for k, v in pairs(t) do o[k] = v end; return o end
local function set(words) local t = {}; for w in words:gmatch("%S+") do t[w] = true end; return t end
local keywords = set("and break do else elseif end false for function if in local nil not or repeat return then true until while continue type export")
local function identifier(s) return type(s) == "string" and s:match("^[A-Za-z_][A-Za-z0-9_]*$") and not keywords[s] end
-- Resource ceilings are opt-in. Nil/false/math.huge means unlimited.
-- This does not disable bytecode format checks or the host VM's own limits.
local resourceLimits = set("max_bytes max_strings max_string_bytes max_protos max_instructions max_constants max_table_entries max_debug_entries max_nodes max_work max_depth max_expression_depth max_function_expansions max_output_bytes")
local function configure(options)
    check(options == nil or type(options) == "table", "options must be a table")
    local o = copy(options or {})
    for name in pairs(resourceLimits) do
        local n = o[name]
        if n == nil or n == false then n = math.huge end
        check(type(n) == "number" and n >= 1 and n == floor(n), name .. " must be a positive integer or false (unlimited)")
        o[name] = n
    end
    -- Lexical scope splitting is required by the source compiler, not an input cap.
    o.max_scope_locals = o.max_scope_locals or 180
    check(type(o.max_scope_locals) == "number" and o.max_scope_locals >= 1 and o.max_scope_locals <= 200 and o.max_scope_locals == floor(o.max_scope_locals), "max_scope_locals must be an integer in 1..200")
    for _, name in ipairs({ "header", "expression_if", "strict_trailing", "allow_trailing" }) do
        check(o[name] == nil or type(o[name]) == "boolean", name .. " must be boolean")
    end
    check(o.indent == nil or (type(o.indent) == "string" and #o.indent <= 16 and o.indent:match("^[ \t]*$")), "indent must be at most 16 spaces/tabs")
    check(o.vector_size == nil or o.vector_size == 3 or o.vector_size == 4, "vector_size must be 3 or 4")
    for _, name in ipairs({ "vector_constructor", "integer_constructor" }) do
        local text = o[name]
        if text ~= nil then
            check(type(text) == "string" and #text <= 256, name .. " must be a qualified identifier")
            local count = 0
            for part in text:gmatch("[^.]+") do check(identifier(part), name .. " must be a qualified identifier"); count = count + #part end
            local _, dots = text:gsub("%.", "")
            check(count > 0 and count + dots == #text and not text:find("..", 1, true) and text:sub(1, 1) ~= "." and text:sub(-1) ~= ".", name .. " must be a qualified identifier")
        end
    end
    if o.opcode_multiplier ~= nil then
        local n = o.opcode_multiplier
        check(type(n) == "number" and n >= 1 and n <= 255 and n == floor(n) and n % 2 == 1, "opcode_multiplier must be odd, 1..255")
    end
    if o.upvalue_names ~= nil then
        check(type(o.upvalue_names) == "table", "upvalue_names must be an array")
        local names, seen, count = {}, {}, 0
        for index, name in pairs(o.upvalue_names) do
            check(type(index) == "number" and index >= 1 and index <= 255 and index == floor(index) and identifier(name), "invalid external upvalue name")
            check(not seen[name], "external upvalue names must be distinct")
            names[index], seen[name], count = name, true, count + 1
        end
        for i = 1, count do check(names[i], "upvalue_names must be a dense array") end
        o.upvalue_names = names
    end
    o._budget = { work = 0, nodes = 0, constants = 0, entries = 0, debug = 0 }
    o._quoted = {}
    return o
end
local function spend(options, amount)
    local budget = options._budget
    budget.work = budget.work + (amount or 1)
    check(budget.work <= options.max_work, "analysis work limit exceeded")
end
local function nodes(options, amount)
    local budget = options._budget
    budget.nodes = budget.nodes + (amount or 1)
    check(budget.nodes <= options.max_nodes, "intermediate node limit exceeded")
    spend(options, amount)
end
local function join(options, parts, separator)
    separator = separator or ""
    local size = math.max(0, #parts - 1) * #separator
    for _, part in ipairs(parts) do size = size + #part end
    check(size <= options.max_output_bytes, "output exceeds size limit")
    spend(options, #parts + floor(size / 1024))
    return concat(parts, separator)
end
local function quote(s, options)
    local cached = options and options._quoted[s]
    if cached then return cached end
    -- Native scanning/escaping avoids a second Lua-level per-byte pass and
    -- memoization avoids re-escaping a large constant at every reference.
    local escaped = s:gsub('[%z\1-\31\127-\255\\"]', function(c)
        local n = c:byte()
        if n == 10 then return "\\n" elseif n == 13 then return "\\r" elseif n == 9 then return "\\t"
        elseif c == '"' then return '\\"' elseif c == '\\' then return '\\\\' end
        return string.format("\\%03d", n)
    end)
    if options then
        check(#escaped + 2 <= options.max_output_bytes, "string literal exceeds output limit")
        spend(options, #s)
    end
    local text = '"' .. escaped .. '"'
    if options then options._quoted[s] = text end
    return text
end
local function number(n)
    if n ~= n then return "(0 / 0)" end
    if n == math.huge then return "(1 / 0)" end
    if n == -math.huge then return "(-1 / 0)" end
    if n == 0 and 1 / n < 0 then return "(-1 / (1 / 0))" end
    for p = 1, 17 do local s = string.format("%." .. p .. "g", n); if tonumber(s) == n then return s end end
    return string.format("%.17g", n)
end
local function reader(data, options)
    local r = { data = data, pos = 1, limit = #data, options = options }
    function r:take(n)
        check(n >= 0 and n <= self.limit - self.pos + 1, "truncated input at byte " .. self.pos)
        local s = self.data:sub(self.pos, self.pos + n - 1); self.pos = self.pos + n; return s
    end
    function r:u8() check(self.pos <= self.limit, "truncated input at byte " .. self.pos); local v = self.data:byte(self.pos); self.pos = self.pos + 1; return v end
    function r:u32() local a, b, c, d = self:take(4):byte(1, 4); return a + b * 256 + c * 65536 + d * 16777216 end
    function r:i32() local n = self:u32(); return n >= 2147483648 and n - 4294967296 or n end
    function r:varint()
        local n, m = 0, 1
        for i = 1, 5 do
            local b = self:u8(); check(i < 5 or b < 16, "varint overflows uint32 at byte " .. (self.pos - 1))
            n = n + (b % 128) * m; if b < 128 then return n end; m = m * 128
        end
        fail("unterminated varint")
    end
    function r:count(label, max)
        local n = self:varint(); check(n <= (max or self.limit) and n <= self.limit - self.pos + 1, label .. " count exceeds limit"); spend(options, n); return n
    end
    function r:float(bits)
        local lo, hi, mantissa, exponent, sign
        if bits == 32 then
            hi = self:u32(); sign = hi >= 2147483648 and -1 or 1
            exponent = floor(hi / 8388608) % 256; mantissa = hi % 8388608
            if exponent == 255 then return mantissa == 0 and sign * math.huge or 0 / 0 end
            if exponent == 0 then return sign * (mantissa / 8388608) * 2 ^ (-126) end
            return sign * (1 + mantissa / 8388608) * 2 ^ (exponent - 127)
        end
        lo, hi = self:u32(), self:u32(); sign = hi >= 2147483648 and -1 or 1
        exponent = floor(hi / 1048576) % 2048; mantissa = (hi % 1048576) * 4294967296 + lo
        if exponent == 2047 then return mantissa == 0 and sign * math.huge or 0 / 0 end
        if exponent == 0 then return sign * (mantissa / 4503599627370496) * 2 ^ (-1022) end
        return sign * (1 + mantissa / 4503599627370496) * 2 ^ (exponent - 1023)
    end
    function r:uint64text()
        local bytes = {}
        for i = 1, 10 do
            local b = self:u8(); check(i < 10 or b <= 1, "uint64 overflow")
            bytes[#bytes + 1] = b % 128; if b < 128 then break end
        end
        local digits = { 0 }
        for i = #bytes, 1, -1 do
            local carry = bytes[i]
            for j = 1, #digits do local n = digits[j] * 128 + carry; digits[j] = n % 10; carry = floor(n / 10) end
            while carry > 0 do digits[#digits + 1] = carry % 10; carry = floor(carry / 10) end
        end
        local out = {}; for i = #digits, 1, -1 do out[#out + 1] = tostring(digits[i]) end; return concat(out)
    end
    return r
end
local function parse(data, options)
    check(type(data) == "string", "input must be a byte string")
    check(#data <= (options.max_bytes or 67108864), "input exceeds max_bytes")
    local r = reader(data, options); local version = r:u8()
    if version == 0 then fail("compiler error: " .. data:sub(2, 1025)) end
    check(version >= 3 and version <= 14, "unsupported bytecode version " .. version .. " (expected 3..14)")
    local types = version >= 4 and r:u8() or 0
    check(version < 4 or (types >= 1 and types <= 3), "unsupported type version " .. types)
    local chunk = { version = version, types = types, strings = {}, protos = {}, warnings = {} }
    for i = 1, r:count("string", options.max_strings or 1000000) do chunk.strings[i] = r:take(r:count("string byte", options.max_string_bytes)) end
    local function str() local i = r:varint(); check(i == 0 or chunk.strings[i], "invalid string index " .. i); return chunk.strings[i] end
    if types == 3 then local i = r:u8(); while i ~= 0 do str(); i = r:u8() end end
    local np = r:count("prototype", options.max_protos or 100000)
    check(np > 0, "empty prototype table")
    local total = 0
    for id = 0, np - 1 do
        local size = version >= 12 and r:count("prototype byte") or nil
        local start = r.pos
        if size then check(start + size - 1 <= #data, "prototype extends past input"); r.limit = start + size - 1 end
        local p = { id = id, stack = r:u8(), params = r:u8(), nups = r:u8(), vararg = r:u8(), constants = {}, children = {}, locals = {}, upnames = {} }
        check(p.stack >= p.params and p.stack <= 255 and p.vararg <= 1, "invalid prototype header " .. id)
        p.flags = version >= 4 and r:u8() or 0
        if version >= 4 then p.typeinfo = r:take(r:count("type info byte")) end
        p.sizecode = r:count("instruction word", options.max_instructions or 4000000)
        total = total + p.sizecode; check(total <= (options.max_instructions or 4000000), "total instruction limit exceeded")
        p.code = {}; for pc = 0, p.sizecode - 1 do p.code[pc] = r:u32() end
        p.nconstants = r:count("constant", options.max_constants or 1000000)
        options._budget.constants = options._budget.constants + p.nconstants
        check(options._budget.constants <= options.max_constants, "total constant limit exceeded")
        for k = 0, p.nconstants - 1 do
            local tag = r:u8(); local c = { tag = tag }
            if tag == 0 then c.value = nil
            elseif tag == 1 then local b = r:u8(); check(b < 2, "invalid boolean constant"); c.value = b == 1
            elseif tag == 2 then c.value = r:float(64)
            elseif tag == 3 then c.value = str(); check(c.value ~= nil, "null string constant")
            elseif tag == 4 then c.value = r:u32()
            elseif tag == 5 or tag == 8 then
                c.entries = {}
                local entries = r:count("table entry", options.max_table_entries)
                options._budget.entries = options._budget.entries + entries
                check(options._budget.entries <= options.max_table_entries, "total table entry limit exceeded")
                for j = 1, entries do
                    local key = r:varint(); local value = tag == 8 and r:i32() or -1
                    check(key < k and (value < 0 or value < k), "forward/out-of-range table constant")
                    c.entries[j] = { key = key, value = value }
                end
            elseif tag == 6 then c.value = r:varint(); check(c.value < id, "forward closure prototype")
            elseif tag == 7 or tag == 11 then
                c.value = {}; for j = 1, 4 do c.value[j] = r:float(tag == 7 and 32 or 64) end
            elseif tag == 9 then
                local sign = r:u8(); check(sign < 2, "invalid integer sign")
                c.value = (sign == 1 and "-" or "") .. r:uint64text()
            elseif tag == 10 then fail("Luau class constants are not implemented")
            else fail("unknown constant tag " .. tag .. " in prototype " .. id) end
            p.constants[k] = c
        end
        for j = 1, r:count("child prototype", np) do local child = r:varint(); check(child < id, "forward child prototype"); p.children[j] = child end
        p.linedefined, p.debugname = r:varint(), str()
        local lineinfo = r:u8(); check(lineinfo <= 1, "invalid line-info flag")
        if lineinfo == 1 then
            local gap = r:u8(); check(gap <= 31, "invalid line gap")
            p.lines = {}; local offsets, offset = {}, 0
            for pc = 0, p.sizecode - 1 do offset = (offset + r:u8()) % 256; offsets[pc] = offset end
            local stride, line = 2 ^ gap, 0
            for interval = 0, floor((p.sizecode - 1) / stride) do
                line = line + r:i32()
                for pc = interval * stride, math.min((interval + 1) * stride - 1, p.sizecode - 1) do p.lines[pc] = line + offsets[pc] end
            end
        end
        local debug = r:u8(); check(debug <= 1, "invalid debug-info flag")
        if debug == 1 then
            local count = r:count("debug local", options.max_debug_entries)
            options._budget.debug = options._budget.debug + count
            check(options._budget.debug <= options.max_debug_entries, "total debug entry limit exceeded")
            for j = 1, count do
                local v = { name = str(), first = r:varint(), last = r:varint(), reg = r:u8() }
                check(v.first <= v.last and v.last <= p.sizecode and v.reg < p.stack, "invalid local lifetime"); p.locals[j] = v
            end
            local nu = r:count("upvalue name", 255); check(nu == p.nups, "upvalue name count mismatch")
            for j = 1, nu do p.upnames[j] = str() end
        end
        if version >= 11 then
            p.feedback = {}
            for j = 1, r:count("feedback slot") do
                local kind, pc = r:u8(), r:varint(); check(kind == 0 and pc < p.sizecode, "invalid feedback slot"); p.feedback[j] = pc
            end
        end
        if size then
            check(r.pos <= start + size, "prototype size mismatch")
            p.extension = r:take(start + size - r.pos)
            r.limit = #data
        end
        chunk.protos[id + 1] = p
    end
    chunk.main = r:varint(); check(chunk.main < np, "invalid main prototype")
    chunk.bytes_consumed = r.pos - 1; chunk.trailing = data:sub(r.pos)
    if #chunk.trailing > 0 then
        if options.strict_trailing or (#chunk.trailing ~= 24 and not options.allow_trailing) then fail("unexpected " .. #chunk.trailing .. " trailing bytes") end
        chunk.warnings[#chunk.warnings + 1] = "Preserved " .. #chunk.trailing .. " opaque trailing bytes; no signature verification was performed."
    end
    chunk.instruction_words = total
    return chunk
end
function D.parse(data, options) return parse(data, configure(options)) end
local opnames = {}
for name in ("NOP BREAK LOADNIL LOADB LOADN LOADK MOVE GETGLOBAL SETGLOBAL GETUPVAL SETUPVAL CLOSEUPVALS GETIMPORT GETTABLE SETTABLE GETTABLEKS SETTABLEKS GETTABLEN SETTABLEN NEWCLOSURE NAMECALL CALL RETURN JUMP JUMPBACK JUMPIF JUMPIFNOT JUMPIFEQ JUMPIFLE JUMPIFLT JUMPIFNOTEQ JUMPIFNOTLE JUMPIFNOTLT ADD SUB MUL DIV MOD POW ADDK SUBK MULK DIVK MODK POWK AND OR ANDK ORK CONCAT NOT MINUS LENGTH NEWTABLE DUPTABLE SETLIST FORNPREP FORNLOOP FORGLOOP FORGPREP_INEXT FASTCALL3 FORGPREP_NEXT NATIVECALL GETVARARGS DUPCLOSURE PREPVARARGS LOADKX JUMPX FASTCALL COVERAGE CAPTURE SUBRK DIVRK FASTCALL1 FASTCALL2 FASTCALL2K FORGPREP JUMPXEQKNIL JUMPXEQKB JUMPXEQKN JUMPXEQKS IDIV IDIVK GETUDATAKS SETUDATAKS NAMECALLUDATA NEWCLASSMEMBER CALLFB CMPPROTO FASTPCALL NEWCLASS"):gmatch("%S+") do opnames[#opnames + 1] = name end
local auxiliary = set("GETGLOBAL SETGLOBAL GETIMPORT GETTABLEKS SETTABLEKS NAMECALL JUMPIFEQ JUMPIFLE JUMPIFLT JUMPIFNOTEQ JUMPIFNOTLE JUMPIFNOTLT NEWTABLE SETLIST FORGLOOP FASTCALL3 LOADKX FASTCALL2 FASTCALL2K JUMPXEQKNIL JUMPXEQKB JUMPXEQKN JUMPXEQKS GETUDATAKS SETUDATAKS NAMECALLUDATA NEWCLASSMEMBER CALLFB CMPPROTO NEWCLASS")
local conditional = set("JUMPIF JUMPIFNOT JUMPIFEQ JUMPIFLE JUMPIFLT JUMPIFNOTEQ JUMPIFNOTLE JUMPIFNOTLT JUMPXEQKNIL JUMPXEQKB JUMPXEQKN JUMPXEQKS CMPPROTO")
local unconditional = set("JUMP JUMPBACK JUMPX")
local forprep = set("FORGPREP FORGPREP_NEXT FORGPREP_INEXT FORNPREP")
local fast = set("FASTCALL FASTCALL1 FASTCALL2 FASTCALL2K FASTCALL3 FASTPCALL")
local registerABC = set("GETTABLE SETTABLE ADD SUB MUL DIV MOD POW AND OR IDIV")
local registerAB = set("MOVE GETTABLEN SETTABLEN NOT MINUS LENGTH")
local registerK = set("ADDK SUBK MULK DIVK MODK POWK ANDK ORK IDIVK")
local property = set("GETTABLEKS SETTABLEKS GETUDATAKS SETUDATAKS NAMECALL NAMECALLUDATA")
local function validateInstruction(p, i)
    local op, a, b, c = i.op, i.a, i.b, i.c
    local function reg(r) check(r >= 0 and r < p.stack, "register out of range in " .. op .. " at pc " .. i.pc) end
    local function range(r, count) check(r >= 0 and r + count <= p.stack, "register range out of bounds in " .. op .. " at pc " .. i.pc) end
    local function constant(k, tag)
        local value = p.constants[k]
        check(value and (not tag or value.tag == tag), "invalid constant operand in " .. op .. " at pc " .. i.pc)
        return value
    end
    if registerABC[op] then reg(a); reg(b); reg(c)
    elseif registerAB[op] then reg(a); reg(b)
    elseif registerK[op] then reg(a); reg(b); constant(c)
    elseif property[op] then
        reg(a); reg(b); constant((op == "GETUDATAKS" or op == "SETUDATAKS" or op == "NAMECALLUDATA") and i.aux % 65536 or i.aux, 3)
        if op == "NAMECALL" or op == "NAMECALLUDATA" then reg(a + 1) end
    elseif op == "LOADNIL" or op == "LOADN" or op == "NEWCLOSURE" or op == "DUPCLOSURE" then reg(a)
    elseif op == "LOADB" then reg(a); check(b <= 1, "invalid LOADB boolean")
    elseif op == "LOADK" or op == "LOADKX" then reg(a); constant(op == "LOADK" and i.d or i.aux)
    elseif op == "GETGLOBAL" or op == "SETGLOBAL" then reg(a); constant(i.aux, 3)
    elseif op == "GETUPVAL" or op == "SETUPVAL" then reg(a); check(b < p.nups, "upvalue out of range")
    elseif op == "GETIMPORT" then
        reg(a); local k = constant(i.d, 4)
        check(k.value == i.aux, "GETIMPORT path does not match its constant")
    elseif op == "CLOSEUPVALS" then range(a, 0)
    elseif op == "CALL" or op == "CALLFB" then
        reg(a); if b > 0 then range(a, b) end; if c > 1 then range(a, c - 1) end
    elseif op == "RETURN" then range(a, b == 0 and 0 or b - 1)
    elseif op == "GETVARARGS" then check(p.vararg == 1, "GETVARARGS in a nonvariadic function"); range(a, b == 0 and 1 or b - 1)
    elseif op == "PREPVARARGS" then check(p.vararg == 1 and a == p.params, "invalid PREPVARARGS")
    elseif op == "NEWTABLE" then reg(a); check(b <= 31, "invalid NEWTABLE hash size")
    elseif op == "DUPTABLE" then reg(a); local k = constant(i.d); check(k.tag == 5 or k.tag == 8, "invalid DUPTABLE template")
    elseif op == "SETLIST" then reg(a); range(b, c == 0 and 0 or c - 1); check(i.aux >= 1, "invalid SETLIST index")
    elseif op == "CONCAT" then reg(a); reg(b); reg(c); check(b <= c, "invalid concatenation range")
    elseif op == "SUBRK" or op == "DIVRK" then reg(a); constant(b); reg(c)
    elseif op == "FORNPREP" or op == "FORNLOOP" or forprep[op] then range(a, 3)
    elseif op == "FORGLOOP" then local n = i.aux % 256; check(n > 0, "empty FORGLOOP result range"); range(a, 3 + n)
    elseif op == "JUMPIF" or op == "JUMPIFNOT" then reg(a)
    elseif op == "JUMPXEQKNIL" or op == "JUMPXEQKB" then
        reg(a); check(i.aux % 2147483648 <= (op == "JUMPXEQKB" and 1 or 0), "invalid comparison flags")
    elseif op == "JUMPXEQKN" or op == "JUMPXEQKS" then reg(a); constant(i.aux % 16777216, op == "JUMPXEQKN" and 2 or 3)
    elseif conditional[op] and op ~= "CMPPROTO" then reg(a); reg(i.aux)
    elseif op == "FASTCALL1" or op == "FASTCALL2" or op == "FASTCALL2K" or op == "FASTCALL3" then
        reg(b)
        if op == "FASTCALL2" or op == "FASTCALL3" then reg(i.aux % 256) end
        if op == "FASTCALL3" then reg(floor(i.aux / 256) % 256) end
        if op == "FASTCALL2K" then constant(i.aux) end
    elseif op == "FASTPCALL" then check(a <= 1, "invalid FASTPCALL function")
    elseif op == "NATIVECALL" or op == "CMPPROTO" or op == "NEWCLASS" or op == "NEWCLASSMEMBER" then fail("unsupported " .. op)
    end
end
local function decode(chunk, multiplier, options)
    for _, p in ipairs(chunk.protos) do
        local instructions, bypc, pc = {}, {}, 0
        while pc < p.sizecode do
            spend(options)
            local w = p.code[pc]; local op = opnames[(w % 256 * multiplier) % 256 + 1]
            check(op ~= nil, "invalid opcode at prototype " .. p.id .. ", pc " .. pc)
            local d, e = floor(w / 65536), floor(w / 256)
            local i = { pc = pc, op = op, a = floor(w / 256) % 256, b = floor(w / 65536) % 256, c = floor(w / 16777216), d = d < 32768 and d or d - 65536, e = e < 8388608 and e or e - 16777216 }
            i.next = pc + (auxiliary[op] and 2 or 1)
            if auxiliary[op] then check(pc + 1 < p.sizecode, "missing AUX"); i.aux = p.code[pc + 1] end
            if conditional[op] or unconditional[op] or forprep[op] or op == "FORNLOOP" or op == "FORGLOOP" then i.target = pc + 1 + (op == "JUMPX" and i.e or i.d)
            elseif op == "LOADB" and i.c ~= 0 then i.target = pc + 1 + i.c end
            if op == "NEWCLOSURE" or op == "DUPCLOSURE" then
                local child
                if op == "NEWCLOSURE" then child = p.children[i.d + 1]
                else local k = p.constants[i.d]; check(k and k.tag == 6, "invalid closure constant"); child = k.value end
                check(child ~= nil, "invalid closure child"); i.child = child; i.captures = {}
                for j = 1, chunk.protos[child + 1].nups do
                    local cw = p.code[i.next]; check(cw and opnames[(cw % 256 * multiplier) % 256 + 1] == "CAPTURE", "missing CAPTURE")
                    local kind, index = floor(cw / 256) % 256, floor(cw / 65536) % 256
                    check(kind <= 2, "unsupported capture kind " .. kind)
                    check((kind == 2 and index < p.nups) or (kind ~= 2 and index < p.stack), "invalid capture index")
                    i.captures[j] = { kind = kind, index = index }; i.next = i.next + 1
                end
            elseif op == "CAPTURE" then fail("orphan CAPTURE at pc " .. pc) end
            instructions[#instructions + 1], bypc[pc] = i, i; pc = i.next
        end
        check(pc == p.sizecode, "instruction length mismatch")
        for _, i in ipairs(instructions) do
            validateInstruction(p, i)
            if i.target then check(bypc[i.target] ~= nil or i.target == p.sizecode, "jump into AUX/capture or outside prototype at pc " .. i.pc) end
            if fast[i.op] then
                local call = bypc[i.pc + 1 + i.c]
                check(call and (call.op == "CALL" or call.op == "CALLFB"), "invalid fastcall fallback")
            end
        end
        p.instructions, p.bypc = instructions, bypc
    end
    chunk.opcode_multiplier = multiplier
end
local function decodeChunk(chunk, options)
    local multiplier = options.opcode_multiplier
    if multiplier then check(multiplier >= 1 and multiplier <= 255 and multiplier % 2 == 1, "opcode_multiplier must be odd, 1..255"); decode(chunk, multiplier, options)
    else
        local ok, err = pcall(decode, chunk, 1, options)
        if not ok then local encoded, err2 = pcall(decode, chunk, 203, options); if not encoded then fail("neither plain nor encoded opcodes validated:\n" .. tostring(err) .. "\n" .. tostring(err2)) end end
    end
    return chunk
end
function D.decode(chunk, options)
    check(type(chunk) == "table" and type(chunk.protos) == "table", "decode expects a parsed chunk")
    return decodeChunk(chunk, configure(options))
end
local function cfg(p, options)
    local leaders = { [0] = true, [p.sizecode] = true }
    for _, i in ipairs(p.instructions) do
        if i.target then leaders[i.target] = true; leaders[i.next] = true end
        if i.op == "RETURN" then leaders[i.next] = true end
        -- A latch can share its original block with real loop-body operations.
        -- Split it so the structurer does not discard those operations.
        if i.op == "FORNLOOP" or i.op == "FORGLOOP" then leaders[i.pc] = true end
    end
    local starts = {}; for pc in pairs(leaders) do if pc < p.sizecode then starts[#starts + 1] = pc end end; table.sort(starts)
    local blocks, map = {}, {}
    for n, pc in ipairs(starts) do
        local b = { id = n, pc = pc, finish = starts[n + 1] or p.sizecode, instructions = {}, preds = {}, succ = {}, input = {}, output = {}, stmts = {} }
        blocks[n], map[pc] = b, b
    end
    local exit = { id = #blocks + 1, pc = p.sizecode, finish = p.sizecode, instructions = {}, preds = {}, succ = {}, input = {}, output = {}, stmts = {}, exit = true }
    map[p.sizecode], blocks[#blocks + 1] = exit, exit
    local function edge(b, pc)
        local to = map[pc]; check(to ~= nil, "invalid block edge")
        for _, x in ipairs(b.succ) do if x == to then return to end end
        b.succ[#b.succ + 1] = to; to.preds[#to.preds + 1] = b; return to
    end
    for _, b in ipairs(blocks) do
        local pc = b.pc
        while pc < b.finish do local i = p.bypc[pc]; check(i, "missing instruction"); b.instructions[#b.instructions + 1] = i; i.block = b; pc = i.next end
        local last = b.instructions[#b.instructions]; b.last = last
        if last then
            if last.op == "RETURN" then edge(b, p.sizecode)
            elseif unconditional[last.op] or (last.op == "LOADB" and last.c ~= 0) or (forprep[last.op] and last.op ~= "FORNPREP") then edge(b, last.target)
            elseif last.target then edge(b, last.target); edge(b, last.next)
            else edge(b, b.finish) end
        end
    end
    local queue = { blocks[1] }; blocks[1].reachable = true; local qi = 1
    while qi <= #queue do local b = queue[qi]; qi = qi + 1; for _, s in ipairs(b.succ) do if not s.reachable then s.reachable = true; queue[#queue + 1] = s end end end
    for _, b in ipairs(blocks) do local preds = {}; for _, x in ipairs(b.preds) do if x.reachable then preds[#preds + 1] = x end end; b.preds = preds end
    return { blocks = blocks, map = map, entry = blocks[1], exit = exit, options = options }
end
local function literal(text) return { tag = "literal", text = text } end
local function ref(v) return { tag = "ref", value = v } end
local function unary(op, a) return { tag = "unary", op = op, a = a } end
local function binary(op, a, b) return { tag = "binary", op = op, a = a, b = b } end
local function negate(e)
    if e.tag == "unary" and e.op == "not" then return e.a end
    if e.tag == "literal" and e.text == "true" then return literal("false") end
    if e.tag == "literal" and e.text == "false" then return literal("true") end
    if e.tag == "binary" and e.op == "==" then return binary("~=", e.a, e.b) end
    if e.tag == "binary" and e.op == "~=" then return binary("==", e.a, e.b) end
    -- Do not rewrite not(a < b) to a >= b: NaN and metamethod semantics differ.
    return unary("not", e)
end
local function root(v)
    local r = v; while r.parent do r = r.parent end
    while v.parent do local next = v.parent; v.parent = r; v = next end
    return r
end
local function unite(a, b)
    a, b = root(a), root(b); if a == b then return a end
    if a.id > b.id then a, b = b, a end
    b.parent = a; a.captured = a.captured or b.captured; a.parameter = a.parameter or b.parameter
    return a
end
local function ir(chunk, p, options)
    -- Reserve conservative costs for quadratic data-flow/lexical passes before
    -- allocating graphs. Actual expression traversal is charged separately.
    spend(options, p.sizecode * p.sizecode + #p.locals * (p.sizecode + p.stack))
    local g = cfg(p, options); local ctx = { chunk = chunk, proto = p, graph = g, values = {}, params = {}, options = options, closures = {} }
    local function value(reg, pc, b, kind)
        nodes(options)
        local v = { id = #ctx.values + 1, reg = reg, pc = pc, block = b, kind = kind }; ctx.values[#ctx.values + 1] = v; return v
    end
    local function incoming(b, reg)
        if not b.input[reg] then b.input[reg] = value(reg, b.pc, b, "phi") end
        return b.input[reg]
    end
    for r = 0, p.params - 1 do local v = value(r, -1, g.entry, "param"); v.parameter = r + 1; ctx.params[r + 1] = v; g.entry.input[r] = v end
    local function constant(k, depth)
        depth = (depth or 0) + 1; check(depth <= options.max_expression_depth, "constant nesting too deep"); nodes(options)
        local c = p.constants[k]; check(c, "constant index " .. tostring(k) .. " is out of range in prototype " .. p.id)
        if c.tag == 0 then return literal("nil") elseif c.tag == 1 then return literal(tostring(c.value))
        elseif c.tag == 2 then return literal(number(c.value)) elseif c.tag == 3 then local e = literal(quote(c.value, options)); e.string = c.value; return e
        elseif c.tag == 4 then
            local n, id = floor(c.value / 1073741824), c.value; local e
            check(n >= 1 and n <= 3, "invalid import path")
            local indices = { floor(id / 1048576) % 1024, floor(id / 1024) % 1024, id % 1024 }
            for j = 1, n do
                local key = p.constants[indices[j]]; check(key and key.tag == 3, "invalid import key")
                if j == 1 then e = { tag = "global", name = key.value }
                else e = { tag = "index", base = e, key = literal(quote(key.value, options)), field = key.value } end
            end
            return e
        elseif c.tag == 5 or c.tag == 8 then
            local entries = {}
            for _, pair in ipairs(c.entries) do entries[#entries + 1] = { key = constant(pair.key, depth), value = pair.value >= 0 and constant(pair.value, depth) or literal("0") } end
            return { tag = "table", entries = entries }
        elseif c.tag == 7 or c.tag == 11 then
            local a = {}; for j = 1, options.vector_size or 3 do a[j] = literal(number(c.value[j])) end
            return { tag = "call", fn = { tag = "raw", text = options.vector_constructor or "vector.create" }, args = a, single = true }
        elseif c.tag == 9 then
            check(options.integer_constructor, "integer constant requires options.integer_constructor; refusing double-precision rounding")
            return { tag = "call", fn = { tag = "raw", text = options.integer_constructor }, args = { literal(quote(c.value, options)) }, single = true }
        end
        fail("constant kind cannot be used as a literal: " .. c.tag)
    end
    local binops = { ADD = "+", SUB = "-", MUL = "*", DIV = "/", MOD = "%", POW = "^", AND = "and", OR = "or", IDIV = "//" }
    for _, b in ipairs(g.blocks) do
        if b.reachable and not b.exit then
            local regs = b.output
            local function read(r)
                check(r == 256 or (r >= 0 and r < p.stack), "register out of range in prototype " .. p.id .. ", pc " .. b.pc .. ": " .. r)
                return ref(regs[r] or incoming(b, r))
            end
            local function stmt(s, i) nodes(options); s.pc, s.block = i.pc, b; b.stmts[#b.stmts + 1] = s; return s end
            local function assign(r, e, i, count)
                local s = stmt({ kind = "assign", expr = e, outs = {} }, i)
                for j = 0, (count or 1) - 1 do
                    check(r + j < p.stack, "write register out of range")
                    local v = value(r + j, i.pc, b, "def"); v.stmt = s; v.position = j + 1; s.outs[j + 1], regs[r + j] = v, v
                end
                return s
            end
            local function args(first, count)
                local a = {}; for r = first, first + count - 1 do a[#a + 1] = read(r) end; return a
            end
            local function openargs(first) return { { tag = "openrange", first = first, top = read(256), block = b, regs = copy(regs), input = incoming } } end
            for _, i in ipairs(b.instructions) do
                local op, a, bb, c = i.op, i.a, i.b, i.c
                if op == "NOP" or op == "BREAK" or op == "COVERAGE" or op == "PREPVARARGS" or fast[op] then
                elseif op == "LOADNIL" then assign(a, literal("nil"), i)
                elseif op == "LOADB" then assign(a, literal(bb ~= 0 and "true" or "false"), i)
                elseif op == "LOADN" then assign(a, literal(tostring(i.d)), i)
                elseif op == "LOADK" or op == "LOADKX" then assign(a, constant(op == "LOADK" and i.d or i.aux), i)
                elseif op == "MOVE" then assign(a, read(bb), i)
                elseif op == "GETGLOBAL" or op == "SETGLOBAL" then
                    local k = p.constants[i.aux]; check(k and k.tag == 3, "invalid global key")
                    local e = { tag = "global", name = k.value }
                    if op == "GETGLOBAL" then assign(a, e, i) else stmt({ kind = "store", lhs = e, expr = read(a) }, i) end
                elseif op == "GETIMPORT" then assign(a, constant(i.d), i)
                elseif op == "GETUPVAL" or op == "SETUPVAL" then
                    check(bb < p.nups, "upvalue out of range"); local e = { tag = "upvalue", index = bb + 1 }
                    if op == "GETUPVAL" then assign(a, e, i) else stmt({ kind = "store", lhs = e, expr = read(a) }, i) end
                elseif op == "CLOSEUPVALS" then stmt({ kind = "close", reg = a }, i)
                elseif op == "GETTABLE" or op == "SETTABLE" or op == "GETTABLEN" or op == "SETTABLEN" or op == "GETTABLEKS" or op == "SETTABLEKS" or op == "GETUDATAKS" or op == "SETUDATAKS" then
                    local e = { tag = "index", base = read(bb) }
                    if op == "GETTABLE" or op == "SETTABLE" then e.key = read(c)
                    elseif op == "GETTABLEN" or op == "SETTABLEN" then e.key = literal(tostring(c + 1))
                    else local k = (op == "GETUDATAKS" or op == "SETUDATAKS") and i.aux % 65536 or i.aux
                        e.key = constant(k); e.field = p.constants[k].value; check(type(e.field) == "string", "nonstring property key") end
                    if op:sub(1, 3) == "GET" then assign(a, e, i) else stmt({ kind = "store", lhs = e, expr = read(a) }, i) end
                elseif op == "NAMECALL" or op == "NAMECALLUDATA" then
                    local k = p.constants[op == "NAMECALL" and i.aux or i.aux % 65536]; check(k and k.tag == 3, "invalid method key")
                    local receiver = read(bb)
                    local s = assign(a, { tag = "method", object = receiver, name = k.value }, i); s.method = true
                    local s2 = assign(a + 1, receiver, i); s2.methodself = s; s.self = s2
                elseif op == "CALL" or op == "CALLFB" then
                    local e = { tag = "call", fn = read(a), args = bb == 0 and openargs(a + 1) or args(a + 1, bb - 1), single = c == 2 }
                    if c == 1 then stmt({ kind = "call", expr = e }, i)
                    else
                        local s = assign(a, e, i, c == 0 and 1 or c - 1)
                        if c == 0 then s.open = true; s.outs[1].openbase = a; regs[256] = s.outs[1] end
                    end
                elseif op == "RETURN" then b.term = { kind = "return", args = bb == 0 and openargs(a) or args(a, bb - 1), pc = i.pc }
                elseif op == "GETVARARGS" then
                    check(p.vararg == 1, "GETVARARGS in a nonvariadic function")
                    if bb ~= 1 then
                        local s = assign(a, { tag = "vararg", single = bb == 2 }, i, bb == 0 and 1 or bb - 1)
                        if bb == 0 then s.open = true; s.outs[1].openbase = a; regs[256] = s.outs[1] end
                    end
                elseif op == "NEWCLOSURE" or op == "DUPCLOSURE" then
                    local e = { tag = "closure", child = i.child, captures = {}, pc = i.pc }
                    -- The closure destination is assigned BEFORE captures (recursive local functions).
                    local s = assign(a, e, i)
                    for j, capture in ipairs(i.captures) do
                        local v = capture.kind == 2 and { tag = "upvalue", index = capture.index + 1 } or read(capture.index)
                        e.captures[j] = { kind = capture.kind, expr = v, reg = capture.index, block = b, pc = i.next }
                    end
                    ctx.closures[#ctx.closures + 1] = e
                elseif op == "NEWTABLE" then assign(a, { tag = "table", entries = {} }, i)
                elseif op == "DUPTABLE" then assign(a, constant(i.d), i)
                elseif op == "SETLIST" then stmt({ kind = "setlist", target = read(a), first = i.aux, args = c == 0 and openargs(bb) or args(bb, c - 1) }, i)
                elseif binops[op] then assign(a, binary(binops[op], read(bb), read(c)), i)
                elseif binops[op:sub(1, -2)] and op:sub(-1) == "K" then assign(a, binary(binops[op:sub(1, -2)], read(bb), constant(c)), i)
                elseif op == "SUBRK" or op == "DIVRK" then assign(a, binary(op == "SUBRK" and "-" or "/", constant(bb), read(c)), i)
                elseif op == "NOT" or op == "MINUS" or op == "LENGTH" then assign(a, unary(op == "NOT" and "not" or (op == "MINUS" and "-" or "#"), read(bb)), i)
                elseif op == "CONCAT" then
                    check(bb <= c, "invalid concatenation range"); local e = read(c)
                    for r = c - 1, bb, -1 do e = binary("..", read(r), e) end; assign(a, e, i)
                elseif conditional[op] then
                    local e
                    if op == "JUMPIF" then e = read(a) elseif op == "JUMPIFNOT" then e = negate(read(a))
                    elseif op == "CMPPROTO" then fail("CMPPROTO speculative guards are not implemented (prototype " .. p.id .. ", pc " .. i.pc .. ")")
                    elseif op:sub(1, 8) == "JUMPXEQK" then
                        local k
                        if op == "JUMPXEQKNIL" then k = literal("nil") elseif op == "JUMPXEQKB" then k = literal(i.aux % 2 == 1 and "true" or "false") else k = constant(i.aux % 16777216) end
                        e = binary(i.aux >= 2147483648 and "~=" or "==", read(a), k)
                    else
                        local cmp = { JUMPIFEQ = "==", JUMPIFLE = "<=", JUMPIFLT = "<", JUMPIFNOTEQ = "~=", JUMPIFNOTLE = "<=", JUMPIFNOTLT = "<" }
                        e = binary(cmp[op], read(a), read(i.aux % 256))
                        if op == "JUMPIFNOTLE" or op == "JUMPIFNOTLT" then e = negate(e) end
                    end
                    b.term = { kind = "branch", cond = e, yes = g.map[i.target], no = g.map[i.next], pc = i.pc }
                elseif op == "FORNPREP" then
                    b.term = { kind = "nprep", initial = read(a + 2), limit = read(a), step = read(a + 1), body = g.map[i.next], after = g.map[i.target], reg = a, pc = i.pc }
                elseif op == "FORNLOOP" then
                    local s = assign(a + 2, binary("+", read(a + 2), read(a + 1)), i); s.synthetic = true
                    b.term = { kind = "nlatch", body = g.map[i.target], after = g.map[i.next], reg = a, variable = s.outs[1], pc = i.pc }
                elseif op == "FORGLOOP" then
                    local n = i.aux % 256; check(n >= 1 and a + 2 + n < p.stack, "invalid generic-for outputs")
                    local generator = { read(a), read(a + 1), read(a + 2) }
                    local s = assign(a + 3, { tag = "loopvars" }, i, n); s.synthetic = true
                    local hidden = assign(a + 2, ref(s.outs[1]), i); hidden.synthetic = true
                    b.term = { kind = "glatch", body = g.map[i.target], after = g.map[i.next], variables = s.outs, generator = generator, reg = a, pc = i.pc }
                elseif forprep[op] then b.term = { kind = "gprep", generator = { read(a), read(a + 1), read(a + 2) }, latch = g.map[i.target], reg = a, pc = i.pc }
                elseif unconditional[op] then b.term = { kind = "jump", to = g.map[i.target], pc = i.pc }
                else fail("unsupported " .. op .. " in prototype " .. p.id .. ", pc " .. i.pc) end
            end
            if not b.term then b.term = { kind = "jump", to = b.succ[1], pc = b.last.pc } end
        end
    end
    -- Connect block inputs to reaching definitions. Union only within one physical
    -- register: unlike indiscriminate SSA copy coalescing, this preserves swaps.
    local n = 1
    while n <= #ctx.values do
        local v = ctx.values[n]; n = n + 1
        if v.kind == "phi" then
            if #v.block.preds == 0 then v.kind = "undefined"
            else
                for _, pred in ipairs(v.block.preds) do local source = pred.output[v.reg] or incoming(pred, v.reg); unite(v, source) end
            end
        end
    end
    -- REF captures remain a shared cell until CLOSEUPVALS on every CFG path.
    for _, closure in ipairs(ctx.closures) do
        for _, cap in ipairs(closure.captures) do
            if cap.kind == 1 then
                local v = cap.expr.value; root(v).captured = true
                local queue, seen = { { b = cap.block, pc = cap.pc } }, {}; local q = 1
                while q <= #queue do
                    local item = queue[q]; q = q + 1; local b, stop = item.b, false; spend(options, #b.stmts + 1)
                    local key = b.id .. ":" .. item.pc
                    if not seen[key] then
                        seen[key] = true
                        for _, s in ipairs(b.stmts) do
                            if s.pc >= item.pc then
                                if s.kind == "close" and cap.reg >= s.reg then stop = true; break end
                                for _, out in ipairs(s.outs or {}) do if out.reg == cap.reg then unite(v, out) end end
                            end
                        end
                        if not stop then for _, next in ipairs(b.succ) do if not next.exit then queue[#queue + 1] = { b = next, pc = next.pc } end end end
                    end
                end
            end
        end
    end
    ctx.incoming = incoming
    ctx.resolve = function()
        while n <= #ctx.values do
            local v = ctx.values[n]; n = n + 1
            if v.kind == "phi" then
                if #v.block.preds == 0 then v.kind = "undefined" else
                    for _, pred in ipairs(v.block.preds) do unite(v, pred.output[v.reg] or incoming(pred, v.reg)) end
                end
            end
        end
    end
    return ctx
end
local function walk(e, visit, options, depth)
    if not e then return e end
    depth = (depth or 0) + 1
    check(depth <= options.max_expression_depth, "expression nesting limit exceeded")
    spend(options)
    local replacement = visit(e); if replacement then return replacement end
    local function child(x) return walk(x, visit, options, depth) end
    if e.tag == "binary" then e.a, e.b = child(e.a), child(e.b)
    elseif e.tag == "ifexpr" then e.cond, e.yes, e.no = child(e.cond), child(e.yes), child(e.no)
    elseif e.tag == "unary" then e.a = child(e.a)
    elseif e.tag == "index" then e.base, e.key = child(e.base), child(e.key)
    elseif e.tag == "call" then e.fn = child(e.fn); for j, v in ipairs(e.args) do e.args[j] = child(v) end
    elseif e.tag == "method" then e.object = child(e.object)
    elseif e.tag == "table" then for _, entry in ipairs(e.entries) do entry.key, entry.value = child(entry.key), child(entry.value) end
    elseif e.tag == "closure" then for _, cap in ipairs(e.captures) do cap.expr = child(cap.expr) end end
    return e
end
local function visitstatement(s, visit, options)
    s.expr, s.lhs, s.target = walk(s.expr, visit, options), walk(s.lhs, visit, options), walk(s.target, visit, options)
    for i, e in ipairs(s.args or {}) do s.args[i] = walk(e, visit, options) end
    s.cond = walk(s.cond, visit, options)
    s.initial, s.limit, s.step = walk(s.initial, visit, options), walk(s.limit, visit, options), walk(s.step, visit, options)
    for i, e in ipairs(s.generator or {}) do s.generator[i] = walk(e, visit, options) end
end
local function groups(ctx)
    for _, v in ipairs(ctx.values) do local r = root(v); r.defs, r.uses, r.sites = {}, 0, {} end
    for _, v in ipairs(ctx.values) do
        local r = root(v)
        if v.kind == "param" or (v.kind == "def" and v.stmt and not v.stmt.removed) then r.defs[#r.defs + 1] = v end
        if v.openbase then r.openbase = v.openbase end
    end
    for _, b in ipairs(ctx.graph.blocks) do
        if b.reachable then
            local function count(s)
                visitstatement(s, function(e)
                    if e.tag == "ref" then local v = root(e.value); v.uses = v.uses + 1; v.sites[#v.sites + 1] = s end
                end, ctx.options)
            end
            for _, s in ipairs(b.stmts) do if not s.removed and s.kind ~= "close" and not s.synthetic then count(s) end end
            if b.term then count(b.term) end
        end
    end
end
local function normalize(ctx)
    groups(ctx)
    local function expand(list)
        if not list or #list ~= 1 or list[1].tag ~= "openrange" then return list end
        local e, out = list[1], {}; local v = root(e.top.value)
        check(v.openbase ~= nil and #v.defs == 1, "ambiguous open-result tail at prototype " .. ctx.proto.id .. ", block " .. e.block.pc)
        check(e.first <= v.openbase, "open-result tail begins inside an unknown tuple")
        for r = e.first, v.openbase - 1 do out[#out + 1] = ref(e.regs[r] or e.input(e.block, r)) end
        local tail = ref(v); tail.multret = true; out[#out + 1] = tail; return out
    end
    for _, b in ipairs(ctx.graph.blocks) do
        for _, s in ipairs(b.stmts) do
            s.args = expand(s.args)
            if s.expr and s.expr.tag == "call" then s.expr.args = expand(s.expr.args) end
        end
        if b.term then b.term.args = expand(b.term.args) end
    end
    ctx.resolve(); groups(ctx)
    for _, b in ipairs(ctx.graph.blocks) do
        for _, s in ipairs(b.stmts) do
            local e = s.expr
            if e and e.tag == "call" and e.fn.tag == "ref" then
                local v = root(e.fn.value)
                if #v.defs == 1 and v.defs[1].stmt and v.defs[1].stmt.method then
                    local method = v.defs[1].stmt
                    check(#e.args >= 1, "method call has no receiver argument")
                    e.fn = method.expr; table.remove(e.args, 1); method.removed, method.self.removed = true, true
                end
            end
        end
    end
    -- All capture operands denote creation-time bindings, never delayed reads.
    for _, closure in ipairs(ctx.closures) do
        for j, cap in ipairs(closure.captures) do
            if cap.expr.tag == "ref" then
                local v = root(cap.expr.value); v.hold = true
                if cap.kind == 0 and (#v.defs > 1 or v.captured) and cap.expr.value.pc ~= closure.pc then
                    local b, position = cap.block, nil
                    for index, s in ipairs(b.stmts) do if s.pc == closure.pc and s.expr == closure then position = index; break end end
                    check(position, "missing closure creation statement")
                    local snapshot = { id = #ctx.values + 1, reg = -1, kind = "def", pc = closure.pc, block = b, hold = true }
                    local s = { kind = "assign", expr = cap.expr, outs = { snapshot }, pc = closure.pc, block = b }
                    snapshot.stmt, snapshot.position = s, 1; ctx.values[#ctx.values + 1] = snapshot
                    insert(b.stmts, position, s); cap.expr = ref(snapshot)
                end
            end
        end
    end
    groups(ctx)
end
local function dominators(graph, reverse)
    local options = graph.options
    local start = reverse and graph.exit or graph.entry
    local seen, post, stack = { [start] = true }, {}, { { b = start, index = 1 } }
    while #stack > 0 do
        spend(options)
        local item = stack[#stack]; local edges = reverse and item.b.preds or item.b.succ
        local next = edges[item.index]; item.index = item.index + 1
        if next then
            if next.reachable and not seen[next] then seen[next] = true; stack[#stack + 1] = { b = next, index = 1 } end
        else post[#post + 1] = item.b; stack[#stack] = nil end
    end
    local order, index = {}, {}; for i = #post, 1, -1 do order[#order + 1] = post[i]; index[post[i]] = #order end
    local idom = { [start] = start }
    local function intersect(a, b)
        while a ~= b do
            while index[a] > index[b] do spend(options); a = idom[a] end
            while index[b] > index[a] do spend(options); b = idom[b] end
        end
        return a
    end
    local changed, iterations = true, 0
    while changed do
        changed, iterations = false, iterations + 1; check(iterations <= #order * 2 + 10, "dominator analysis did not converge")
        for j = 2, #order do
            local b, d = order[j], nil
            for _, pred in ipairs(reverse and b.succ or b.preds) do spend(options); if idom[pred] then d = d and intersect(d, pred) or pred end end
            if idom[b] ~= d then idom[b], changed = d, true end
        end
    end
    return idom, index
end
local function structure(ctx)
    local g = ctx.graph; local idom = dominators(g, false); local postdom = dominators(g, true)
    local loops, reserved = {}, {}
    local function dominates(a, b)
        while b and b ~= a do spend(ctx.options); local prev = idom[b]; if prev == b then return false end; b = prev end
        return b == a
    end
    for _, b in ipairs(g.blocks) do
        if b.reachable then for _, header in ipairs(b.succ) do
            if dominates(header, b) then
                local loop = loops[header] or { header = header, nodes = { [header] = true }, latches = {} }; loops[header] = loop
                loop.latches[b] = true
                local queue = { b }; local q = 1
                while q <= #queue do
                    spend(ctx.options)
                    local node = queue[q]; q = q + 1
                    if not loop.nodes[node] then
                        loop.nodes[node] = true
                        for _, pred in ipairs(node.preds) do queue[#queue + 1] = pred end
                    end
                end
            end
        end end
    end
    for _, b in ipairs(g.blocks) do
        local t = b.term
        if t and t.kind == "nprep" then
            for _, latch in ipairs(g.blocks) do
                if latch.term and latch.term.kind == "nlatch" and latch.term.body == t.body and latch.term.reg == t.reg then t.latch = latch; reserved[t.body] = true; break end
            end
            check(t.latch, "numeric for has no matching latch")
        elseif t and t.kind == "gprep" then
            check(t.latch.term and t.latch.term.kind == "glatch", "generic for has no matching latch"); reserved[t.latch] = true
        end
    end
    for header, loop in pairs(loops) do
        -- Compiler-emitted loop regions are contiguous. A global postdominator
        -- can be the function exit when an inner loop has an early return;
        -- using it as the loop follow accidentally swallows the outer loop.
        local finish = header.finish
        for node in pairs(loop.nodes) do if node.finish > finish then finish = node.finish end end
        local after = g.map[finish] or g.exit
        while not after.reachable and not after.exit do after = #after.succ == 1 and after.succ[1] or g.blocks[after.id + 1] end
        loop.after, loop.continue = after, header
    end
    local generated = 0
    local function newblock() return { kind = "block", body = {} } end
    local emit
    emit = function(start, stop, loop, depth, suppress)
        depth = depth or 0
        check(depth < (ctx.options.max_depth or 200), "control-flow nesting limit exceeded in proto " .. ctx.proto.id .. " start " .. tostring(start and start.pc) .. " stop " .. tostring(stop and stop.pc) .. " loop " .. tostring(loop and loop.header.pc))
        local out, current, seen = newblock(), start, {}
        local function add(s) nodes(ctx.options); generated = generated + 1; check(generated <= (ctx.options.max_nodes or 1000000), "structured output expansion limit exceeded"); out.body[#out.body + 1] = copy(s) end
        local function action(target)
            if loop and target == loop.after then return "break" end
            if loop and target == loop.continue then return "continue" end
        end
        while current and current ~= stop and not current.exit do
            if loop and current == loop.after then add({ kind = "break" }); break end
            if loop and current == loop.continue and seen[current] then break end
            check(not seen[current], "unstructured cycle in prototype " .. ctx.proto.id .. " at pc " .. current.pc)
            seen[current] = true
            local active = loops[current]
            if active and not reserved[current] and current ~= suppress and active ~= loop then
                local node = { kind = "while", cond = literal("true"), body = emit(current, nil, active, depth + 1, current) }
                add(node); current = active.after
            else
                for _, s in ipairs(current.stmts) do if not s.removed and s.kind ~= "close" and not s.synthetic then add(s) end end
                local t = current.term
                if not t then break end
                if t.kind == "return" then add({ kind = "return", args = t.args, pc = t.pc }); current = nil
                elseif t.kind == "nprep" then
                    local desc = { header = t.body, continue = t.latch, after = t.after, nodes = loops[t.body] and loops[t.body].nodes or {} }
                    local node = { kind = "fornum", initial = t.initial, limit = t.limit, step = t.step, binding = root(t.latch.term.variable), body = emit(t.body, t.latch, desc, depth + 1) }
                    add(node); current = t.after
                elseif t.kind == "gprep" then
                    local lt = t.latch.term
                    local desc = { header = t.latch, continue = t.latch, after = lt.after, nodes = loops[t.latch] and loops[t.latch].nodes or {} }
                    local node = { kind = "forgen", generator = t.generator, bindings = {}, body = emit(lt.body, t.latch, desc, depth + 1) }
                    for j, v in ipairs(lt.variables) do node.bindings[j] = root(v) end
                    add(node); current = lt.after
                elseif t.kind == "nlatch" or t.kind == "glatch" then
                    check(loop ~= nil, "orphan loop latch at pc " .. t.pc); current = nil
                elseif t.kind == "jump" then
                    if t.to == stop then current = nil
                    else local a = action(t.to)
                        if a then if a ~= "continue" or t.to ~= suppress then add({ kind = a }) end; current = nil
                        else current = t.to end
                    end
                elseif t.kind == "branch" then
                    local ay, an = action(t.yes), action(t.no)
                    if ay or an then
                        if ay and an then
                            local yes, no = newblock(), newblock(); yes.body[1], no.body[1] = { kind = ay }, { kind = an }
                            add({ kind = "if", cond = t.cond, yes = yes, no = no }); current = nil
                        elseif ay then
                            local yes = newblock(); yes.body[1] = { kind = ay }; add({ kind = "if", cond = t.cond, yes = yes, no = newblock() }); current = t.no
                        else
                            local yes = newblock(); yes.body[1] = { kind = an }; add({ kind = "if", cond = negate(t.cond), yes = yes, no = newblock() }); current = t.yes
                        end
                    else
                        local join = postdom[current] or stop or g.exit
                        -- A containing region's boundary must not be consumed by a child region.
                        if stop and join ~= stop and stop.pc > current.pc and join.pc > stop.pc then join = stop end
                        if join == current then join = stop or g.exit end
                        local yes = t.yes == join and newblock() or emit(t.yes, join, loop, depth + 1)
                        local no = t.no == join and newblock() or emit(t.no, join, loop, depth + 1)
                        if #yes.body == 0 then add({ kind = "if", cond = negate(t.cond), yes = no, no = yes })
                        else add({ kind = "if", cond = t.cond, yes = yes, no = no }) end
                        current = join
                    end
                else fail("unsupported terminator " .. t.kind) end
            end
        end
        return out
    end
    ctx.ast = emit(g.entry, g.exit, nil, 0)
    ctx.output_nodes = generated
    return ctx.ast
end
D._normalize, D._structure = normalize, structure
local function stable(e)
    if e.tag == "literal" then return true end
    if e.tag == "ref" then local v = root(e.value); return #v.defs == 1 and not v.captured end
    return false
end
local function effect(e, options, depth)
    depth = (depth or 0) + 1; check(depth <= options.max_expression_depth, "expression nesting limit exceeded"); spend(options)
    if not e then return false end
    if e.tag == "literal" or e.tag == "ref" then return false end
    if e.tag == "unary" and e.op == "not" then return effect(e.a, options, depth) end
    if e.tag == "binary" and (e.op == "and" or e.op == "or") then return effect(e.a, options, depth) or effect(e.b, options, depth) end
    return true
end
local function evalorder(e, visit, conditionalDepth, options, depth)
    depth = (depth or 0) + 1; check(depth <= options.max_expression_depth, "expression nesting limit exceeded"); spend(options)
    if not e then return end
    local d = conditionalDepth or 0
    if e.tag == "ref" then visit(e, d, "read")
    elseif e.tag == "binary" then
        evalorder(e.a, visit, d, options, depth); evalorder(e.b, visit, d + ((e.op == "and" or e.op == "or") and 1 or 0), options, depth)
        if e.op ~= "and" and e.op ~= "or" then visit(e, d, "effect") end
    elseif e.tag == "ifexpr" then evalorder(e.cond, visit, d, options, depth); evalorder(e.yes, visit, d + 1, options, depth); evalorder(e.no, visit, d + 1, options, depth)
    elseif e.tag == "unary" then evalorder(e.a, visit, d, options, depth); if e.op ~= "not" then visit(e, d, "effect") end
    elseif e.tag == "index" then evalorder(e.base, visit, d, options, depth); evalorder(e.key, visit, d, options, depth); visit(e, d, "effect")
    elseif e.tag == "call" then evalorder(e.fn, visit, d, options, depth); for _, a in ipairs(e.args) do evalorder(a, visit, d, options, depth) end; visit(e, d, "effect")
    elseif e.tag == "method" then evalorder(e.object, visit, d, options, depth); visit(e, d, "effect")
    elseif e.tag == "table" then for _, p in ipairs(e.entries) do evalorder(p.key, visit, d, options, depth); evalorder(p.value, visit, d, options, depth) end; visit(e, d, "effect")
    elseif e.tag == "closure" then for _, c in ipairs(e.captures) do evalorder(c.expr, visit, d + 1, options, depth) end; visit(e, d, "effect")
    elseif e.tag ~= "literal" then visit(e, d, "effect") end
end
local function statementorder(s, visit, options)
    if s.lhs and s.lhs.tag == "index" then evalorder(s.lhs.base, visit, nil, options); evalorder(s.lhs.key, visit, nil, options) end
    evalorder(s.expr, visit, nil, options); evalorder(s.target, visit, nil, options)
    for _, e in ipairs(s.args or {}) do evalorder(e, visit, nil, options) end
    evalorder(s.cond, visit, nil, options); evalorder(s.initial, visit, nil, options); evalorder(s.limit, visit, nil, options); evalorder(s.step, visit, nil, options)
    for _, e in ipairs(s.generator or {}) do evalorder(e, visit, nil, options) end
end
local function optimizeIR(ctx)
    for pass = 1, 5 do
        groups(ctx); local changed = false
        for _, b in ipairs(ctx.graph.blocks) do
            for index = #b.stmts, 1, -1 do
                local s = b.stmts[index]
                if not s.removed and not s.synthetic and s.kind == "assign" and #s.outs == 1 then
                    local v = root(s.outs[1]); local e = s.expr
                    if #v.defs == 1 and not v.hold and not v.captured and not v.parameter then
                        if (e.tag == "literal" or (e.tag == "ref" and stable(e))) and not s.open then
                            local function replace(x) if x.tag == "ref" and root(x.value) == v then return e end end
                            for _, block in ipairs(ctx.graph.blocks) do
                                spend(ctx.options, #block.stmts + 1)
                                for _, st in ipairs(block.stmts) do if not st.removed then visitstatement(st, replace, ctx.options) end end
                                if block.term then visitstatement(block.term, replace, ctx.options) end
                            end
                            s.removed, changed = true, true
                        elseif v.uses == 1 then
                            local target = v.sites[1]
                            while target and target.removed and target.movedTo do target = target.movedTo end
                            if target and not target.removed and target.block == nil then
                                -- Terminators do not carry a block field.
                                for _, block in ipairs(ctx.graph.blocks) do if block.term == target then target.block = block; break end end
                            end
                            if target and not target.removed and target.block == b and target.pc > s.pc then
                                local safe = true
                                for j = index + 1, #b.stmts do
                                    local other = b.stmts[j]
                                    if other == target or other.pc >= target.pc then break end
                                    if not other.removed and not other.synthetic and other.kind ~= "close" then safe = false; break end
                                end
                                local before, found = false, false
                                statementorder(target, function(x, conditionalDepth, kind)
                                    if x.tag == "ref" and root(x.value) == v then
                                        found = true
                                        if before or (conditionalDepth > 0 and effect(e, ctx.options)) then safe = false end
                                    elseif not found and kind == "effect" then before = true end
                                end, ctx.options)
                                if e.tag == "closure" and ctx.chunk.protos[e.child + 1].debugname then safe = false end
                                if safe and found then
                                    visitstatement(target, function(x) if x.tag == "ref" and root(x.value) == v then return e end end, ctx.options)
                                    s.removed, s.movedTo, changed = true, target, true
                                end
                            end
                        elseif v.uses == 0 and not effect(e, ctx.options) then s.removed, changed = true, true end
                    end
                end
            end
        end
        if not changed then break end
    end
    groups(ctx)
end
local function simplifyGraph(ctx)
    local g = ctx.graph
    local function empty(b)
        for _, s in ipairs(b.stmts) do if not s.removed and not s.synthetic and s.kind ~= "close" then return false end end
        return true
    end
    local function forward(b)
        local seen = {}
        while b and b.term and b.term.kind == "jump" and empty(b) and b.term.to.pc > b.pc and not seen[b] do
            seen[b] = true; b = b.term.to
        end
        return b
    end
    for pass = 1, 20 do
        local changed = false
        for _, b in ipairs(g.blocks) do
            local t = b.term
            if t and t.kind == "branch" then
                t.yes, t.no = forward(t.yes), forward(t.no)
                local y, n = t.yes.term, t.no.term
                if n and n.kind == "branch" and empty(t.no) and t.no.pc > b.pc then
                    if n.yes == t.yes then t.cond, t.no = binary("or", t.cond, n.cond), n.no; changed = true
                    elseif n.no == t.yes then t.cond, t.no = binary("or", t.cond, negate(n.cond)), n.yes; changed = true end
                elseif y and y.kind == "branch" and empty(t.yes) and t.yes.pc > b.pc then
                    if y.no == t.no then t.cond, t.yes = binary("and", t.cond, y.cond), y.yes; changed = true
                    elseif y.yes == t.no then t.cond, t.yes = binary("and", t.cond, negate(y.cond)), y.no; changed = true end
                end
            end
        end
        if not changed then break end
    end
    -- Rebuild edges after decision-tree folding before dominator analysis.
    for _, b in ipairs(g.blocks) do b.succ, b.preds, b.reachable = {}, {}, nil end
    local function edge(b, to)
        if not to then return end
        for _, old in ipairs(b.succ) do if old == to then return end end
        b.succ[#b.succ + 1] = to; to.preds[#to.preds + 1] = b
    end
    for _, b in ipairs(g.blocks) do
        local t = b.term
        if t then
            if t.kind == "branch" then edge(b, t.yes); edge(b, t.no)
            elseif t.kind == "jump" then edge(b, t.to)
            elseif t.kind == "nprep" or t.kind == "nlatch" or t.kind == "glatch" then edge(b, t.body); edge(b, t.after)
            elseif t.kind == "gprep" then edge(b, t.latch)
            elseif t.kind == "return" then edge(b, g.exit) end
        else
            -- Unreachable compiler jump trampolines still identify loop follows.
            local i = b.last
            if i and i.target and unconditional[i.op] then edge(b, g.map[i.target]) end
        end
    end
    local queue, q = { g.entry }, 1; g.entry.reachable = true
    while q <= #queue do local b = queue[q]; q = q + 1; for _, n in ipairs(b.succ) do if not n.reachable then n.reachable = true; queue[#queue + 1] = n end end end
    for _, b in ipairs(g.blocks) do local preds = {}; for _, p in ipairs(b.preds) do if p.reachable then preds[#preds + 1] = p end end; b.preds = preds end
end
local function childblocks(s)
    if s.kind == "if" then return { s.yes, s.no } end
    if s.kind == "do" or s.kind == "while" or s.kind == "repeat" or s.kind == "fornum" or s.kind == "forgen" then return { s.body } end
    return {}
end
local function astwalk(block, fn, options, depth)
    depth = (depth or 0) + 1; check(depth <= options.max_depth * 2, "AST nesting limit exceeded")
    for _, s in ipairs(block.body) do spend(options); fn(s, block); for _, c in ipairs(childblocks(s)) do astwalk(c, fn, options, depth) end end
end
local function samebody(a, b)
    if #a.body ~= #b.body then return false end
    for j, s in ipairs(a.body) do
        local t = b.body[j]
        if s ~= t then
            if s.kind ~= t.kind then return false end
            if s.pc and t.pc then if s.pc ~= t.pc then return false end
            elseif s.kind == "break" or s.kind == "continue" then
            else return false end
        end
    end
    return true
end
local function assignone(block)
    if #block.body == 1 and block.body[1].kind == "assign" and #block.body[1].outs == 1 then return block.body[1] end
end
local function boolselect(cond, yes, no)
    if yes.tag == "literal" and no.tag == "literal" then
        if yes.text == "true" and no.text == "false" then return unary("not", unary("not", cond)) end
        if yes.text == "false" and no.text == "true" then return negate(cond) end
    end
    return { tag = "ifexpr", cond = cond, yes = yes, no = no }
end
local function optimizeAST(ctx)
    local function visit(block)
        for _, s in ipairs(block.body) do for _, c in ipairs(childblocks(s)) do visit(c) end end
        local out = {}
        for _, s in ipairs(block.body) do
            if s.kind == "if" then
                if #s.no.body == 0 and #s.yes.body == 1 and s.yes.body[1].kind == "if" and #s.yes.body[1].no.body == 0 then
                    local inner = s.yes.body[1]; s.cond, s.yes = binary("and", s.cond, inner.cond), inner.yes
                end
                if #s.no.body == 1 and s.no.body[1].kind == "if" then
                    local other = s.no.body[1]
                    if #other.no.body == 0 and samebody(s.yes, other.yes) then s.cond, s.no = binary("or", s.cond, other.cond), other.no end
                end
                local yes, no = assignone(s.yes), assignone(s.no)
                if ctx.options.expression_if ~= false and yes and no and root(yes.outs[1]) == root(no.outs[1]) then
                    s = { kind = "assign", outs = yes.outs, expr = boolselect(s.cond, yes.expr, no.expr), pc = s.pc }
                elseif ctx.options.expression_if ~= false and yes and #s.no.body == 0 then
                    local prev = out[#out]
                    if prev and prev.kind == "assign" and #prev.outs == 1 and root(prev.outs[1]) == root(yes.outs[1]) and prev.expr.tag == "literal" and not root(prev.outs[1]).captured and not root(prev.outs[1]).hold then
                        local used = false
                        local function readsPrevious(e) if e.tag == "ref" and root(e.value) == root(prev.outs[1]) then used = true end end
                        walk(s.cond, readsPrevious, ctx.options); walk(yes.expr, readsPrevious, ctx.options)
                        if not used then out[#out] = nil; s = { kind = "assign", outs = yes.outs, expr = boolselect(s.cond, yes.expr, prev.expr), pc = s.pc } end
                    end
                end
            elseif s.kind == "fornum" then
                local prev = out[#out]
                if prev and prev.kind == "assign" and #prev.outs == 1 and s.initial.tag == "ref" and root(s.initial.value) == root(prev.outs[1]) then
                    s.initial = prev.expr; out[#out] = nil
                end
            elseif s.kind == "forgen" then
                local prev = out[#out]
                if prev and prev.kind == "assign" and #prev.outs == #s.generator then
                    local match = true
                    for j, e in ipairs(s.generator) do if e.tag ~= "ref" or root(e.value) ~= root(prev.outs[j]) then match = false end end
                    if match then s.generator = { prev.expr }; out[#out] = nil end
                end
            elseif s.kind == "while" and s.cond.tag == "literal" and s.cond.text == "true" then
                local first = s.body.body[1]
                if first and first.kind == "if" and #first.yes.body == 1 and first.yes.body[1].kind == "break" and #first.no.body == 0 then
                    s.cond = negate(first.cond); table.remove(s.body.body, 1)
                end
                local last = s.body.body[#s.body.body]
                if s.cond.tag == "literal" and s.cond.text == "true" and last and last.kind == "if" then
                    local y = #last.yes.body == 1 and last.yes.body[1].kind
                    local n = #last.no.body == 1 and last.no.body[1].kind
                    if y == "break" and (#last.no.body == 0 or n == "continue") then
                        s.kind, s.cond = "repeat", last.cond; s.body.body[#s.body.body] = nil
                    elseif y == "continue" and n == "break" then
                        s.kind, s.cond = "repeat", negate(last.cond); s.body.body[#s.body.body] = nil
                    end
                end
                if last and last.kind == "continue" then s.body.body[#s.body.body] = nil end
            end
            if not (s.kind == "if" and #s.yes.body == 0 and #s.no.body == 0 and not effect(s.cond, ctx.options)) then out[#out + 1] = s end
            if s.kind == "return" or s.kind == "break" or s.kind == "continue" then break end
        end
        -- Reassemble consecutive writes to an unescaped, newly-created table.
        -- Never move a self-reference into its own local initializer.
        local compact, i = {}, 1
        while i <= #out do
            local s = out[i]
            if s.kind == "assign" and #s.outs == 1 and s.expr.tag == "table" then
                local target = root(s.outs[1]); local entries = {}
                for j, entry in ipairs(s.expr.entries) do entries[j] = entry end
                s.expr = { tag = "table", entries = entries }
                while i < #out do
                    local next = out[i + 1]
                    local lhs = next.lhs
                    if next.kind ~= "store" or not lhs or lhs.tag ~= "index" or lhs.base.tag ~= "ref" or root(lhs.base.value) ~= target or lhs.key.tag ~= "literal" then break end
                    local selfRead = false
                    walk(next.expr, function(e) if e.tag == "ref" and root(e.value) == target then selfRead = true end end, ctx.options)
                    if selfRead or target.captured or target.hold then break end
                    local duplicate
                    spend(ctx.options, #entries)
                    for j, entry in ipairs(entries) do
                        if entry.key and entry.key.tag == "literal" and entry.key.text == lhs.key.text then duplicate = j; break end
                    end
                    if duplicate then
                        if effect(entries[duplicate].value, ctx.options) then break end
                        table.remove(entries, duplicate)
                    end
                    entries[#entries + 1] = { key = lhs.key, value = next.expr }
                    i = i + 1
                end
            end
            compact[#compact + 1] = s; i = i + 1
        end
        block.body = compact
    end
    for _ = 1, 3 do visit(ctx.ast) end
end
-- Names are evidence, not descriptions of the value stored in a register.
-- Associate debug-local intervals with reaching definitions before optimization;
-- do not guess from adjacent instructions, constants, fields or callee names.
local function recoverNames(ctx)
    local function note(v, name)
        if v and identifier(name) then
            v.recoveredNames = v.recoveredNames or {}; v.recoveredNames[name] = true
        end
    end
    local byreg = {}
    for _, v in ipairs(ctx.values) do
        if v.kind == "def" or v.kind == "param" then
            byreg[v.reg] = byreg[v.reg] or {}; insert(byreg[v.reg], v)
        end
    end
    for _, info in ipairs(ctx.proto.locals) do
        if identifier(info.name) and info.first < info.last and ctx.proto.bypc[info.first] then
            local block
            for _, b in ipairs(ctx.graph.blocks) do
                if b.pc <= info.first and info.first < b.finish then block = b; break end
            end
            if block and block.reachable then
                local reaching, latest
                for _, v in ipairs(byreg[info.reg] or {}) do
                    if v.block == block and v.pc < info.first and (not latest or v.pc > latest) then
                        reaching, latest = v, v.pc
                    end
                    if v.pc >= info.first and v.pc < info.last then note(v, info.name) end
                end
                -- The interval starts after initialization. Resolve the register
                -- at that exact PC, including multi-instruction/multiple locals.
                reaching = reaching or block.input[info.reg] or ctx.incoming(block, info.reg)
                note(reaching, info.name)
            end
        end
    end
    ctx.resolve()
    for _, closure in ipairs(ctx.closures) do
        local child = ctx.chunk.protos[closure.child + 1]
        for j, cap in ipairs(closure.captures) do
            if cap.expr.tag == "ref" then note(cap.expr.value, child.upnames[j]) end
        end
    end
end
local function anonymousName(state)
    local name
    repeat state.nextLocal = state.nextLocal + 1; name = "local_" .. state.nextLocal
    until not state.reserved[name]
    state.reserved[name] = true
    return name
end
local function allocateNames(ctx, upnames)
    ctx.upnames = upnames or {}
    local used, active, evidence, ordered = {}, {}, {}, {}
    for name in pairs(ctx.options._state.globals) do used[name] = true end
    for _, name in ipairs(ctx.upnames) do used[name] = true end
    local function activate(v) if v then active[root(v)] = true end end
    for _, v in ipairs(ctx.params) do activate(v) end
    astwalk(ctx.ast, function(s)
        visitstatement(s, function(e) if e.tag == "ref" then activate(e.value) end end, ctx.options)
        for _, v in ipairs(s.outs or {}) do activate(v) end
        activate(s.binding); for _, v in ipairs(s.bindings or {}) do activate(v) end
    end, ctx.options)
    for _, v in ipairs(ctx.values) do
        local r = root(v)
        if active[r] and not evidence[r] then evidence[r] = {}; ordered[#ordered + 1] = r end
        if active[r] then
            for name in pairs(v.recoveredNames or {}) do evidence[r][name] = true end
        end
    end
    for _, r in ipairs(ordered) do
        local recovered, count = nil, 0
        for name in pairs(evidence[r]) do recovered, count = name, count + 1 end
        -- Preserve exact spelling/case only when unambiguous and scope-safe.
        -- Conflicting, invalid or unavailable names get local_X, never suffixes
        -- such as player2, lowercased names or semantic guesses.
        if count == 1 and not used[recovered] then r.name = recovered
        else r.name = anonymousName(ctx.options._state) end
        used[r.name] = true
    end
end
local function planLocals(ctx)
    local scopes, bindings = {}, {}
    local function lca(a, b)
        if not a then return b end
        while a.depth > b.depth do a = a.parent end
        while b.depth > a.depth do b = b.parent end
        while a ~= b do a, b = a.parent, b.parent end
        return a
    end
    local function use(v, block) v = root(v); if not v.parameter then scopes[v] = lca(scopes[v], block) end end
    local function traverse(block, parent, owner)
        block.parent, block.owner, block.depth, block.declarations = parent, owner, parent and parent.depth + 1 or 0, {}
        for _, s in ipairs(block.body) do
            local repeatCondition = s.kind == "repeat" and s.cond
            if repeatCondition then s.cond = nil end
            visitstatement(s, function(e) if e.tag == "ref" then use(e.value, block) end end, ctx.options)
            if repeatCondition then s.cond = repeatCondition end
            for _, v in ipairs(s.outs or {}) do use(v, block) end
            if s.kind == "fornum" then bindings[s.binding] = s.body
            elseif s.kind == "forgen" then for _, v in ipairs(s.bindings) do bindings[v] = s.body end end
            for _, child in ipairs(childblocks(s)) do traverse(child, block, s) end
            if repeatCondition then walk(repeatCondition, function(e) if e.tag == "ref" then use(e.value, s.body) end end, ctx.options) end
        end
    end
    -- SSA names have short logical lifetimes, but hundreds of sequential
    -- declarations in one lexical scope exceed the compiler's local limit.
    -- Split oversized regions into do/end scopes. The LCA calculation hoists
    -- only bindings genuinely shared across both regions; captures stay lexical.
    for iteration = 1, #ctx.values + 1 do
        scopes, bindings = {}, {}
        traverse(ctx.ast)
        for v, block in pairs(scopes) do
            local bound = bindings[v]
            local inBinding = bound and block.depth >= bound.depth and lca(block, bound) == bound
            if not inBinding then block.declarations[#block.declarations + 1] = v end
        end
        local candidate
        local function inspect(block, inherited)
            local active = inherited + #block.declarations
            if active > (ctx.options.max_scope_locals or 180) and #block.declarations > 1 and #block.body > 1 then
                candidate = candidate or block
            end
            for _, s in ipairs(block.body) do
                local extra = s.kind == "fornum" and 4 or (s.kind == "forgen" and #s.bindings + 3 or 0)
                for _, child in ipairs(childblocks(s)) do inspect(child, active + extra) end
            end
        end
        inspect(ctx.ast, #ctx.params)
        if not candidate then break end
        check(iteration <= #ctx.values, "cannot safely reduce lexical local count")
        local middle = floor(#candidate.body / 2); local left, right = {}, {}
        for i, st in ipairs(candidate.body) do
            local side = i <= middle and left or right; side[#side + 1] = st
        end
        candidate.body = {
            { kind = "do", body = { kind = "block", body = left } },
            { kind = "do", body = { kind = "block", body = right } }
        }
    end
    local function place(block)
        table.sort(block.declarations, function(a, b) return a.id < b.id end)
        local pending = {}; for _, v in ipairs(block.declarations) do pending[v] = true end
        block.prefix = {}
        -- First-use placement keeps declarations near their initializer, while
        -- declarations shared by branches stay in their least common scope.
        for _, s in ipairs(block.body) do
            s.predeclare, s.localouts = {}, nil
            local needed = {}
            local function collect(node)
                visitstatement(node, function(e) if e.tag == "ref" then local v = root(e.value); if pending[v] then needed[v] = true end end end, ctx.options)
                for _, v in ipairs(node.outs or {}) do v = root(v); if pending[v] then needed[v] = true end end
            end
            collect(s)
            for _, child in ipairs(childblocks(s)) do astwalk(child, collect, ctx.options) end
            local allNew = s.kind == "assign" and #s.outs > 0
            if allNew then
                for _, v in ipairs(s.outs) do if not pending[root(v)] then allNew = false end end
                -- A recursive closure must see the new local, not a global.
                local selfRead = false
                walk(s.expr, function(e) if e.tag == "ref" then for _, v in ipairs(s.outs) do if root(e.value) == root(v) then selfRead = true end end end end, ctx.options)
                if selfRead and s.expr.tag ~= "closure" then allNew = false end
                if selfRead and s.expr.tag == "closure" and #s.outs ~= 1 then allNew = false end
            end
            if allNew then s.localouts = true; for _, v in ipairs(s.outs) do v = root(v); pending[v], needed[v] = nil, nil end end
            for v in pairs(needed) do s.predeclare[#s.predeclare + 1] = v; pending[v] = nil end
            table.sort(s.predeclare, function(a, b) return a.id < b.id end)
            for _, child in ipairs(childblocks(s)) do place(child) end
        end
        for v in pairs(pending) do block.prefix[#block.prefix + 1] = v end
        table.sort(block.prefix, function(a, b) return a.id < b.id end)
    end
    place(ctx.ast)
end
local buildFunction, renderBlock, expression
local precedence = { ["or"] = 1, ["and"] = 2, ["=="] = 3, ["~="] = 3, ["<"] = 3, [">"] = 3, ["<="] = 3, [">="] = 3, [".."] = 4, ["+"] = 5, ["-"] = 5, ["*"] = 6, ["/"] = 6, ["//"] = 6, ["%"] = 6, ["^"] = 8 }
expression = function(e, ctx, level, parent, tail, depth)
    depth = (depth or 0) + 1
    check(depth <= ctx.options.max_expression_depth and level <= ctx.options.max_depth * 2, "source nesting limit exceeded")
    spend(ctx.options)
    check(e, "missing expression")
    local function concat(parts, sep) return join(ctx.options, parts, sep) end
    parent = parent or 0; local text, prec = nil, 10
    local function render(x, p, t) return expression(x, ctx, level, p or 0, t, depth) end
    local function prefix(x)
        if x.tag == "literal" or x.tag == "table" or x.tag == "closure" or x.tag == "ifexpr" then return concat({ "(", render(x), ")" }) end
        return render(x, 9)
    end
    if e.tag == "literal" or e.tag == "raw" then text = e.text
    elseif e.tag == "ref" then text = root(e.value).name
    elseif e.tag == "global" then text = identifier(e.name) and e.name or ("getfenv()[" .. quote(e.name, ctx.options) .. "]")
    elseif e.tag == "upvalue" then text = ctx.upnames[e.index]; check(text, "unbound upvalue " .. e.index)
    elseif e.tag == "index" then text = prefix(e.base) .. (identifier(e.field) and ("." .. e.field) or ("[" .. render(e.key) .. "]")); prec = 9
    elseif e.tag == "binary" then
        prec = precedence[e.op]; local right = e.op == "^" or e.op == ".."
        text = concat({ render(e.a, prec + (right and 1 or 0)), " ", e.op, " ", render(e.b, prec + (right and 0 or 1)) })
    elseif e.tag == "unary" then
        prec = 7; local s = render(e.a, prec)
        if e.op == "-" and s:sub(1, 1) == "-" then s = "(" .. s .. ")" end
        text = e.op .. (e.op == "not" and " " or "") .. s
    elseif e.tag == "ifexpr" then
        prec = 0; text = "if " .. render(e.cond) .. " then " .. render(e.yes) .. " else " .. render(e.no)
    elseif e.tag == "call" then
        local args = {}; for j, v in ipairs(e.args) do args[j] = render(v, 0, j == #e.args) end
        if e.fn.tag == "method" then
            check(identifier(e.fn.name), "nonidentifier NAMECALL cannot be emitted without changing __namecall semantics")
            text = prefix(e.fn.object) .. ":" .. e.fn.name .. "(" .. concat(args, ", ") .. ")"
        else text = prefix(e.fn) .. "(" .. concat(args, ", ") .. ")" end
        prec = 9; if tail and e.single then text, prec = "(" .. text .. ")", 10 end
    elseif e.tag == "vararg" then text = tail and e.single and "(...)" or "..."
    elseif e.tag == "table" then
        local parts = {}
        for j, pair in ipairs(e.entries) do
            local key = pair.key and ((pair.key.string and identifier(pair.key.string)) and (pair.key.string .. " = ") or ("[" .. render(pair.key) .. "] = ")) or ""
            parts[j] = key .. render(pair.value, 0, pair.key == nil and j == #e.entries)
        end
        text = #parts == 0 and "{}" or ("{ " .. concat(parts, ", ") .. " }")
    elseif e.tag == "closure" then
        local names = {}
        for j, cap in ipairs(e.captures) do names[j] = render(cap.expr); check(identifier(names[j]), "capture is not a lexical binding") end
        local child = buildFunction(ctx.chunk, ctx.chunk.protos[e.child + 1], ctx.options, names, (ctx.depth or 0) + 1)
        local params = {}; for j, v in ipairs(child.params) do params[j] = root(v).name end
        if child.proto.vararg == 1 then params[#params + 1] = "..." end
        local body = renderBlock(child.ast, child, level + 1)
        text = "function(" .. concat(params, ", ") .. ")\n" .. body .. string.rep(ctx.indent, level) .. "end"
    else fail("cannot print expression " .. tostring(e.tag)) end
    check(#text <= ctx.options.max_output_bytes, "expression exceeds output limit")
    if prec < parent then return concat({ "(", text, ")" }) end
    return text
end
renderBlock = function(block, ctx, level)
    check(level <= ctx.options.max_depth * 2, "source nesting limit exceeded")
    local out, bytes = {}, 0; local ind = string.rep(ctx.indent, level)
    local function append(s)
        bytes = bytes + #s; check(bytes <= ctx.options.max_output_bytes, "output exceeds size limit")
        out[#out + 1] = s
    end
    local function line(s) spend(ctx.options); append(join(ctx.options, { ind, s, "\n" })) end
    local function concat(parts, sep) return join(ctx.options, parts, sep) end
    local function expr(e, tail) return expression(e, ctx, level, 0, tail) end
    local function names(values) local a = {}; for j, v in ipairs(values) do a[j] = root(v).name end; return concat(a, ", ") end
    local function declarations(values)
        for i = 1, #values, 20 do local a = {}; for j = i, math.min(i + 19, #values) do a[#a + 1] = values[j] end; line("local " .. names(a)) end
    end
    declarations(block.prefix or {})
    for index, s in ipairs(block.body) do
        declarations(s.predeclare or {})
        if s.kind == "assign" then
            local rhs = expr(s.expr, true)
            if s.localouts and #s.outs == 1 and s.expr.tag == "closure" then line("local function " .. root(s.outs[1]).name .. rhs:sub(9))
            else line((s.localouts and "local " or "") .. names(s.outs) .. " = " .. rhs) end
        elseif s.kind == "store" then line(expr(s.lhs) .. " = " .. expr(s.expr, true))
        elseif s.kind == "call" then line(expr(s.expr))
        elseif s.kind == "return" then
            if not (index == #block.body and block == ctx.ast and #s.args == 0) then
                local a = {}; for j, e in ipairs(s.args) do a[j] = expr(e, j == #s.args) end
                line(#a > 0 and "return " .. concat(a, ", ") or "return")
            end
        elseif s.kind == "break" or s.kind == "continue" then line(s.kind)
        elseif s.kind == "if" then
            local current, initial = s, true
            while true do
                line((initial and "if " or "elseif ") .. expr(current.cond) .. " then")
                append(renderBlock(current.yes, ctx, level + 1))
                if #current.no.body == 1 and current.no.body[1].kind == "if" and #(current.no.body[1].predeclare or {}) == 0 then current, initial = current.no.body[1], false
                else
                    if #current.no.body > 0 then line("else"); append(renderBlock(current.no, ctx, level + 1)) end
                    line("end"); break
                end
            end
        elseif s.kind == "do" then line("do"); append(renderBlock(s.body, ctx, level + 1)); line("end")
        elseif s.kind == "while" then line("while " .. expr(s.cond) .. " do"); append(renderBlock(s.body, ctx, level + 1)); line("end")
        elseif s.kind == "repeat" then line("repeat"); append(renderBlock(s.body, ctx, level + 1)); line("until " .. expr(s.cond))
        elseif s.kind == "fornum" then
            local step = s.step.tag == "literal" and s.step.text == "1" and "" or (", " .. expr(s.step))
            line("for " .. s.binding.name .. " = " .. expr(s.initial) .. ", " .. expr(s.limit) .. step .. " do")
            append(renderBlock(s.body, ctx, level + 1)); line("end")
        elseif s.kind == "forgen" then
            local a = {}; for j, e in ipairs(s.generator) do a[j] = expr(e, j == #s.generator) end
            line("for " .. names(s.bindings) .. " in " .. concat(a, ", ") .. " do"); append(renderBlock(s.body, ctx, level + 1)); line("end")
        elseif s.kind == "setlist" then
            local state = ctx.options._state
            if not state.setlist then
                state.setlist = {}; for j = 1, 4 do state.setlist[j] = anonymousName(state) end
            end
            local a = { expr(s.target), tostring(s.first) }; for j, e in ipairs(s.args) do a[#a + 1] = expr(e, j == #s.args) end
            line(state.setlist[1] .. "(" .. concat(a, ", ") .. ")")
        else fail("cannot print statement " .. s.kind) end
    end
    return concat(out)
end
buildFunction = function(chunk, p, options, upnames, depth)
    check(depth <= (options.max_depth or 200), "closure nesting limit exceeded")
    options._state.functions = options._state.functions + 1
    check(options._state.functions <= (options.max_function_expansions or 100000), "closure expansion limit exceeded")
    local ctx = ir(chunk, p, options); ctx.depth, ctx.indent = depth, options.indent or "    "
    recoverNames(ctx); normalize(ctx); optimizeIR(ctx); simplifyGraph(ctx); structure(ctx); optimizeAST(ctx)
    allocateNames(ctx, upnames); planLocals(ctx)
    return ctx
end
function D.decompile(data, options)
    options = configure(options); options._state = { functions = 0, nextLocal = 0, reserved = {}, globals = {} }
    local chunk = decodeChunk(parse(data, options), options)
    local state = options._state
    local function reserveGlobal(name)
        if identifier(name) then state.globals[name], state.reserved[name] = true, true end
    end
    local function reserveExpression(text)
        local base = text:gsub("%.[A-Za-z_][A-Za-z0-9_]*", "")
        if identifier(base) then reserveGlobal(base)
        else for name in text:gmatch("[A-Za-z_][A-Za-z0-9_]*") do reserveGlobal(name) end end
    end
    -- A local in a parent function must not capture an actual global referenced
    -- only in a nested function. Reserve real names across the entire chunk.
    for _, p in ipairs(chunk.protos) do
        for _, i in ipairs(p.instructions) do
            if i.op == "GETGLOBAL" or i.op == "SETGLOBAL" then
                local k = p.constants[i.aux]
                if k and k.tag == 3 then
                    if identifier(k.value) then reserveGlobal(k.value) else reserveGlobal("getfenv") end
                end
            elseif i.op == "SETLIST" then reserveGlobal("select")
            end
        end
        for _, k in pairs(p.constants) do
            if k.tag == 4 then
                local first = p.constants[floor(k.value / 1048576) % 1024]
                if first and first.tag == 3 then
                    if identifier(first.value) then reserveGlobal(first.value) else reserveGlobal("getfenv") end
                end
            elseif k.tag == 7 or k.tag == 11 then reserveExpression(options.vector_constructor or "vector.create")
            elseif k.tag == 9 and options.integer_constructor then reserveExpression(options.integer_constructor)
            end
        end
        for _, info in ipairs(p.locals) do if identifier(info.name) then state.reserved[info.name] = true end end
        for _, name in ipairs(p.upnames) do if identifier(name) then state.reserved[name] = true end end
    end
    local main = chunk.protos[chunk.main + 1]; local upnames = options.upvalue_names or {}
    check(#upnames == main.nups, "root function has external upvalues; provide options.upvalue_names")
    for _, name in ipairs(upnames) do check(identifier(name), "invalid external upvalue name"); state.reserved[name] = true end
    local ctx = buildFunction(chunk, main, options, upnames, 0)
    local source = renderBlock(ctx.ast, ctx, 0)
    if state.setlist then
        local fn, target, first, index = state.setlist[1], state.setlist[2], state.setlist[3], state.setlist[4]
        source = "local function " .. fn .. "(" .. target .. ", " .. first .. ", ...)\n    for " .. index .. " = 1, select(\"#\", ...) do\n        " .. target .. "[" .. first .. " + " .. index .. " - 1] = select(" .. index .. ", ...)\n    end\nend\n\n" .. source
    end
    if options.header ~= false then source = "-- This file was generated by luaunveil.com ;\n\n" .. source end
    check(#source <= (options.max_output_bytes or 67108864), "output exceeds size limit")
    return source, { version = chunk.version, type_version = chunk.types, prototypes = #chunk.protos, instruction_words = chunk.instruction_words, opcode_multiplier = chunk.opcode_multiplier, trailing_bytes = #chunk.trailing, warnings = chunk.warnings, decompiler_version = D.version, work_units = options._budget.work, intermediate_nodes = options._budget.nodes }
end


-- Luau instance adapter. Bytecode extraction is supplied by the host, while
-- decompilation is performed entirely by the common core above.
D.runtime = "Luau"

local function sharedEnvironment()
    if type(getgenv) ~= "function" then return {} end
    local ok, env = pcall(getgenv)
    check(ok and type(env) == "table", "getgenv must return an environment table")
    return env
end
local function hostCall(fn, label, ...)
    check(type(fn) == "function", "host does not provide " .. label)
    local ok, result = pcall(fn, ...)
    check(ok, label .. " failed: " .. tostring(result))
    return result
end
local function isInstance(value)
    return type(typeof) == "function" and typeof(value) == "Instance"
end
local function pathParts(path)
    check(type(path) == "string" and not path:find("[%z\1-\31\127]"), "input must be an instance path without control characters")
    local parts, pos, size = {}, 1, #path
    local function space()
        while pos <= size and path:sub(pos, pos):match("%s") do pos = pos + 1 end
    end
    local function name()
        space()
        local first, last = path:find("[A-Za-z_][A-Za-z0-9_]*", pos)
        check(first == pos, "expected instance name at path position " .. pos)
        parts[#parts + 1] = path:sub(first, last); pos = last + 1
    end
    name()
    while true do
        space(); if pos > size then break end
        local symbol = path:sub(pos, pos); pos = pos + 1
        if symbol == "." then name()
        elseif symbol == "[" then
            space(); local delimiter = path:sub(pos, pos); pos = pos + 1
            check(delimiter == '"' or delimiter == "'", "bracket paths require a quoted child name")
            local chars, closed = {}, false
            while pos <= size do
                local c = path:sub(pos, pos); pos = pos + 1
                if c == delimiter then closed = true; break end
                if c == "\\" then
                    c = path:sub(pos, pos); pos = pos + 1
                    check(c == "\\" or c == '"' or c == "'", "unsupported escape in instance path")
                end
                chars[#chars + 1] = c
            end
            check(closed, "unterminated quoted child name")
            space(); check(path:sub(pos, pos) == "]", "expected closing path bracket"); pos = pos + 1
            parts[#parts + 1] = concat(chars)
        else fail("instance paths accept only names, dots and quoted brackets; not executable expressions") end
    end
    return parts
end
function D.resolve(target)
    if isInstance(target) then return target end
    local parts = pathParts(target)
    check(isInstance(game), "host does not provide Roblox game")
    local current, first = game, 1
    if parts[1] == "game" or parts[1] == "Game" then first = 2 end
    for j = first, #parts do
        local name = parts[j]
        if current == game and (name == "workspace" or name == "Workspace") then
            current = hostCall(game.GetService, "GetService", game, "Workspace")
        else
            current = hostCall(current.FindFirstChild, "FindFirstChild", current, name)
        end
        check(isInstance(current), "instance path component not found: " .. quote(name))
    end
    return current
end
local function scriptName(target)
    local name = target.Name
    check(type(name) == "string", "script has no string Name")
    -- Keep actual names, including Unicode; replace filename separators and
    -- device-unsafe characters only. Never use the full instance path as a file.
    name = name:gsub('[%z\1-\31\127/\\:<>"|?*]', "_"):gsub("[. ]+$", "_")
    if name == "" then name = "Script" end
    local base = name:match("^([^.]*)"):lower()
    if base == "con" or base == "prn" or base == "aux" or base == "nul" or base:match("^com[1-9]$") or base:match("^lpt[1-9]$") then name = "_" .. name end
    return name
end
local pendingOutputs = {}
local function reserveOutput(target, exists)
    check(type(os) == "table" and type(os.date) == "function", "file mode requires os.date")
    local stamp = hostCall(os.date, "os.date", "%Y%m%d%S")
    check(type(stamp) == "string" and stamp:match("^%d%d%d%d%d%d%d%d%d%d$"), "os.date returned an invalid yyyymmddss timestamp")
    local prefix, number = scriptName(target) .. stamp, 1
    while true do
        local path = prefix .. string.format("%.0f", number) .. ".lua"
        if not pendingOutputs[path] then
            pendingOutputs[path] = true
            local ok, present = pcall(exists, path)
            if not ok then pendingOutputs[path] = nil; error(present, 0) end
            if not present then return path end
            pendingOutputs[path] = nil
        end
        local nextNumber = number + 1
        check(nextNumber > number, "host number representation exhausted filename suffixes")
        number = nextNumber
    end
end
function D.run(config)
    check(type(config) == "table", "run expects a configuration table")
    local mode = config.saveMode
    if mode == nil then mode = "cl" end
    check(mode == "cl" or mode == "file", "saveMode must be 'cl' or 'file'")
    check(config.quiet == nil or type(config.quiet) == "boolean", "quiet must be boolean")
    check(config.output == nil and config.overwrite == nil, "file names are generated automatically; output/overwrite are no longer supported")
    local options, env = configure(config.options), sharedEnvironment()
    if options.vector_constructor == nil and type(Vector3) == "table" and type(Vector3.new) == "function" then options.vector_constructor = "Vector3.new" end
    -- getscriptbytecode is a host extension, not part of the provided Synapse
    -- document or standard Luau. Never fall back to the host's decompile().
    local extract = getscriptbytecode or rawget(env, "getscriptbytecode")
    local read = readfile or rawget(env, "readfile")
    local write = writefile or rawget(env, "writefile")
    local isFile = isfile or rawget(env, "isfile")
    local clipboard = setclipboard or rawget(env, "setclipboard")
    check(type(extract) == "function", "host does not provide getscriptbytecode; an instance bytecode extractor is required")
    if mode == "cl" then check(type(clipboard) == "function", "host does not provide setclipboard")
    else check(type(write) == "function" and type(read) == "function" and type(isFile) == "function", "file mode requires writefile, readfile and isfile") end
    local target = D.resolve(config.input)
    check(hostCall(target.IsA, "IsA", target, "LocalScript") or hostCall(target.IsA, "IsA", target, "ModuleScript") or hostCall(target.IsA, "IsA", target, "Script"), "input must resolve to a script instance")
    local bytes = hostCall(extract, "getscriptbytecode", target)
    check(type(bytes) == "string" and #bytes > 0, "getscriptbytecode returned no bytecode")
    local source, info = D.decompile(bytes, options)
    if mode == "cl" then
        check(hostCall(clipboard, "setclipboard", source) ~= false, "setclipboard reported failure"); info.saved_to = "clipboard"
    else
        local function exists(path)
            local result = hostCall(isFile, "isfile", path)
            check(type(result) == "boolean", "isfile must return a boolean")
            return result
        end
        -- No rename/O_EXCL is available in the documented host interface. Use a
        -- caller-controlled workspace; checking isfile cannot close an external race.
        local outputPath = reserveOutput(target, exists)
        local ok, err = pcall(function()
            check(not exists(outputPath), "output appeared before write; refusing overwrite")
            check(hostCall(write, "writefile", outputPath, source) ~= false, "writefile reported failure")
            check(hostCall(read, "readfile", outputPath) == source, "output verification failed")
        end)
        pendingOutputs[outputPath] = nil
        check(ok, tostring(err) .. "; inspect the new destination for a partial output")
        info.saved_to = outputPath
    end
    if not config.quiet then
        local notify = type(warn) == "function" and warn or print
        if type(notify) == "function" then
            notify("luau-decompiler: " .. (mode == "cl" and "copied to clipboard" or ("saved to " .. quote(info.saved_to))))
            for _, warning in ipairs(info.warnings) do notify("luau-decompiler: " .. warning) end
        end
    end
    return source, info
end

local entryMode = ...
if entryMode ~= "module" then
    local env = sharedEnvironment()
    local function setting(value, name)
        if value ~= nil then return value end
        return rawget(env, name)
    end
    local configuredInput = setting(input, "input")
    if configuredInput ~= nil then
        local _, info = D.run({ input = configuredInput, saveMode = setting(saveMode, "saveMode"), options = setting(decompilerOptions, "decompilerOptions") })
        D.lastInfo = info
    end
end
return D
