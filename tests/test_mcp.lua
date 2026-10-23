local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      child.restart({ "-u", "assets/minimal.lua" })
    end,
    post_once = function()
      child.stop()
    end,
  },
})

local setup = [[
  local registry = require('sia.mcp.registry')
  registry.configure({ servers = { docs = {
    command = { 'python3', '-u', 'tests/fixtures/mcp_server.py', MODE or 'normal' },
    tools = { 'search' }, startup_timeout_ms = 2000, request_timeout_ms = 1000,
  } } })
  registry.ensure('docs', function(err, entry) _G.ready = {err = err, ok = entry ~= nil} end)
  assert(vim.wait(4000, function() return _G.ready ~= nil end))
]]

T["project selection and commands honor config.json precedence"] = function()
  child.lua([[
    local r = require('sia.mcp.registry')
    r.configure({servers={docs={command={'echo'},tools={'search'}}}})
    local root = vim.fn.tempname()
    local plugin_path = vim.fn.getcwd() .. '/plugin/sia.lua'
    vim.fn.mkdir(root .. '/.sia', 'p')
    vim.cmd.cd(root)
    local config = require('sia.config')
    local function user(value)
      vim.fn.writefile({vim.json.encode(value)}, root .. '/.sia/config.json')
      config.invalidate_local_config(root)
    end
    dofile(plugin_path)
    vim.cmd('SiaMcp enable docs')
    vim.cmd('SiaMcp enable docs')
    assert(vim.deep_equal(config.get_local_config().mcp, {'docs'}))
    local auto = vim.json.decode(table.concat(vim.fn.readfile(root .. '/.sia/auto.json')))
    assert(#auto.mcp == 1)
    user({mcp={}})
    assert(#config.get_local_config().mcp == 0)
    user({mcp={'docs'}})
    vim.cmd('SiaMcp disable docs')
    assert(vim.deep_equal(config.get_local_config().mcp, {'docs'}))
    user({})
    assert(#config.get_local_config().mcp == 0)
    user({mcp={servers={evil={command={'false'}}}}})
    assert(config.get_local_config() == nil)
    user({mcp={'unknown'}})
    assert(config.get_local_config() == nil)
    vim.fn.delete(root, 'rf')
  ]])
end

T["project selection refresh removes disabled tools at request boundaries"] = function()
  child.lua(setup)
  child.lua([[
    local config = require('sia.config')
    local selection = {'docs'}
    config.get_local_config = function() return {mcp=selection} end
    local r = require('sia.mcp.registry')
    local conv = {project_mcp=true, tool_definitions={}, tool_implementation={}}
    r.prepare(conv, function() end)
    assert(#conv.tool_definitions == 1)
    selection = {}
    r.prepare(conv, function() end)
    assert(#conv.tool_definitions == 0 and next(conv.tool_implementation) == nil)
    assert(r.servers.docs.client.state == 'ready')
  ]])
end

T["discovery paginates, allowlists and reuses a process"] = function()
  child.lua(setup)
  eq(true, child.lua_get("ready.ok"))
  child.lua([[
    local r = require('sia.mcp.registry')
    local entry = r.servers.docs
    assert(#entry.tools == 2 and #entry.exposed == 1)
    local client = entry.client
    r.ensure('docs', function(err, e) assert(not err and e.client == client) end)
    local conv = {mcp_servers={'docs'}, tool_definitions={}, tool_implementation={}}
    r.prepare(conv, function() _G.prepared = true end)
    assert(prepared and #conv.tool_definitions == 1)
    assert(conv.tool_definitions[1].name:match('^mcp_docs_search_'))
    r.stop()
    assert(client.state == 'stopped' and next(client.pending) == nil)
  ]])
end

T["negotiation and framing failures complete startup once"] = function()
  for _, mode in ipairs({ "version", "malformed", "oversized" }) do
    child.lua("MODE = ...; ready = nil", { mode })
    child.lua(setup)
    eq(false, child.lua_get("ready.ok"))
    eq(true, child.lua_get('type(ready.err) == "string"'))
  end
end

T["calls distinguish errors, timeouts, cancellation and exit"] = function()
  child.lua(setup)
  child.lua([[
    local c = require('sia.mcp.registry').servers.docs.client
    local function call(query, timeout, cancel_now)
      local count, outcome = 0, nil
      local cancel = c:request('tools/call', {name='search', arguments={query=query}}, function(err, result)
        count = count + 1; outcome = {err=err, result=result}
      end, timeout)
      if cancel_now then cancel() end
      assert(vim.wait(2000, function() return outcome ~= nil end))
      assert(count == 1)
      return outcome
    end
    assert(call('ok').result.content[1].text == 'page 3\nEvidence')
    assert(call('error').result.isError)
    assert(call('protocol_error').err:find('protocol error'))
    assert(call('slow', 20).err:find('timed out'))
    vim.wait(300)
    assert(call('slow', 1000, true).err:find('cancelled'))
    vim.wait(300)
    assert(next(c.pending) == nil)
    assert(call('exit').err:find('exited'))
  ]])
end

T["adapter preserves schemas, stable names and bounded mixed output"] = function()
  child.lua([[
    local a = require('sia.mcp.tools')
    local schema = {type='object', properties={node={['$ref']='#/$defs/node'}},
      ['$defs']={node={type='object', properties={value={type='integer', minimum=1}}}}, additionalProperties=false}
    local remote = {name='find.a', inputSchema=schema}
    local first = assert(a.wrap('a_b', remote, {}, {}))
    local second = assert(a.wrap('a', {name='b_find.a', inputSchema=schema}, {}, {}))
    assert(first.definition.name ~= second.definition.name and #first.definition.name <= 64)
    assert(vim.deep_equal(first.definition.parameters, schema.properties))
    assert(vim.deep_equal(first.definition.defs, schema['$defs']))
    assert(first.definition.additionalProperties == false)
    assert(first.definition.input_schema == nil)
    assert(not a.wrap('a', {name='bad', inputSchema={type='object', anyOf={}}}, {}, {}))
    local text = a.normalize({content={{type='text',text='p. 4'},{type='image',data='SECRET'}}, structuredContent={page=4}}, 500)
    assert(text:find('p. 4') and text:find('Unsupported MCP content: image') and text:find('Structured content'))
    assert(not text:find('SECRET'))
    assert(a.normalize({content={{type='text',text=string.rep('x',100)}}},10):find('truncated'))
  ]])
end

T["adapter accepts FastMCP titles and preserves nested annotations"] = function()
  child.lua([[
    local schema = {
      title = 'searchArguments',
      type = 'object',
      properties = {query = {title = 'Query', type = 'string'}},
      required = {'query'},
    }
    local tool = assert(require('sia.mcp.tools').wrap('docs', {
      name = 'search', inputSchema = schema,
    }, {}, {}))
    assert(vim.deep_equal(tool.definition.parameters, schema.properties))
    assert(tool.definition.parameters ~= schema.properties)
    assert(tool.definition.parameters.query.title == 'Query')
    assert(tool.definition.additionalProperties == true)
  ]])
end

T["untrusted local config and annotations cannot authorize or launch"] = function()
  child.lua([[
    local r = require('sia.mcp.registry')
    assert(not pcall(r.configure, {servers={bad={command='sh -c evil',tools={'x'}}}}))
    assert(not pcall(r.configure, {servers={bad={command={'echo'},tools={}}}}))
    require('sia.config').get_local_config = function() return {mcp={servers={evil={command={'false'},tools={'x'}}}}} end
    r.configure({})
    assert(next(r.servers) == nil)
    local tool = assert(require('sia.mcp.tools').wrap('docs', {
      name='search', inputSchema={type='object'}, annotations={readOnlyHint=true}
    }, {}, {}))
    assert(not tool.implementation.allow_parallel({}, {approved_tools={}}))
    local dispatched = false
    require('sia.permissions').resolve_permissions = function() return {deny=true} end
    tool.implementation.execute({}, function(result) assert(result.content:find('denied')); dispatched=true end,
      {conversation={approved_tools={}},turn_id='test'})
    assert(dispatched)
  ]])
end

T["project-authorized execution skips confirmation and bounds tool results"] = function()
  child.lua([[
    local config = require('sia.config')
    config.options.settings.ui.confirm.async.enable = false
    config.options.settings.ui.confirm.use_vim_ui = true
    config.options.settings.ui.confirm.show_preview = false
    local sent, outcome = false, nil
    vim.ui.input = function() error('MCP calls must not prompt') end
    vim.ui.select = function() error('MCP calls must not prompt') end
    require('sia.permissions').resolve_permissions = function() return {ask=true} end
    local client = {state='ready', request=function(_, method, params, callback)
      assert(method == 'tools/call' and params.arguments.query == 'needle')
      sent = true
      callback(nil,{content={{type='text',text='source p. 7: '..string.rep('x',100)}}})
      return function() end
    end}
    local tool = assert(require('sia.mcp.tools').wrap('docs',{
      name='search',inputSchema={type='object',properties={query={type='string'}}}
    },client,{max_output_bytes=32}))
    tool.implementation.execute({query='needle'},function(result) outcome=result end,{
      conversation={approved_tools={}},turn_id='test'
    })
    assert(sent and outcome.content:find('source p. 7') and outcome.content:find('truncated'))
    sent, outcome = false, nil
    tool.implementation.execute({query='needle'},function(result) outcome=result end,{
      conversation={approved_tools={}},turn_id='test',cancellable={is_cancelled=true}
    })
    assert(not sent and outcome.content:find('cancelled'))
    client.state = 'stopped'
    tool.implementation.execute({query='needle'},function(result) outcome=result end,{
      conversation={approved_tools={}},turn_id='test'
    })
    assert(not sent and outcome.content:find('unavailable'))
  ]])
end

T["providers serialize shared function schemas through JSON round trips"] = function()
  child.lua([[
    local schema = vim.json.decode([=[{
      "type": "object",
      "properties": {
        "x": {"title": "X", "anyOf": [{"$ref": "#/$defs/value"}, {"type": "null"}], "default": null},
        "empty": {"type": "object", "properties": {}}
      },
      "required": [],
      "$defs": {"value": {"type": "string", "pattern": "^a"}},
      "anyOf": [{"required": ["x"]}, {"required": ["empty"]}],
      "oneOf": [{"properties": {"x": {"type": "string"}}}, {"properties": {"x": {"type": "null"}}}],
      "allOf": [{"properties": {"empty": {"type": "object"}}}],
      "additionalProperties": {"type": "integer"}
    }]=])
    local definition = assert(require('sia.mcp.tools').schema(schema))
    definition.name = 'mcp_test'
    definition.type = 'function'
    definition.description = 'test'
    local tools = {definition}
    for _, case in ipairs({
      {require('sia.provider.openai').completion, 'completion'},
      {require('sia.provider.openai').responses, 'responses'},
      {require('sia.provider.anthropic').messages, 'anthropic'},
    }) do
      local data = {}
      case[1].prepare_tools(data, tools)
      local actual = case[2] == 'completion' and data.tools[1]['function'].parameters
        or case[2] == 'responses' and data.tools[1].parameters or data.tools[1].input_schema
      assert(vim.deep_equal(vim.json.decode(vim.json.encode(actual)), schema))
    end
    local common = require('sia.provider.common')
    assert(common.tool_schema({parameters=vim.empty_dict(),required={}}).additionalProperties == false)
    for _, additional in ipairs({true, false, {type='integer'}}) do
      local imported = assert(require('sia.mcp.tools').schema({
        type='object', additionalProperties=additional,
      }))
      assert(vim.deep_equal(common.tool_schema(imported).additionalProperties, additional))
    end
  ]])
end

T["concurrent startup, notifications, unsupported requests and reconnect"] = function()
  child.lua([[
    local r = require('sia.mcp.registry')
    r.configure({servers={docs={command={'python3','-u','tests/fixtures/mcp_server.py'},tools={'search'}}}})
    local count, client = 0, nil
    for _ = 1, 5 do
      r.ensure('docs', function(err, entry)
        assert(not err)
        assert(not client or client == entry.client)
        client = entry.client; count = count + 1
      end)
    end
    assert(vim.wait(3000,function() return count == 5 end))
    local function call(query)
      local done
      client:request('tools/call',{name='search',arguments={query=query}},function(err,result)
        assert(not err and result); done=true
      end)
      assert(vim.wait(2000,function() return done end))
    end
    call('requests')
    call('changed')
    assert(client.dirty)
    local refreshed
    r.ensure('docs',function(err) assert(not err); refreshed=true end)
    assert(vim.wait(2000,function() return refreshed end))
    assert(not client.dirty)
    r.stop('docs')
    local restarted
    r.ensure('docs',function(err,entry) assert(not err and entry.client ~= client); restarted=true end)
    assert(vim.wait(3000,function() return restarted end))
  ]])
end

return T
