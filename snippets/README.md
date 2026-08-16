# Snippets Guide

This directory contains custom snippets in **SnipMate format**, loaded by LuaSnip.
For dynamic snippets that need programmatic logic, use **Lua snippets** in `lua/snippets/`.

## Table of Contents

- [Directory Layout](#directory-layout)
- [SnipMate Format](#snipmate-format)
  - [Basic Structure](#basic-structure)
  - [Tabstops and Placeholders](#tabstops-and-placeholders)
  - [Mirroring](#mirroring)
  - [Visual Placeholder](#visual-placeholder)
  - [Backtick Evaluation](#backtick-evaluation)
  - [Escaping](#escaping)
- [Lua Snippet Format](#lua-snippet-format)
  - [File Structure](#file-structure)
  - [snippet (s)](#snippet-s)
  - [text_node (t)](#text_node-t)
  - [insert_node (i)](#insert_node-i)
  - [function_node (f)](#function_node-f)
  - [choice_node (c)](#choice_node-c)
  - [dynamic_node (d)](#dynamic_node-d)
  - [snippet_node (sn)](#snippet_node-sn)
  - [Postfix Snippets](#postfix-snippets)
  - [Real-World Example](#real-world-example)
- [Filetype Resolution](#filetype-resolution)
- [When to Use Which Format](#when-to-use-which-format)
- [Testing](#testing)
- [Keybindings](#keybindings)

---

## Directory Layout

```
~/.config/nvim/
├── snippets/              # SnipMate format (static snippets)
│   ├── {filetype}/
│   │   └── {name}.snippets
│   └── README.md
└── lua/snippets/          # Lua format (dynamic snippets)
    ├── all.lua            # all filetypes
    └── sh.lua             # shell-specific
```

LuaSnip determines the filetype from the directory name (e.g., `snippets/sh/*.snippets` → filetype `sh`).

---

## SnipMate Format

### Basic Structure

```snippets
# Comments start with #

snippet trigger Description text here
	body line 1 (must be tab-indented)
	body line 2
	body line 3

snippet anotherTrigger Another snippet
	single line body
```

Rules:
- The `snippet` keyword starts a declaration, followed by trigger and optional description
- **Body lines must be indented with a real tab character**
- A snippet ends at the next unindented line (blank line or next `snippet` declaration)
- Blank lines **within** a body must also have a tab prefix to avoid terminating the snippet
- Comments (`#`) are only valid outside snippet bodies

### Tabstops and Placeholders

```snippets
snippet greet Greeting with name
	Hello, ${1:World}!
	Welcome to ${2:the program}.
	$0
```

| Syntax | Meaning |
|--------|---------|
| `$1`, `$2`, ... | Tabstops — press `<Tab>` to jump between them (in order) |
| `${1:default}` | Tabstop with default text (editable placeholder) |
| `$0` | Final cursor position (always the last stop) |
| `${1:nested ${2:text}}` | Nested placeholders |

### Mirroring

Use the same tabstop number to mirror text across multiple locations:

```snippets
snippet class Class definition
	class ${1:ClassName}:
	    """${2:Docstring for $1}"""
	    def __init__(self):
	        pass
```

When you type in `$1`, all other `$1` references update in real-time.

### Visual Placeholder

`${VISUAL}` expands to the text that was visually selected before triggering the snippet:

```snippets
snippet wrap Wrap selection in tags
	<${1:div}>
	    ${VISUAL}
	</$1>
```

Usage: Select text → press trigger key → type `wrap` → expands with selection inside.

### Backtick Evaluation

Backtick pairs execute VimL and insert the result:

```snippets
snippet date Insert current date
	`strftime("%Y-%m-%d")`

snippet file Current filename
	`expand("%:t")`
```

### Escaping

| Character | Escape | When needed |
|-----------|--------|-------------|
| `}` | `\}` | Inside `${...}` placeholders to include literal `}` |
| `$` | `\$` | Literal dollar sign (avoid triggering tabstop) |
| `` ` `` | `` \` `` | Literal backtick (avoid triggering VimL eval) |
| `\` | `\\` | Literal backslash |

Note: `{` does NOT need escaping — it has no special meaning outside `${`.

---

## Lua Snippet Format

For snippets that need runtime logic — computed text, conditional content, dynamic
docstrings — use Lua snippets in `lua/snippets/{filetype}.lua`.

### File Structure

Each file returns a table of snippet objects:

```lua
local ls = require("luasnip")
local s = ls.snippet        -- snippet constructor
local t = ls.text_node      -- static text
local i = ls.insert_node    -- editable tabstop
local f = ls.function_node  -- computed text from other nodes
local c = ls.choice_node    -- cycle between alternatives
local d = ls.dynamic_node   -- runtime-generated snippet structure
local sn = ls.snippet_node  -- nested snippet (used inside dynamic_node)

return {
  s({ trig = "trigger", name = "Name", desc = "Description" }, {
    -- nodes go here
  }),
}
```

---

### snippet (s)

The top-level container that defines a trigger and holds a list of nodes.

```lua
s({ trig = "fn", name = "Function", desc = "Insert a function" }, { ... })

-- Short form (trigger-only, no metadata):
s("fn", { ... })
```

**Parameters:**

| Field | Type | Description |
|-------|------|-------------|
| `trig` | string | The text typed to trigger expansion |
| `name` | string | Short name shown in completion menu |
| `desc` | string | Longer description for documentation |
| `wordTrig` | bool | Only trigger at word boundary (default: `true`) |
| `regTrig` | bool | Treat `trig` as a Lua pattern (default: `false`) |

The second argument is a table of **nodes** — the snippet body. Nodes are rendered
in order, left to right, top to bottom.

---

### text_node (t)

Inserts **static, non-editable text**. This is the most basic node — it just outputs
fixed content that the user cannot modify after expansion.

```lua
-- Single line:
t("Hello, World!")

-- Multi-line (each table entry = one line):
t({ "line 1", "line 2", "line 3" })

-- Empty string entry = newline:
t({ "first line", "", "third line (blank line above)" })
```

**Key concept:** `t({"a", "b"})` inserts `a\nb`. The table entries represent lines,
not concatenated strings. An empty string `""` means "end this line and start a new one"
(i.e., insert a newline).

**Example — a multi-line snippet with only static text:**

```lua
s("main", {
  t({ "int main(int argc, char *argv[]) {", "\t" }),
  i(0),
  t({ "", "}" }),
})
-- Expands to:
-- int main(int argc, char *argv[]) {
--     |cursor|
-- }
```

---

### insert_node (i)

Creates an **editable tabstop** — a position where the cursor stops and waits for
user input. Press `<Tab>` to jump forward through tabstops in numerical order.

```lua
i(1)              -- tabstop 1, no default text
i(1, "default")   -- tabstop 1 with default "default" (user can overwrite)
i(0)              -- special: final cursor position (exit point)
```

**Parameters:**
- First arg: position number (`1`, `2`, `3`... or `0` for final)
- Second arg (optional): default text pre-filled at this position

**Example:**

```lua
s("greet", {
  t("Hello, "), i(1, "name"), t("! Welcome to "), i(2, "place"), t("."),
  t({ "", "" }),
  i(0),
})
-- Expands to:
-- Hello, |name|! Welcome to |place|.
-- |final cursor|
--
-- Tab order: name → place → final cursor
```

**Mirroring:** Using the same number in multiple `i()` nodes mirrors the text.
When you edit one, all others with the same number update simultaneously.

---

### function_node (f)

Inserts **computed text** derived from other nodes. The function re-runs whenever
its dependencies change, updating the output in real-time.

```lua
f(function(args, parent, user_args)
  -- args[1] = text from first dependency (table of lines)
  -- args[2] = text from second dependency, etc.
  -- Return: string or table of strings
  return args[1][1]:upper()
end, { 1 })  -- dependency list: watch node 1
```

**Parameters:**
- First arg: a function `(args, parent, user_args) -> string | string[]`
- Second arg: table of node indices to watch (dependencies)

**How `args` works:**
- `args[n]` corresponds to the n-th entry in the dependency list
- Each `args[n]` is a `table of strings` (one per line of that node's current text)
- For single-line nodes: `args[1][1]` gets the text

**Example — uppercase mirror:**

```lua
s("upper", {
  i(1, "text"),
  t(" -> "),
  f(function(args)
    return args[1][1]:upper()
  end, { 1 }),
})
-- Type "hello" in tabstop 1 → output: "hello -> HELLO"
-- Updates live as you type
```

**Example — repeat a character N times:**

```lua
s("sep", {
  t("-- "),
  i(1, "40"),
  t({ "", "" }),
  f(function(args)
    local n = tonumber(args[1][1]) or 40
    return string.rep("-", n)
  end, { 1 }),
})
-- Type "60" → inserts a line of 60 dashes
```

---

### choice_node (c)

Provides a **list of alternatives** that the user can cycle through at a single
tabstop position. Only one choice is active at a time.

```lua
c(1, {
  t("option A"),
  t("option B"),
  i(nil, "custom input"),
  sn(nil, { t("complex: "), i(1, "inner") }),
})
```

**Parameters:**
- First arg: tabstop position number
- Second arg: table of alternative nodes (any node type)

**Cycling keys:** `<C-j>` next choice, `<C-k>` previous choice (configurable).

**Example — return statement with choices:**

```lua
s("ret", {
  t("return "),
  c(1, {
    t("nil"),
    t("true"),
    t("false"),
    i(nil, "value"),  -- free-form input as last option
  }),
})
-- Expands to: return |nil|
-- Press <C-j>: return |true|
-- Press <C-j>: return |false|
-- Press <C-j>: return |value| (editable)
```

**Example — variable declaration style:**

```lua
s("var", {
  c(1, {
    t("local "),
    t("global "),
    t(""),
  }),
  i(2, "name"),
  t(" = "),
  i(3, "value"),
})
```

---

### dynamic_node (d)

Generates **new snippet structure at runtime** based on other nodes' content.
Unlike `function_node` which only returns text, `dynamic_node` returns a full
`snippet_node` containing any combination of nodes (including more tabstops).

```lua
d(position, function(args, parent, old_state, user_args)
  -- Must return a snippet_node: sn(nil, { ... })
  return sn(nil, { t("generated"), i(1, "editable") })
end, { dependencies })
```

**Parameters:**
- First arg: tabstop position
- Second arg: generator function → must return `sn(nil, { ... })`
- Third arg: dependency list (like function_node)

**Key difference from function_node:**
- `f()` returns static text (string) — no interactivity
- `d()` returns a `snippet_node` — can contain new `i()`, `c()`, `t()` nodes

**Example — generate N arguments:**

```lua
s("args", {
  t("function("),
  i(1, "3"),
  t({ ")", "" }),
  d(2, function(args)
    local count = tonumber(args[1][1]) or 0
    local nodes = {}
    for idx = 1, count do
      if idx > 1 then table.insert(nodes, t({ "", "" })) end
      table.insert(nodes, t("  arg" .. idx .. " = "))
      table.insert(nodes, i(idx, "nil"))
    end
    if #nodes == 0 then return sn(nil, { t("") }) end
    return sn(nil, nodes)
  end, { 1 }),
})
-- Type "3" → generates:
-- function(3)
--   arg1 = |nil|
--   arg2 = |nil|
--   arg3 = |nil|
-- Change to "2" → regenerates with only 2 args
```

**Important:** The generator re-runs every time a dependency changes, destroying
and recreating the inner nodes. User input in previous dynamic content is lost.

---

### snippet_node (sn)

A **nested snippet container** used exclusively inside `dynamic_node` and `choice_node`.
It wraps multiple nodes into a single unit that can be returned or selected as a group.

```lua
sn(nil, {
  t("prefix: "),
  i(1, "editable"),
  t(" suffix"),
})
```

**Parameters:**
- First arg: jump position (almost always `nil` — the parent manages positioning)
- Second arg: table of nodes (same as a snippet body)

**You never use `sn` directly at the top level** — it only appears as the return
value of `d()` generators or as a choice inside `c()`:

```lua
-- Inside dynamic_node:
d(2, function(args)
  return sn(nil, { t("result: "), i(1, "value") })
end, { 1 })

-- Inside choice_node:
c(1, {
  t("simple"),
  sn(nil, { t("complex: "), i(1, "detail"), t(" end") }),
})
```

**Why it exists:** LuaSnip requires a snippet-like wrapper to manage tabstop
numbering and jump targets within dynamically generated content. `sn` provides
this wrapper without being a full top-level snippet.

---

### Postfix Snippets

Postfix snippets trigger **after existing text** with a dot-syntax. The text before
the dot is captured and available as `POSTFIX_MATCH`.

```lua
local postfix = require("luasnip.extras.postfix").postfix

postfix({ trig = ".len", desc = "Get length" }, {
  f(function(_, parent)
    return "#" .. parent.snippet.env.POSTFIX_MATCH
  end),
})
```

**How it works:**
1. User types: `myTable.len`
2. LuaSnip matches `.len` postfix trigger
3. `POSTFIX_MATCH` captures `myTable`
4. Expansion replaces `myTable.len` with `#myTable`

**Example — method wrapping:**

```lua
postfix({ trig = ".not", desc = "Negate" }, {
  f(function(_, parent)
    return "not " .. parent.snippet.env.POSTFIX_MATCH
  end),
})
-- typing: condition.not → expands to: not condition
```

---

### Real-World Example

This snippet generates documentation comments that update as you edit function arguments:

```lua
local ls = require("luasnip")
local s = ls.snippet
local t = ls.text_node
local i = ls.insert_node
local f = ls.function_node

local function gen_docs(args)
  local docs = {}
  for _, line in ipairs(args[1]) do
    line = vim.trim(line)
    if line ~= "" then
      local var = line:match('^local%s+(.-)%s*=')
      if var then
        table.insert(docs, "# :" .. var .. ": ")
      end
    end
  end
  if #docs == 0 then return "" end
  docs[#docs + 1] = ""
  return docs
end

return {
  s({ trig = "fun", desc = "function with docstrings" }, {
    t("# "), i(3, "Description"), t({ "", "" }),
    f(gen_docs, { 2 }),  -- regenerates when node 2 changes
    t("function "), i(1, "name"), t({ "() {", "\t" }),
    i(2, "local arg=\"$1\""), t({ "", "\t" }),
    i(0), t({ "", "}" }),
  }),
}
```

As you edit the argument lines (node 2), the docstring block updates automatically.

---

## Filetype Resolution

| Path | Filetype |
|------|----------|
| `snippets/sh.snippets` | sh |
| `snippets/sh/curl.snippets` | sh |
| `snippets/python/python.snippets` | python |
| `lua/snippets/all.lua` | all (every filetype) |

---

## When to Use Which Format

| Need | Format | Location |
|------|--------|----------|
| Static template with placeholders | SnipMate | `snippets/{ft}/` |
| VimL evaluation (date, filename) | SnipMate (backticks) | `snippets/{ft}/` |
| Computed/mirrored transformations | Lua (function_node) | `lua/snippets/` |
| Content that changes based on input | Lua (dynamic_node) | `lua/snippets/` |
| Postfix dot-triggers | Lua (postfix) | `lua/snippets/` |
| Choice between alternatives | Lua (choice_node) | `lua/snippets/` |

---

## Testing

Run the headless test to verify all snippets load correctly:

```bash
nvim --headless -u NONE -c "luafile scripts/test_snippets.lua"
```

---

## Keybindings

| Key | Action |
|-----|--------|
| `<Tab>` | Jump to next tabstop (in snippet) / next cmp item / expand trigger / literal tab |
| `<S-Tab>` | Jump to previous tabstop (in snippet) / prev cmp item / fallback |
| `<CR>` | Confirm selected completion item (expands snippet if selected) |
| `<C-Space>` | Manually trigger completion menu |
| `<C-j>` | Next choice (choice_node) |
| `<C-k>` | Previous choice (choice_node) |
