---------
-- Lua 5.1+ lexical analyzer written in Lua.
--
-- This file is part of LuaSrcDiet, based on Yueliang material.
--
-- **Notes:**
--
-- * This is a version of the native 5.1.x lexer from Yueliang 0.4.0,
--   with significant modifications to handle LuaSrcDiet's needs:
--   (1) llex.error is an optional error function handler,
--   (2) seminfo for strings include their delimiters and no
--       translation operations are performed on them.
-- * ADDED shbang handling has been added to support executable scripts.
-- * NO localized decimal point replacement magic.
-- * NO limit to number of lines.
-- * NO support for compatible long strings (LUA\_COMPAT_LSTR).
-- * Added goto keyword and double-colon operator (Lua 5.2+).
----
local find = string.find
local fmt = string.format
local match = string.match
local sub = string.sub
local tonumber = tonumber

local M = {}

local kw = {}
for v in ([[
and break do else elseif end false for function goto if in
local nil not or repeat return then true until while]]):gmatch("%S+") do
  kw[v] = true
end

local z,                -- source stream
      sourceid,         -- name of source
      I,                -- position of lexer
      buff,             -- buffer for strings
      ln,               -- line number
      tok,              -- lexed token list
      seminfo,          -- lexed semantic information list
      tokln             -- line numbers for messages


--- Adds information to token listing.
--
-- @tparam string token
-- @tparam string info
local function addtoken(token, info)
  local i = #tok + 1
  tok[i] = token
  seminfo[i] = info
  tokln[i] = ln
end

--- Handles line number incrementation and end-of-line characters.
--
-- @tparam int i Position of lexer in the source stream.
-- @tparam bool is_tok
-- @treturn int
local function inclinenumber(i, is_tok)
  local old = sub(z, i, i)
  i = i + 1  -- skip '\n' or '\r'
  local c = sub(z, i, i)
  if (c == "\n" or c == "\r") and (c ~= old) then
    i = i + 1  -- skip '\n\r' or '\r\n'
    old = old..c
  end
  if is_tok then addtoken("TK_EOL", old) end
  ln = ln + 1
  I = i
  return i
end

--- Returns a chunk name or id, no truncation for long names.
--
-- @treturn string
local function chunkid()
  if sourceid and match(sourceid, "^[=@]") then
    return sub(sourceid, 2)  -- remove first char
  end
  return "[string]"
end

--- Formats error message and throws error.
--
-- A simplified version, does not report what token was responsible.
--
-- @tparam string s
-- @tparam int line The line number.
-- @raise
local function errorline(s, line)
  local e = M.error or error
  e(fmt("%s:%d: %s", chunkid(), line or ln, s))
end

--- Counts separators (`="` in a long string delimiter.
--
-- @tparam int i Position of lexer in the source stream.
-- @treturn int
local function skip_sep(i)
  local s = sub(z, i, i)
  i = i + 1
  local count = #match(z, "=*", i)
  i = i + count
  I = i
  return (sub(z, i, i) == s) and count or (-count) - 1
end

--- Reads a long string or long comment.
--
-- @tparam bool is_str
-- @tparam string sep
-- @treturn string
-- @raise if unfinished long string or comment.
local function read_long_string(is_str, sep)
  local i = I + 1  -- skip 2nd '['
  local c = sub(z, i, i)
  if c == "\r" or c == "\n" then  -- string starts with a newline?
    i = inclinenumber(i)  -- skip it
  end
  while true do
    local p, _, r = find(z, "([\r\n%]])", i) -- (long range match)
    if not p then
      errorline(is_str and "unfinished long string" or
                "unfinished long comment")
    end
    i = p
    if r == "]" then                    -- delimiter test
      if skip_sep(i) == sep then
        buff = sub(z, buff, I)
        I = I + 1  -- skip 2nd ']'
        return buff
      end
      i = I
    else                                -- newline
      buff = buff.."\n"
      i = inclinenumber(i)
    end
  end--while
end

--- Reads a string.
--
-- @tparam string del The delimiter.
-- @treturn string
-- @raise if unfinished string or too large escape sequence.
local function read_string(del)
  local i = I
  while true do
    local p, _, r = find(z, "([\n\r\\\"\'])", i) -- (long range match)
    if p then
      if r == "\n" or r == "\r" then
        errorline("unfinished string")
      end
      i = p
      if r == "\\" then                         -- handle escapes
        i = i + 1
        r = sub(z, i, i)
        if r == "" then break end -- (EOZ error)
        p = find("abfnrtv\n\r", r, 1, true)

        if p then                               -- special escapes
          if p > 7 then
            i = inclinenumber(i)
          else
            i = i + 1
          end

        elseif find(r, "%D") then               -- other non-digits
          i = i + 1

        else                                    -- \xxx sequence
          local _, q, s = find(z, "^(%d%d?%d?)", i)
          i = q + 1
          if s + 1 > 256 then -- UCHAR_MAX
            errorline("escape sequence too large")
          end

        end--if p
      else
        i = i + 1
        if r == del then                        -- ending delimiter
          I = i
          return sub(z, buff, i - 1)            -- return string
        end
      end--if r
    else
      break -- (error)
    end--if p
  end--while
  errorline("unfinished string")
end


--- Initializes lexer for given source _z and source name _sourceid.
--
-- @tparam string _z The source code.
-- @tparam string _sourceid Name of the source.
local function init(_z, _sourceid)
  z = _z                        -- source
  sourceid = _sourceid          -- name of source
  I = 1                         -- lexer's position in source
  ln = 1                        -- line number
  tok = {}                      -- lexed token list*
  seminfo = {}                  -- lexed semantic information list*
  tokln = {}                    -- line numbers for messages*

  -- Initial processing (shbang handling).
  local p, _, q, r = find(z, "^(#[^\r\n]*)(\r?\n?)")
  if p then                             -- skip first line
    I = I + #q
    addtoken("TK_COMMENT", q)
    if #r > 0 then inclinenumber(I, true) end
  end
end

--- Runs lexer on the given source code.
--
-- @tparam string source The Lua source to scan.
-- @tparam ?string source_name Name of the source (optional).
-- @treturn {string,...} A list of lexed tokens.
-- @treturn {string,...} A list of semantic information (lexed strings).
-- @treturn {int,...} A list of line numbers.
function M.lex(source, source_name)
  init(source, source_name)

  while true do--outer
    local i = I
    -- inner loop allows break to be used to nicely section tests
    while true do --luacheck: ignore 512

      local p, _, r = find(z, "^([_%a][_%w]*)", i)
      if p then
        I = i + #r
        if kw[r] then
          addtoken("TK_KEYWORD", r)             -- reserved word (keyword)
        else
          addtoken("TK_NAME", r)                -- identifier
        end
        break -- (continue)
      end

      local p, _, r = find(z, "^(%.?)%d", i)
      if p then                                 -- numeral
        if r == "." then i = i + 1 end
        local _, q, r = find(z, "^%d*[%.%d]*([eE]?)", i)  --luacheck: ignore 421
        i = q + 1
        if #r == 1 then                         -- optional exponent
          if match(z, "^[%+%-]", i) then        -- optional sign
            i = i + 1
          end
        end
        local _, q = find(z, "^[_%w]*", i)
        I = q + 1
        local v = sub(z, p, q)                  -- string equivalent
        if not tonumber(v) then            -- handles hex test also
          errorline("malformed number")
        end
        addtoken("TK_NUMBER", v)
        break -- (continue)
      end

      local p, q, r, t = find(z, "^((%s)[ \t\v\f]*)", i)
      if p then
        if t == "\n" or t == "\r" then          -- newline
          inclinenumber(i, true)
        else
          I = q + 1                             -- whitespace
          addtoken("TK_SPACE", r)
        end
        break -- (continue)
      end

      local _, q = find(z, "^::", i)
      if q then
        I = q + 1
        addtoken("TK_OP", "::")
        break -- (continue)
      end

      local p, q = find(z, "^(<%s-const%s->)", i)
      if p then
        I = q + 1
        addtoken("TK_VARATTR", "<const> ")
        break
      end

      local p, q = find(z, "^(<%s-close%s->)", i)
      if p then
        I = q + 1
        addtoken("TK_VARATTR", "<close> ")
        break
      end

      local r = match(z, "^%p", i)
      if r then
        buff = i
        local p = find("-[\"\'.=<>~", r, 1, true)  --luacheck: ignore 421
        if p then
          -- two-level if block for punctuation/symbols
          if p <= 2 then
            if p == 1 then                      -- minus
              local c = match(z, "^%-%-(%[?)", i)
              if c then
                i = i + 2
                local sep = -1
                if c == "[" then
                  sep = skip_sep(i)
                end
                if sep >= 0 then                -- long comment
                  addtoken("TK_LCOMMENT", read_long_string(false, sep))
                else                            -- short comment
                  I = find(z, "[\n\r]", i) or (#z + 1)
                  addtoken("TK_COMMENT", sub(z, buff, I - 1))
                end
                break -- (continue)
              end
              -- (fall through for "-")
            else                                -- [ or long string
              local sep = skip_sep(i)
              if sep >= 0 then
                addtoken("TK_LSTRING", read_long_string(true, sep))
              elseif sep == -1 then
                addtoken("TK_OP", "[")
              else
                errorline("invalid long string delimiter")
              end
              break -- (continue)
            end

          elseif p <= 5 then
            if p < 5 then                       -- strings
              I = i + 1
              addtoken("TK_STRING", read_string(r))
              break -- (continue)
            end
            r = match(z, "^%.%.?%.?", i)        -- .|..|... dots
            -- (fall through)

          else                                  -- relational
            r = match(z, "^%p=?", i)
            -- (fall through)
          end
        end
        I = i + #r
        addtoken("TK_OP", r)  -- for other symbols, fall through
        break -- (continue)
      end

      local r = sub(z, i, i)
      if r ~= "" then
        I = i + 1
        addtoken("TK_OP", r)                    -- other single-char tokens
        break
      end
      addtoken("TK_EOS", "")                    -- end of stream,
      return tok, seminfo, tokln                -- exit here

    end--while inner
  end--while outer
end

return M
