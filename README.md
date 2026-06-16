# PBIP 字段依赖扫描工具

Power BI PBIP 项目字段依赖分析工具。扫描报表中所有视觉对象、筛选器、切片器、条件格式对字段的引用，并与语义模型定义对比，自动识别未使用的字段和表，辅助精简模型。

## 功能特性

- **零依赖运行** — 仅使用 PowerShell 内置命令，无需安装 Python、Node.js 或任何第三方模块
- **自动发现项目结构** — 放入 PBIP 文件夹即可运行，自动识别 Report 和 SemanticModel 目录
- **全面扫描** — 覆盖视觉对象字段、三级筛选器（报表/页面/视觉对象）、切片器、条件格式
- **未使用字段分析** — 对比 TMDL 定义与报表引用，找出从未被使用的列和度量值
- **未使用表分析** — 识别完全没有任何字段被引用的表
- **双格式输出** — CSV（每类一个文件）+ 交互式 HTML 报告（浏览器打开，支持搜索筛选）

## 快速开始

### 方式一：双击运行（Windows）

1. 将 `pbip_field_scanner.ps1` 和 `pbip_field_scanner.bat` 复制到你的 PBIP 项目根目录
2. 双击 `pbip_field_scanner.bat`
3. 等待扫描完成
4. 在浏览器中打开生成的 `PBIP_Field_Dependency_Report.html`

### 方式二：命令行运行

```powershell
# 基本用法（扫描当前目录下的 PBIP 项目）
powershell -ExecutionPolicy Bypass -File pbip_field_scanner.ps1

# 扫描指定目录
powershell -ExecutionPolicy Bypass -File pbip_field_scanner.ps1 -Path "D:\Projects\MyReport.pbip"

# 只输出 CSV
powershell -ExecutionPolicy Bypass -File pbip_field_scanner.ps1 -Output csv

# 只输出 HTML
powershell -ExecutionPolicy Bypass -File pbip_field_scanner.ps1 -Output html
```

## 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `-Path` | PBIP 项目根目录路径 | 脚本所在目录 |
| `-Output` | 输出格式：`csv` / `html` / `both` | `both` |

## 工作原理

工具直接读取 PBIP 项目的原始文件（JSON + TMDL），无需打开 Power BI Desktop：

1. **项目发现** — 定位 `.pbip` 文件，解析 Report 和 SemanticModel 目录路径
2. **报表层扫描** — 遍历所有页面和视觉对象，从以下位置提取字段引用：
   - `queryState` — 轴、值、图例、行、提示等字段
   - `filterConfig` — 报表级、页面级、视觉对象级筛选器
   - `objects` — 条件格式规则（ScopedEval）
3. **语义模型扫描** — 解析 TMDL 文件，提取列和度量值定义
4. **未使用分析** — 将所有已定义字段与所有被引用字段做差集，找出未使用的字段和表

## 输出文件

所有输出文件生成在 PBIP 项目根目录下。

### CSV 文件（每类分析一个文件）

| 文件 | 说明 |
|------|------|
| `PBIP_Visual_Fields_Detail.csv` | 报表中每一条字段引用：页面、视觉对象名称、来源类型（轴/筛选器/切片器/条件格式）、字段引用、字段类型 |
| `PBIP_Measure_Dependencies.csv` | TMDL 中定义的所有度量值：所属表、名称、DAX 表达式、内部字段依赖 |
| `PBIP_Measure_Expanded_Deps.csv` | 报表中使用的度量值展开后的间接字段依赖 |
| `PBIP_Fields_by_Page.csv` | 按页面和来源类型汇总的字段使用统计 |
| `PBIP_Field_Usage_Frequency.csv` | 字段引用频率排名（引用次数从高到低） |
| `PBIP_Unused_Fields.csv` | TMDL 中定义但报表中从未引用的列和度量值 |
| `PBIP_Unused_Tables.csv` | 表级使用汇总：总列数/度量值数 vs 已用列数/度量值数、使用状态 |

### HTML 报告

`PBIP_Field_Dependency_Report.html` — 自包含的交互式报告，浏览器直接打开：
- 汇总卡片显示各表记录数
- 可折叠展开各分析表
- 每个表格支持实时搜索筛选
- 无需任何外部依赖

## 输出字段说明

### 视觉对象字段明细

| 字段 | 说明 |
|------|------|
| Page | 报表页面显示名称 |
| VName | 视觉对象显示名称 |
| VType | 视觉对象类型（barChart、pivotTable、Slicer 等） |
| Source | 字段来源：Visual Field（视觉对象字段）、Visual Filter（视觉对象筛选器）、Slicer Field（切片器字段）、Page Filter（页面级筛选器）、Report Filter（报表级筛选器）、Conditional Format（条件格式） |
| Role | 字段角色：Axis（轴）、Value(Y)（值）、Legend（图例）、Rows（行）、Values（值）、Slicer Field（切片器字段）、Tooltip（提示）、filter（筛选器）、CondFmt（条件格式） |
| FieldRef | 字段引用，格式为 `表名[字段名]`。可能包含后缀：`.层次结构.级别`（层次结构级别）、`(聚合函数)`（聚合字段） |
| FieldType | 字段类型：Column（列）、Measure（度量值）、Aggregation（聚合）、HierarchyLevel（层次结构级别）、VisualCalculation（视觉计算） |
| Detail | 附加信息：筛选器的类型、条件格式的对象路径 |

### 未使用字段

| 字段 | 说明 |
|------|------|
| Table | 表名（来自 TMDL） |
| FieldType | Column（列）或 Measure（度量值） |
| FieldName | 字段名称 |
| FieldRef | 完整引用格式：`表名[字段名]` |
| Status | Unused（未使用） |
| Note | 备注（如 "Auto-generated LocalDateTable"） |

### 未使用表

| 字段 | 说明 |
|------|------|
| Table | 表名 |
| TotalColumns | TMDL 中定义的列数 |
| TotalMeasures | TMDL 中定义的度量值数 |
| UsedColumns | 报表中引用的列数 |
| UsedMeasures | 报表中引用的度量值数 |
| Status | Unused（完全未使用）/ Partially Used（部分使用）/ Fully Used（全部使用） |
| Note | 备注 |

## 字段引用格式

| 字段类型 | 格式 | 示例 |
|---------|------|------|
| 列 | `表名[列名]` | `view_t_fssc_kpi_report_display[组别]` |
| 度量值 | `表名[度量值名]` | `view_t_fssc_kpi_report_display[提交单量]` |
| 聚合 | `表名[列名] (函数)` | `view_t_fssc_kpi_report_display[单号拼接] (CountNonNull)` |
| 层次结构级别 | `表名[列名].层次结构.级别` | `view_t_fssc_kpi_report_display[单据提交时间(原始)].日期层次结构.年` |
| 视觉计算 | `[名称]` | `[RunningTotal]` |

## 系统要求

- **PowerShell 3.0+**（Windows 8 / Windows Server 2012 及以上版本内置）
- **PBIP 格式项目** — Power BI Project 文件（.pbip），以 PBIP 格式保存

无需 Python、无需第三方模块、无需 Power BI Desktop。

## PBIP 项目目录结构

工具识别的标准 PBIP 文件夹布局：

```
YourProject.pbip/
├── YourProject.pbip                    # 项目元数据（JSON）
├── YourProject.Report/
│   └── definition/
│       ├── report.json                 # 报表级筛选器
│       └── pages/
│           ├── pages.json              # 页面顺序
│           └── {guid}/
│               ├── page.json            # 页面显示名称 + 页面级筛选器
│               └── visuals/{guid}/
│                   └── visual.json     # 视觉对象字段引用 + 筛选器
└── YourProject.SemanticModel/
    └── definition/
        └── tables/*.tmdl              # 列和度量值定义
```

## 已知限制

- **EXTERNALMEASURE**：定义为 `EXTERNALMEASURE` 的度量值（DirectQuery 到 Analysis Services）在 PBIP 文件中无内部字段依赖可见，实际依赖存在于外部 AS 模型中，无法在此扫描
- **计算组**：未专门处理，计算组项内的字段可能无法完整捕获
- **报表级度量值**：仅在 report.json 中定义（不在 SemanticModel 中）的度量值不纳入未使用分析
- **LocalDateTable**：自动生成的日期表会被识别并标记，但其层次结构引用可能无法完全捕获，删除前请人工确认

## 许可证

[MIT License](LICENSE)
