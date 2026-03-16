-- 仅提前加载模块；真正的命令/autocmd 注册发生在 setup() 中。
pcall(require, "oil_pyright_remote")
