# Local patches to LuaMacro 2.5.0

Only `luam` is modified. The patch below applies to the upstream 2.5.0 `luam`
(the driver script; `macro.lua` and the `macro/` modules are untouched).

It fixes three runner problems found while testing the `macro.let` experiment:

1. **Traceback rewriting could not terminate.** `fix_error_trace` rewrote
   `[string "file"]:N:` only, but its loop kept re-matching the function frame
   form `<[string "file"]:N>` (no trailing colon), so any uncaught error raised
   from an anonymous function spun forever. The rewrite is now a single pass over
   both forms, using the line table per occurrence; `lookup_line` also guards an
   empty/nil line table.
2. **Runtime failures exited 0.** `subst_runstring` discarded the `runstring`
   result and the main path ignored it. Dump/write modes now return success and
   the main path `os.exit`s with the result. A missing input file also exits 1
   instead of returning from the main chunk.
3. **`-e` needed a dummy input file.** The "no input" usage check did not consider
   `-e`, and then `-e` statements were never reached. The check now allows `-e`
   without an input file.

Regression coverage: `make validate-luamacro` (see `tools/validate_luamacro.lua`).
It checks the anonymous-frame case terminates with mapped lines, named runtime
errors and missing files exit nonzero, `-d` exits zero, and standalone `-e`
works and propagates errors.

```diff
--- luam (upstream 2.5.0)
+++ luam (vendored)
@@ -71,13 +71,16 @@
     i = i + 1
 end
 
-if not args[1] and not args.i then
+if not args[1] and not args.i and not args.e then
     print(usage)
     os.exit()
 elseif args[1] then
     args.input_name = args[1]
     args.input,err = io.open(args[1],'r')
-    if err then return print(err) end
+    if err then
+        io.stderr:write(err,'\n')
+        os.exit(1)
+    end
     table.remove(args,1)
 end
 -- set defaults, if flags not specified
@@ -93,6 +96,7 @@
 -- in the output.
 
 local function lookup_line (lno,li)
+    if not li or #li == 0 then return nil end
     for i = 1,#li-1 do
         --print(li[i].il,li[i].ol,lno,'match')
         if lno < li[i+1].ol then
@@ -121,17 +125,22 @@
     local ino
     if strname then
         lno = tonumber(lno)
-        if li then
-            ino = lookup_line(lno,li)
-            err = err:gsub('%[string "%S+"%]:'..(lno or '?')..':',strname..':'..(ino or '?'))
-        end
+        if li then ino = lookup_line(lno,li) end
+        -- Rewrite every frame in one pass: the error prefix and traceback lines
+        -- end in ':', a function's definition frame ends in '>'.  The old code
+        -- replaced only the ':' form and looped until no match remained, so an
+        -- unnamed frame (`<[string "file"]:N>`) made it spin forever.
+        err = err:gsub('%[string "(%S+)"%]:(%d+)([:>])',function (name,gen,tail)
+            local mapped = li and lookup_line(tonumber(gen),li)
+            return name..':'..(mapped or gen)..tail
+        end)
     end
     return err,lno,ino
 end
 
 local function runstring (code,name,li,...)
     local res,err = loadstring(code,name)
-    local lno,ok
+    local lno,ino,ok
     if not res then
         err,lno,ino = fix_error_trace(err,li)
         if ino then
@@ -152,11 +161,7 @@
     ok,err = xpcall(function(...) return res(...) end, debug.traceback)
     if not ok then
         err = err:gsub("%[C%]: in function 'xpcall'.+",'')
-        if li then
-            repeat
-                err,lno = fix_error_trace(err,li)
-            until not lno
-        end
+        err = fix_error_trace(err,li)
         io.stderr:write(err,'\n')
     end
     return ok
@@ -184,6 +189,7 @@
             f:write(buf)
             f:close()
         end
+        return true
     else
         return runstring(buf,name,li,...)
     end
@@ -266,15 +272,17 @@
 
 require 'macro.ifelse'
 
+local ok = true
 if args.e ~= '' then
-    subst_runstring(args.e,"<temp>")
+    ok = subst_runstring(args.e,"<temp>") ~= false
 else
     if args.input then
         arg = args
         arg[0] = args.input_name
         arg[-1] = 'luam'
-        subst_runstring(args.input,args.input_name,unpack(args))
+        ok = subst_runstring(args.input,args.input_name,unpack(args)) ~= false
     elseif args.i then
         interactive_loop()
     end
 end
+os.exit(ok and 0 or 1)
```
