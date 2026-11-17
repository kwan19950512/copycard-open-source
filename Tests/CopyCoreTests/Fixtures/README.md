# MHL 格式与独立验证依据

本项目导出传统 MHL 1.0，不宣称生成 ASC MHL 2.0 历史链。

- 参考实现：<https://github.com/pomfort/mhl-tool>，MIT 许可。
- 核对版本：`34f06f22ae965d12e49590adc301373d5ce611ff`。
- 上游参考文件：`tests/aux_files/mhl_verify_xxhash64be/xxhash64be.mhl`、`tests/aux_files/mhl_verify_md5/md5.mhl`。
- 清单放在目标根目录，`file` 使用相对此目录的路径；摘要元素为 `xxhash64be` 或 `md5`。

没有复制上游媒体或整套仓库进本项目。`ReportTests.testPomfortReferenceVerifier` 用本地生成的极小文件导出清单，调用独立工具确认正常文件验证成功，再损坏生成文件确认验证失败。设置 `MHL_REFERENCE_TOOL` 为编译好的 Pomfort `mhl` 可执行文件路径后运行 `swift test`；未提供工具则该项明确跳过。独立工具不属于产品依赖。
