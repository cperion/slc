-- A project: the entry, extra module paths and build options. Lua is the
-- configuration language; slc reads this table and nothing else.
return {
    entry = 'main.slc',
    paths = { 'model' },
    options = { opt = 2 },
}
