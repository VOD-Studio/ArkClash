# 领域文档

engineering skills 探索代码前怎么读本仓库的领域文档。本仓库是单一上下文。

## 探索前先读

- 根目录的 **`GLOSSARY.md`**：术语表。
- **`docs/adr/`**：读和这次要改的地方相关的决策记录。

这些文件不存在时**直接继续**，不用提示缺失，也不用建议先建。`/domain-modeling`（经由 `/grill-with-docs`、`/improve-codebase-architecture` 调用）会在术语或决策真正定下来时再创建。

## 文件结构

```
/
├── GLOSSARY.md
├── docs/adr/
│   ├── 0001-core-in-vpn-extension.md
│   └── ...
├── core/
└── entry/
```

## 用术语表里的词

输出里提到领域概念时（issue 标题、重构方案、假设、测试名），用 `GLOSSARY.md` 里定义的词，不换成术语表明确不用的同义词。

需要的概念不在术语表里，说明要么在发明项目不用的说法（重新考虑），要么术语表确实有缺口（记下来交给 `/domain-modeling`）。

## 和 ADR 冲突时明说

输出和已有 ADR 矛盾时，明确指出，不要悄悄推翻：

> _和 ADR-0003（UI 通过 external-controller 访问内核）矛盾，但值得重新讨论，因为……_
