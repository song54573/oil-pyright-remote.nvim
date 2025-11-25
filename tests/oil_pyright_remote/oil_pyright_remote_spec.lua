describe("oil_pyright_remote", function()
  it("loads without error and registers commands", function()
    local ok, err = pcall(require, "oil_pyright_remote")
    assert.is_true(ok, err or "module should load")

    local cmds = vim.api.nvim_get_commands({ builtin = false })
    local expected = {
      "PyrightRemoteHost",
      "PyrightRemoteEnv",
      "PyrightRemoteRoot",
      "PyrightRemoteRestart",
      "PyrightRemoteEnvForget",
    }
    for _, name in ipairs(expected) do
      assert.truthy(cmds[name], ("command %s should exist"):format(name))
    end
  end)
end)
