param(
    [string]$Path,

    [ValidateSet("csv","html","both")]
    [string]$Output = "both"
)

if (-not $Path) { $Path = $PSScriptRoot }
if (-not $Path) { $Path = (Get-Location).Path }

$ErrorActionPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Info { param([string]$Msg) Write-Host "[INFO] $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "  -> $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "  [!] $Msg" -ForegroundColor Yellow }

function Read-JsonFile {
    param([string]$F)
    if (Test-Path $F) { return Get-Content -Path $F -Raw -Encoding UTF8 | ConvertFrom-Json }
    return $null
}

function Discover-PBIPProject {
    param([string]$RootDir)
    $root = (Resolve-Path $RootDir).Path
    $pbipFiles = Get-ChildItem -Path $root -Filter "*.pbip" -File
    if ($pbipFiles.Count -eq 0) {
        Write-Host "Error: No .pbip file found." -ForegroundColor Red
        exit 1
    }
    $pbipFile = $pbipFiles[0]
    $pbipData = Read-JsonFile $pbipFile.FullName
    $reportRelPath = $null
    foreach ($art in $pbipData.artifacts) {
        if ($art.report) { $reportRelPath = $art.report.path; break }
    }
    if (-not $reportRelPath) {
        $rd = Get-ChildItem -Path $root -Directory | Where-Object { $_.Name -like "*.Report" }
        if ($rd.Count -gt 0) { $reportRelPath = $rd[0].Name }
        else { Write-Host "Error: No Report directory found." -ForegroundColor Red; exit 1 }
    }
    $reportDir = Join-Path $root $reportRelPath
    if (-not (Test-Path $reportDir -PathType Container)) {
        Write-Host "Error: Report dir not found: $reportRelPath" -ForegroundColor Red; exit 1
    }
    $projectName = $pbipFile.BaseName
    $smDir = Join-Path $root "$projectName.SemanticModel"
    if (-not (Test-Path $smDir -PathType Container)) {
        $sd = Get-ChildItem -Path $root -Directory | Where-Object { $_.Name -like "*.SemanticModel" }
        if ($sd.Count -gt 0) { $smDir = $sd[0].FullName }
        else { $smDir = $null; Write-Warn "SemanticModel not found, skipping TMDL scan" }
    }
    return @{ RootDir=$root; PbipFile=$pbipFile; ReportDir=$reportDir; SmDir=$smDir; ProjectName=$projectName }
}

function Get-EntityProperty {
    param([object]$Obj)
    if (-not $Obj) { return $null }
    foreach ($key in @("Column","Measure")) {
        if ($Obj.PSObject.Properties[$key]) {
            $item = $Obj.$key
            $entity = ""; $prop = ""
            if ($item.Expression.SourceRef.Entity) { $entity = $item.Expression.SourceRef.Entity }
            if ($item.Property) { $prop = $item.Property }
            if ($entity -and $prop) { return "$entity`[$prop`]" }
        }
    }
    if ($Obj.PSObject.Properties["Aggregation"]) {
        $agg = $Obj.Aggregation
        $entity = ""; $prop = ""
        if ($agg.Expression.Column.Expression.SourceRef.Entity) { $entity = $agg.Expression.Column.Expression.SourceRef.Entity }
        if ($agg.Expression.Column.Property) { $prop = $agg.Expression.Column.Property }
        $fc = $agg.Function
        $fm = @{0="None";1="Sum";2="Average";3="Min";4="Max";5="CountNonNull";6="Count";7="StdDev";8="Variance";9="Median";12="DistinctCount"}
        $fn = $fm[[int]$fc]
        if (-not $fn) { $fn = "Func_$fc" }
        if ($entity -and $prop) { return "$entity`[$prop`] ($fn)" }
    }
    if ($Obj.PSObject.Properties["HierarchyLevel"]) {
        $hl = $Obj.HierarchyLevel
        $entity = ""; $prop = ""; $hierName = ""; $level = ""
        $he = $hl.Expression.Hierarchy
        if ($he) {
            $hierName = $he.Hierarchy
            $inner = $he.Expression
            if ($inner.PropertyVariationSource) {
                $pvs = $inner.PropertyVariationSource
                if ($pvs.Expression.SourceRef.Entity) { $entity = $pvs.Expression.SourceRef.Entity }
                if ($pvs.Property) { $prop = $pvs.Property }
            }
        }
        $level = $hl.Level
        if ($entity -and $prop) { return "$entity`[$prop`].$hierName.$level" }
    }
    return $null
}

function Get-FieldsFromQueryState {
    param([object]$QS)
    $fields = @()
    if (-not $QS) { return $fields }
    foreach ($pn in $QS.PSObject.Properties.Name) {
        $rd = $QS.$pn
        if (-not $rd.projections) { continue }
        foreach ($proj in $rd.projections) {
            $fo = $proj.field
            $fr = Get-EntityProperty $fo
            $ft = ""
            if ($fo.PSObject.Properties.Name.Count -gt 0) { $ft = ($fo.PSObject.Properties.Name | Select-Object -First 1) }
            if ($fr) { $fields += @{ Role=$pn; FieldRef=$fr; FieldType=$ft } }
            if ($fo.PSObject.Properties["NativeVisualCalculation"]) {
                $nvc = $fo.NativeVisualCalculation
                $dax = $nvc.Expression
                if ($dax) {
                    $mx = [regex]::Matches($dax, '\[([^\]]+)\]')
                    foreach ($m in $mx) { $fields += @{ Role=$pn; FieldRef="[$($m.Groups[1].Value)]"; FieldType="VisualCalculation" } }
                }
            }
        }
    }
    return $fields
}

function Get-FieldsFromFilters {
    param([object]$FC)
    $fields = @()
    if (-not $FC -or -not $FC.filters) { return $fields }
    foreach ($f in $FC.filters) {
        $fo = $f.field
        $fr = Get-EntityProperty $fo
        $ft = ""
        if ($fo.PSObject.Properties.Name.Count -gt 0) { $ft = ($fo.PSObject.Properties.Name | Select-Object -First 1) }
        $fType = ""
        if ($f.type) { $fType = $f.type }
        if ($fr) { $fields += @{ FieldRef=$fr; FieldType=$ft; FilterType=$fType } }
    }
    return $fields
}

function Get-FieldsFromObjects {
    param([object]$Obj)
    $fields = @()
    if (-not $Obj) { return $fields }
    function Recurse($node, $path) {
        if (-not $node -or $node -isnot [PSObject]) { return }
        foreach ($k in $node.PSObject.Properties.Name) {
            $v = $node.$k
            if ($k -eq "ScopedEval" -and $v.PSObject.Properties["Aggregation"]) {
                $fr = Get-EntityProperty $v.Aggregation
                if ($fr) { $fields += @{ FieldRef=$fr; FieldType="ConditionalFormat"; Path=$path } }
            }
            if ($v -is [PSObject]) { Recurse $v "$path > $k" }
        }
    }
    Recurse $Obj ""
    return $fields
}

function Get-VisualName {
    param([object]$VD)
    $vis = $VD.visual
    if ($vis -and $vis.visualContainerObjects -and $vis.visualContainerObjects.title) {
        foreach ($t in $vis.visualContainerObjects.title) {
            $val = $t.properties.text.expr.Literal.Value
            if ($val) { return $val.Trim("'") }
        }
    }
    return $VD.name
}

function Test-IsSlicer { param([string]$VT) return ($VT -like "*slicer*") -or ($VT -like "*PowerSlicer*") }

function Parse-TMDLFiles {
    param([string]$TDir)
    $tables = @{}
    if (-not $TDir -or -not (Test-Path $TDir)) { return $tables }
    foreach ($tmdl in (Get-ChildItem -Path $TDir -Filter "*.tmdl" -File)) {
        $tn = $tmdl.BaseName
        $content = Get-Content -Path $tmdl.FullName -Raw -Encoding UTF8
        $cols = @(); $measures = @{}
        $mm = [regex]::Matches($content, '(?m)^\tmeasure\s+(.+?)\s*=\s*(.+?)$')
        foreach ($m in $mm) { $measures[$m.Groups[1].Value.Trim()] = $m.Groups[2].Value.Trim() }
        $cm = [regex]::Matches($content, '(?m)^\tcolumn\s+(.+?)$')
        foreach ($m in $cm) { $cols += $m.Groups[1].Value.Trim() }
        $tables[$tn] = @{ Columns=$cols; Measures=$measures }
    }
    return $tables
}

function Scan-Report {
    param($ProjectInfo)
    $results = @()
    $rd = $ProjectInfo.ReportDir

    $rj = Join-Path $rd "definition\report.json"
    $rData = Read-JsonFile $rj
    if ($rData -and $rData.filterConfig) {
        foreach ($ff in (Get-FieldsFromFilters $rData.filterConfig)) {
            $results += [PSCustomObject]@{ Page="[Report]"; VName="[ReportFilter]"; VType="ReportFilter"; Source="Report Filter"; Role="filter"; FieldRef=$ff.FieldRef; FieldType=$ff.FieldType; Detail=$ff.FilterType }
        }
    }

    $pagesDir = Join-Path $rd "definition\pages"
    if (-not (Test-Path $pagesDir)) { return $results }
    foreach ($pf in (Get-ChildItem -Path $pagesDir -Directory | Sort-Object Name)) {
        $pData = Read-JsonFile (Join-Path $pf.FullName "page.json")
        $pDN = $pf.Name
        if ($pData.displayName) { $pDN = $pData.displayName }

        if ($pData -and $pData.filterConfig) {
            foreach ($ff in (Get-FieldsFromFilters $pData.filterConfig)) {
                $results += [PSCustomObject]@{ Page=$pDN; VName="[PageFilter]"; VType="PageFilter"; Source="Page Filter"; Role="filter"; FieldRef=$ff.FieldRef; FieldType=$ff.FieldType; Detail=$ff.FilterType }
            }
        }

        $visDir = Join-Path $pf.FullName "visuals"
        if (-not (Test-Path $visDir)) { continue }
        foreach ($vf in (Get-ChildItem -Path $visDir -Directory | Sort-Object Name)) {
            $vData = Read-JsonFile (Join-Path $vf.FullName "visual.json")
            if (-not $vData) { continue }
            $vis = $vData.visual
            $vType = "Unknown"
            if ($vis.visualType) { $vType = $vis.visualType }
            $vName = Get-VisualName $vData
            $typeLabel = $vType
            if (Test-IsSlicer $vType) { $typeLabel = "Slicer" }

            $qs = $null
            if ($vis -and $vis.query -and $vis.query.queryState) { $qs = $vis.query.queryState }
            $roleMap = @{ Category="Axis"; Y="Value(Y)"; Series="Legend"; Rows="Rows"; Values="Values"; categories="Slicer Field"; Tooltip="Tooltip"; Category2="Axis2" }
            foreach ($qf in (Get-FieldsFromQueryState $qs)) {
                $rDisp = $qf.Role; if ($roleMap[$qf.Role]) { $rDisp = $roleMap[$qf.Role] }
                $src = "Visual Field"
                if (Test-IsSlicer $vType) { $src = "Slicer Field" }
                $results += [PSCustomObject]@{ Page=$pDN; VName=$vName; VType=$typeLabel; Source=$src; Role=$rDisp; FieldRef=$qf.FieldRef; FieldType=$qf.FieldType; Detail="" }
            }

            $vFC = $vData.filterConfig
            foreach ($ff in (Get-FieldsFromFilters $vFC)) {
                $results += [PSCustomObject]@{ Page=$pDN; VName=$vName; VType=$typeLabel; Source="Visual Filter"; Role="filter"; FieldRef=$ff.FieldRef; FieldType=$ff.FieldType; Detail=$ff.FilterType }
            }

            $objs = $null; if ($vis.objects) { $objs = $vis.objects }
            foreach ($cf in (Get-FieldsFromObjects $objs)) {
                $results += [PSCustomObject]@{ Page=$pDN; VName=$vName; VType=$typeLabel; Source="Conditional Format"; Role="CondFmt"; FieldRef=$cf.FieldRef; FieldType=$cf.FieldType; Detail=$cf.Path }
            }
        }
    }
    return $results
}

function Scan-SemanticModel {
    param($ProjectInfo)
    $md = @()
    if (-not $ProjectInfo.SmDir) { return $md }
    $tDir = Join-Path $ProjectInfo.SmDir "definition\tables"
    $tables = Parse-TMDLFiles $tDir
    foreach ($tn in ($tables.Keys | Sort-Object)) {
        $td = $tables[$tn]
        foreach ($mn in ($td.Measures.Keys | Sort-Object)) {
            $expr = $td.Measures[$mn]
            $deps = @()
            $tc = [regex]::Matches($expr, "'([^']+)'\[([^\]]+)\]")
            foreach ($m in $tc) { $deps += "$($m.Groups[1].Value)[$($m.Groups[2].Value)]" }
            $cleaned = [regex]::Replace($expr, 'EXTERNALMEASURE\([^)]*\)', '')
            $mx = [regex]::Matches($cleaned, '\[([^\]]+)\]')
            foreach ($m in $mx) { $deps += "[$($m.Groups[1].Value)]" }
            $ds = ""
            if ($deps.Count -gt 0) { $ds = $deps -join "; " } else { $ds = "(EXTERNALMEASURE - no internal deps)" }
            $md += [PSCustomObject]@{ Table=$tn; MeasureName=$mn; MeasureRef="$tn[$mn]"; Expression=$expr; Dependencies=$ds }
        }
    }
    return $md
}

function Build-Report {
    param($ReportResults, $MeasureDeps)
    $s1 = $ReportResults | Select-Object Page, VName, VType, Source, Role, FieldRef, FieldType, Detail
    $s2 = $MeasureDeps

    $mMap = @{}
    foreach ($m in $MeasureDeps) { $mMap[$m.MeasureRef] = $m }
    $s3 = @()
    foreach ($r in $ReportResults) {
        if ($r.FieldType -eq "Measure") {
            if ($mMap[$r.FieldRef]) {
                $md = $mMap[$r.FieldRef]
                foreach ($dep in $md.Dependencies -split "; ") {
                    $s3 += [PSCustomObject]@{ Page=$r.Page; VName=$r.VName; VType=$r.VType; Source=$r.Source; Role=$r.Role; Measure=$r.FieldRef; DepField=$dep.Trim(); DepType="Measure Indirect" }
                }
            } else {
                $s3 += [PSCustomObject]@{ Page=$r.Page; VName=$r.VName; VType=$r.VType; Source=$r.Source; Role=$r.Role; Measure=$r.FieldRef; DepField="(EXTERNALMEASURE)"; DepType="External Measure" }
            }
        }
        if ($r.FieldType -eq "VisualCalculation") {
            $s3 += [PSCustomObject]@{ Page=$r.Page; VName=$r.VName; VType=$r.VType; Source=$r.Source; Role=$r.Role; Measure=$r.FieldRef; DepField="(VisualCalc)"; DepType="VisualCalculation" }
        }
    }

    $pg = $ReportResults | Group-Object Page, Source | Sort-Object Name
    $s4 = @()
    foreach ($g in $pg) {
        $parts = $g.Name -split ", "; $page=$parts[0]; $src=$parts[1]
        $uf = $g.Group | Select-Object -ExpandProperty FieldRef -Unique
        $s4 += [PSCustomObject]@{ Page=$page; SourceType=$src; FieldCount=$uf.Count; FieldList=($uf|Sort-Object) -join "; " }
    }

    $fg = $ReportResults | Where-Object { $_.FieldRef -match '^[^\[]+\[' } | Select-Object FieldRef | Group-Object FieldRef | Sort-Object Count -Descending
    $s5 = @()
    foreach ($g in $fg) {
        $tn = ""
        if ($g.Name -match '^([^\[]+)') { $tn = $Matches[1] }
        $s5 += [PSCustomObject]@{ Table=$tn; FieldRef=$g.Name; RefCount=$g.Count }
    }

    return @{
        "Visual Fields Detail" = $s1
        "Measure Dependencies" = $s2
        "Measure Expanded Deps" = $s3
        "Fields by Page" = $s4
        "Field Usage Frequency" = $s5
    }
}

function Export-ReportCsv {
    param($ReportData, [string]$OutputDir)
    foreach ($sn in $ReportData.Keys) {
        $rows = $ReportData[$sn]
        if (-not $rows -or $rows.Count -eq 0) { continue }
        $safeName = $sn -replace '[<>:"/\\|?*]', '_' -replace '\s+', '_'
        $csvPath = Join-Path $OutputDir "PBIP_$safeName.csv"
        $sb = [System.Text.StringBuilder]::new()
        $props = $rows[0].PSObject.Properties.Name
        [void]$sb.AppendLine(($props -join ","))
        foreach ($row in $rows) {
            $vals = foreach ($p in $props) { $v = "$($row.$p)"; if ($v -is [string]) { $v = $v.Replace('"','""') }; "`"$v`"" }
            [void]$sb.AppendLine($vals -join ",")
        }
        $bom = [byte[]]@(0xEF,0xBB,0xBF)
        $content = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
        $bytes = New-Object byte[] ($bom.Length + $content.Length)
        [System.Array]::Copy($bom, $bytes, $bom.Length)
        [System.Array]::Copy($content, 0, $bytes, $bom.Length, $content.Length)
        [System.IO.File]::WriteAllBytes($csvPath, $bytes)
        Write-Ok "CSV: $csvPath ($($rows.Count) rows)"
    }
}

function Export-ReportHtml {
    param($ReportData, [string]$OutputDir)
    $htmlPath = Join-Path $OutputDir "PBIP_Field_Dependency_Report.html"
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<!DOCTYPE html><html lang="zh-CN"><head><meta charset="UTF-8"><title>PBIP Field Dependency Report</title>')
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine('body{font-family:Arial,"Microsoft YaHei",sans-serif;margin:20px;background:#f5f5f5}')
    [void]$sb.AppendLine('h1{color:#1a1a2e;border-bottom:3px solid #16213e;padding-bottom:10px}')
    [void]$sb.AppendLine('h2{color:#16213e;margin-top:30px;cursor:pointer;padding:8px 12px;background:#e8eaf6;border-radius:6px;user-select:none}')
    [void]$sb.AppendLine('h2:hover{background:#c5cae9}')
    [void]$sb.AppendLine('h2::before{content:"[+] ";font-size:1em}')
    [void]$sb.AppendLine('h2.open::before{content:"[-] "}')
    [void]$sb.AppendLine('.section{display:none;margin:10px 0 20px 0}')
    [void]$sb.AppendLine('.section.open{display:block}')
    [void]$sb.AppendLine('table{border-collapse:collapse;width:100%;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,0.1);border-radius:6px;overflow:hidden;font-size:13px}')
    [void]$sb.AppendLine('th{background:#1a1a2e;color:#fff;padding:10px 12px;text-align:left;position:sticky;top:0}')
    [void]$sb.AppendLine('td{padding:8px 12px;border-bottom:1px solid #e0e0e0}')
    [void]$sb.AppendLine('tr:nth-child(even){background:#f7f9fc}')
    [void]$sb.AppendLine('tr:hover{background:#e3f2fd}')
    [void]$sb.AppendLine('.summary{display:flex;flex-wrap:wrap;gap:12px;margin:20px 0}')
    [void]$sb.AppendLine('.card{background:#fff;padding:16px 20px;border-radius:8px;box-shadow:0 1px 3px rgba(0,0,0,0.1);min-width:150px}')
    [void]$sb.AppendLine('.card .num{font-size:28px;font-weight:bold;color:#16213e}')
    [void]$sb.AppendLine('.card .label{font-size:12px;color:#666;margin-top:4px}')
    [void]$sb.AppendLine('.filter-bar{margin:10px 0;padding:8px;background:#fff;border-radius:6px;box-shadow:0 1px 2px rgba(0,0,0,0.08)}')
    [void]$sb.AppendLine('.filter-bar input{padding:6px 10px;border:1px solid #ccc;border-radius:4px;width:250px;font-size:13px}')
    [void]$sb.AppendLine('</style></head><body>')
    [void]$sb.AppendLine('<h1>PBIP Field Dependency Report</h1>')
    [void]$sb.AppendLine('<div class="summary">')
    foreach ($sn in $ReportData.Keys) {
        $cnt = $ReportData[$sn].Count
        [void]$sb.AppendLine("<div class=`"card`"><div class=`"num`">$cnt</div><div class=`"label`">$sn</div></div>")
    }
    [void]$sb.AppendLine('</div>')
    $si = 0
    foreach ($sn in $ReportData.Keys) {
         $rows = $ReportData[$sn]
        [void]$sb.AppendLine("<h2 id=`"h_$si`" onclick=`"toggleSection('$si')`">$sn ($($rows.Count) records)</h2>")
        [void]$sb.AppendLine("<div class=`"section`" id=`"$si`">")
        [void]$sb.AppendLine('<div class="filter-bar"><input type="text" placeholder="Search..." onkeyup="filterTable(this,this.parentElement.nextElementSibling)"></div>')
        if ($rows.Count -eq 0) {
            [void]$sb.AppendLine('<p style="color:#999;padding:20px">(no data)</p>')
        } else {
            [void]$sb.AppendLine('<div style="max-height:600px;overflow:auto"><table><thead><tr>')
            $props = $rows[0].PSObject.Properties.Name
            foreach ($p in $props) { [void]$sb.AppendLine("<th>$([System.Web.HttpUtility]::HtmlEncode($p))</th>") }
            [void]$sb.AppendLine('</tr></thead><tbody>')
            foreach ($row in $rows) {
                [void]$sb.AppendLine('<tr>')
                foreach ($p in $props) {
                    $v = [System.Web.HttpUtility]::HtmlEncode("$($row.$p)")
                    [void]$sb.AppendLine("<td>$v</td>")
                }
                [void]$sb.AppendLine('</tr>')
            }
            [void]$sb.AppendLine('</tbody></table></div>')
        }
        [void]$sb.AppendLine('</div>')
        $si++
    }
    [void]$sb.AppendLine('<script>')
    [void]$sb.AppendLine('function toggleSection(id){var s=document.getElementById(id);var h=document.getElementById("h_"+id);s.classList.toggle("open");h.classList.toggle("open")}')
    [void]$sb.AppendLine('function filterTable(input,container){var f=input.value.toLowerCase();var rows=container.querySelectorAll("tbody tr");for(var i=0;i<rows.length;i++){var t=rows[i].textContent.toLowerCase();rows[i].style.display=t.indexOf(f)>-1?"":"none"}}')
    [void]$sb.AppendLine('</script></body></html>')
    [System.IO.File]::WriteAllText($htmlPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding $true))
    Write-Ok "HTML: $htmlPath"
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor DarkCyan
Write-Host "  PBIP Field Dependency Scanner (PowerShell)" -ForegroundColor DarkCyan
Write-Host "============================================================" -ForegroundColor DarkCyan
Write-Host ""

$project = Discover-PBIPProject -RootDir $Path
Write-Info "Project: $($project.ProjectName)"
Write-Info "Report: $($project.ReportDir)"

Write-Host ""
Write-Info "[1/3] Scanning Report layer..."
$reportResults = Scan-Report -ProjectInfo $project
Write-Ok "$($reportResults.Count) field references found"

Write-Host ""
Write-Info "[2/3] Scanning SemanticModel layer..."
$measureDeps = Scan-SemanticModel -ProjectInfo $project
Write-Ok "$($measureDeps.Count) measures found"

# Parse TMDL for unused field analysis
$tmdlTables = @{}
if ($project.SmDir) {
    $tmdlDir = Join-Path $project.SmDir "definition\tables"
    $tmdlTables = Parse-TMDLFiles $tmdlDir
}
Write-Info "Parsed $($tmdlTables.Count) tables from TMDL"

Write-Host ""
Write-Info "[3/4] Analyzing unused fields..."
# Build set of all used fields (TableName[PropertyName])
$usedFields = @{}
foreach ($r in $reportResults) {
    if ($r.FieldRef -match '^([^\[]+)\[([^\]]+)\]') {
        $usedFields["$($Matches[1])[$($Matches[2])]"] = $true
    }
}
# Also include fields referenced by Measure DAX expressions
foreach ($md in $measureDeps) {
    foreach ($dep in $md.Dependencies -split "; ") {
        $dep = $dep.Trim()
        if ($dep -match '^([^\[]+)\[([^\]]+)\]') {
            $usedFields["$($Matches[1])[$($Matches[2])]"] = $true
        }
    }
}

# Sheet 6: Unused Fields Detail
$unusedFields = @()
# Sheet 7: Unused Tables Summary
$unusedTables = @()
foreach ($tn in ($tmdlTables.Keys | Sort-Object)) {
    $td = $tmdlTables[$tn]
    $isAutoDate = $tn -like "LocalDateTable*"
    $usedColCount = 0; $usedMeaCount = 0
    foreach ($col in $td.Columns) {
        $ref = "$tn[$col]"
        if ($usedFields[$ref]) {
            $usedColCount++
        } else {
            $note = ""
            if ($isAutoDate) { $note = "Auto-generated LocalDateTable" }
            $unusedFields += [PSCustomObject]@{ Table=$tn; FieldType="Column"; FieldName=$col; FieldRef=$ref; Status="Unused"; Note=$note }
        }
    }
    foreach ($mn in ($td.Measures.Keys | Sort-Object)) {
        $ref = "$tn[$mn]"
        if ($usedFields[$ref]) {
            $usedMeaCount++
        } else {
            $note = ""
            if ($isAutoDate) { $note = "Auto-generated LocalDateTable" }
            $unusedFields += [PSCustomObject]@{ Table=$tn; FieldType="Measure"; FieldName=$mn; FieldRef=$ref; Status="Unused"; Note=$note }
        }
    }
    $totalFields = $td.Columns.Count + $td.Measures.Count
    $totalUsed = $usedColCount + $usedMeaCount
    if ($totalUsed -eq 0) {
        $status = "Unused"
    } elseif ($totalUsed -lt $totalFields) {
        $status = "Partially Used"
    } else {
        $status = "Fully Used"
    }
    $tNote = ""
    if ($isAutoDate) { $tNote = "Auto-generated LocalDateTable" }
    $unusedTables += [PSCustomObject]@{ Table=$tn; TotalColumns=$td.Columns.Count; TotalMeasures=$td.Measures.Count; UsedColumns=$usedColCount; UsedMeasures=$usedMeaCount; Status=$status; Note=$tNote }
}
Write-Ok "$($unusedFields.Count) unused fields, $($unusedTables.Count) tables analyzed"

Write-Host ""
Write-Info "[4/4] Building report..."
$reportData = Build-Report -ReportResults $reportResults -MeasureDeps $measureDeps
$reportData["Unused Fields"] = $unusedFields
$reportData["Unused Tables"] = $unusedTables

if ($Output -eq "csv" -or $Output -eq "both") { Export-ReportCsv -ReportData $reportData -OutputDir $project.RootDir }
if ($Output -eq "html" -or $Output -eq "both") { Export-ReportHtml -ReportData $reportData -OutputDir $project.RootDir }

Write-Host ""
Write-Host "============================================================" -ForegroundColor DarkCyan
Write-Host "  Summary" -ForegroundColor DarkCyan
Write-Host "============================================================" -ForegroundColor DarkCyan

$sg = $reportResults | Group-Object Source | Sort-Object Count -Descending
Write-Host ""; Write-Host "--- By Source ---" -ForegroundColor Yellow
foreach ($g in $sg) { Write-Host "  $($g.Name): $($g.Count)" }

$tg = $reportResults | Group-Object FieldType | Sort-Object Count -Descending
Write-Host ""; Write-Host "--- By Field Type ---" -ForegroundColor Yellow
foreach ($g in $tg) { Write-Host "  $($g.Name): $($g.Count)" }

$pg = $reportResults | Group-Object Page | Sort-Object Count -Descending
Write-Host ""; Write-Host "--- By Page ---" -ForegroundColor Yellow
foreach ($g in $pg) { Write-Host "  $($g.Name): $($g.Count)" }

$unusedFieldCount = ($unusedFields | Where-Object { $_.Status -eq "Unused" }).Count
$unusedTableCount = ($unusedTables | Where-Object { $_.Status -eq "Unused" }).Count
$partialTableCount = ($unusedTables | Where-Object { $_.Status -eq "Partially Used" }).Count
Write-Host ""; Write-Host "--- Unused Analysis ---" -ForegroundColor Yellow
Write-Host "  Unused fields: $unusedFieldCount"
Write-Host "  Unused tables: $unusedTableCount"
Write-Host "  Partially used tables: $partialTableCount"

Write-Host ""
Write-Host "Done! Output: $($project.RootDir)" -ForegroundColor Green
Write-Host ""
