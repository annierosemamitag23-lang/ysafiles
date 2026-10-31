param(
    [string]$ModelPath,
    [string]$MongoExportPath
)

$ErrorActionPreference = "Continue"
$FailureCount = 0
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Project = Join-Path $Root "AgapAI"
$Api = Join-Path $Project "agapai\api"
$Dashboard = Join-Path $Project "agapai\dashboard"
$Venv = Join-Path $Project "agapai\.venv"
$Python = Join-Path $Venv "Scripts\python.exe"
$Frozen = Join-Path $Root "restore-kit\requirements-frozen.txt"
$ModelTarget = Join-Path $Api "agapai_api\models\agapai_multitask_xlmr\encoder\model.safetensors"
$Heads = Join-Path $Api "agapai_api\models\agapai_multitask_xlmr\heads.pt"
$ExpectedModelSize = [int64]1112197096
$ExpectedModelSha256 = "E8B863AB898B405FA5E7AD25B39177402413DA173FF15EECCEEB6D91500433BF"
$PyVersion = ""

function Report-Step {
    param([string]$Name, [bool]$Passed, [string]$Detail = "")
    if ($Passed) {
        Write-Host "PASS $Name $Detail"
    } else {
        Write-Host "FAIL $Name $Detail" -ForegroundColor Red
        $script:FailureCount++
    }
}

function Confirm-LargeDownload {
    param([string]$Name, [string]$Estimate)
    $answer = Read-Host "$Name may download/install $Estimate. Continue? [y/N]"
    return $answer -match "^(?i)y(es)?$"
}

function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

Write-Host "AgapAI restore kit: $Root"

$PyLauncher = Get-Command py.exe -ErrorAction SilentlyContinue
if ($null -eq $PyLauncher) {
    Report-Step "Python 3.11" $false "Install Python 3.11 and its py launcher, then rerun. Captured environment: Python 3.11.0."
} else {
    $PyVersion = (& py -3.11 --version 2>&1 | Out-String).Trim()
    Report-Step "Python 3.11" ($PyVersion -match "^Python 3\.11\.") $PyVersion
}

$NodeCommand = Get-Command node -ErrorAction SilentlyContinue
if ($null -eq $NodeCommand) {
    Report-Step "Node 24" $false "Install Node.js 24."
} else {
    $NodeVersion = (& node --version 2>&1 | Out-String).Trim()
    Report-Step "Node 24" ($NodeVersion -match "^v?24\.") $NodeVersion
}
$NpmCommand = Get-Command npm -ErrorAction SilentlyContinue
if ($null -eq $NpmCommand) {
    Report-Step "npm" $false "Install npm with Node.js 24."
} else {
    $NpmVersion = (& npm --version 2>&1 | Out-String).Trim()
    Report-Step "npm" ($LASTEXITCODE -eq 0) $NpmVersion
}
$GitCommand = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $GitCommand) {
    Report-Step "Git" $false "Install Git for Windows."
    Report-Step "Git LFS" $false "Install Git LFS."
} else {
    $GitVersion = (& git --version 2>&1 | Out-String).Trim()
    Report-Step "Git" ($LASTEXITCODE -eq 0) $GitVersion
    $LfsVersion = (& git lfs version 2>&1 | Out-String).Trim()
    Report-Step "Git LFS" ($LASTEXITCODE -eq 0) $LfsVersion
}

if ($null -eq $GitCommand) {
    $LfsPullPassed = $false
} else {
    Push-Location $Root
    try {
        & git lfs pull
        $LfsPullPassed = ($LASTEXITCODE -eq 0)
    } finally {
        Pop-Location
    }
}
Report-Step "Git LFS pull (heads.pt)" $LfsPullPassed

if (Test-Path -LiteralPath $Heads) {
    $HeadReader = [System.IO.StreamReader]::new($Heads)
    try { $HeadFirstLine = $HeadReader.ReadLine() } finally { $HeadReader.Dispose() }
    Report-Step "heads.pt is a real LFS file" ($HeadFirstLine -ne "version https://git-lfs.github.com/spec/v1")
} else {
    Report-Step "heads.pt is a real LFS file" $false "Expected next to meta.json, one level above encoder."
}

if (-not (Test-Path -LiteralPath $ModelTarget)) {
    if ([string]::IsNullOrWhiteSpace($ModelPath)) {
        $ModelPath = Read-Host "Enter the path to model.safetensors from Drive or USB"
    }
    if (-not [string]::IsNullOrWhiteSpace($ModelPath) -and (Test-Path -LiteralPath $ModelPath -PathType Leaf)) {
        $SourceItem = Get-Item -LiteralPath $ModelPath
        $SourceHash = Get-FileSha256 $ModelPath
        if ($SourceItem.Length -eq $ExpectedModelSize -and $SourceHash -eq $ExpectedModelSha256) {
            Copy-Item -LiteralPath $ModelPath -Destination $ModelTarget
        }
    }
}
if (Test-Path -LiteralPath $ModelTarget -PathType Leaf) {
    $ModelItem = Get-Item -LiteralPath $ModelTarget
    $ModelHash = Get-FileSha256 $ModelTarget
    Report-Step "model.safetensors size and SHA256" ($ModelItem.Length -eq $ExpectedModelSize -and $ModelHash -eq $ExpectedModelSha256) "bytes=$($ModelItem.Length)"
} else {
    Report-Step "model.safetensors size and SHA256" $false "Model file not found or source verification failed; no existing target was overwritten."
}

if (-not (Test-Path -LiteralPath $Python)) {
    if ($PyVersion -match "^Python 3\.11\.") {
        & py -3.11 -m venv $Venv
        Report-Step "Create project virtual environment" ($LASTEXITCODE -eq 0)
    } else {
        Report-Step "Create project virtual environment" $false "Python 3.11 is required."
    }
} else {
    Report-Step "Project virtual environment" $true "already exists; kept in place."
}

if ((Test-Path -LiteralPath $Python) -and (Test-Path -LiteralPath $Frozen)) {
    $FrozenLines = Get-Content -LiteralPath $Frozen
    $DeepfaceReplaced = $false
    $OpenCvReplaced = $false
    $PortableLines = foreach ($Line in $FrozenLines) {
        if ($Line -match "^deepface @ file:///.*deepface-0\.0\.95-py3-none-any\.whl$") {
            $DeepfaceReplaced = $true
            "deepface==0.0.95"
        } elseif ($Line -match "^opencv-python @ file:///.*opencv_python-4\.12\.0\.88-cp37-abi3-win_amd64\.whl$") {
            $OpenCvReplaced = $true
            "opencv-python==4.12.0.88"
        } else {
            $Line
        }
    }
    if (-not ($DeepfaceReplaced -and $OpenCvReplaced)) {
        Report-Step "Prepare frozen requirements" $false "Unexpected local wheel references; inspect restore-kit\requirements-frozen.txt."
    } elseif (Confirm-LargeDownload "Python dependencies from the captured 302-package environment" "several GB (torch, TensorFlow, JAX and related packages)") {
        $InstallRequirements = Join-Path $env:TEMP ("agapai-requirements-" + $PID + ".txt")
        [System.IO.File]::WriteAllLines($InstallRequirements, [string[]]$PortableLines, [System.Text.UTF8Encoding]::new($false))
        & $Python -m pip install -r $InstallRequirements
        Report-Step "Install captured Python requirements" ($LASTEXITCODE -eq 0)
    } else {
        Report-Step "Install captured Python requirements" $false "Approval declined; rerun when ready."
    }
} else {
    Report-Step "Install captured Python requirements" $false "Virtual environment or restore-kit\requirements-frozen.txt is missing."
}

if ((Test-Path -LiteralPath $Python) -and (Test-Path -LiteralPath (Join-Path $Dashboard "package-lock.json"))) {
    $NodeModules = Join-Path $Dashboard "node_modules"
    if (Test-Path -LiteralPath $NodeModules) {
        Report-Step "Dashboard npm ci" $true "node_modules already exists; skipped to preserve files."
    } else {
        Push-Location $Dashboard
        try {
            & npm ci
            $NpmCiPassed = ($LASTEXITCODE -eq 0)
        } finally {
            Pop-Location
        }
        Report-Step "Dashboard npm ci" $NpmCiPassed
    }
} else {
    Report-Step "Dashboard npm ci" $false "Node 24, venv, or package-lock.json is missing."
}

if (Test-Path -LiteralPath $Python) {
    & $Python -m nltk.downloader wordnet omw-1.4
    Report-Step "NLTK wordnet and omw-1.4" ($LASTEXITCODE -eq 0)

    $Hf = Join-Path (Split-Path -Parent $Python) "hf.exe"
    if (-not (Test-Path -LiteralPath $Hf)) {
        Report-Step "Hugging Face model cache" $false "hf.exe not found; complete Python dependency installation first."
    } else {
        $HfModels = @(
            @{ Repo = "ljvmiranda921/tl_calamancy_md"; Revision = "0.2.0"; Estimate = "model files; size varies" },
            @{ Repo = "facebook/nllb-200-distilled-600M"; Revision = "f8d333a098d19b4fd9a8b18f94170487ad3f821d"; Estimate = "about 2.31 GiB" },
            @{ Repo = "facebook/bart-large-mnli"; Revision = "d7645e127eaf1aefc7862fd59a17a5aa8558b8ce"; Estimate = "about 1.52 GiB" }
        )
        foreach ($HfModel in $HfModels) {
            if (Confirm-LargeDownload "Hugging Face $($HfModel.Repo) at $($HfModel.Revision)" $HfModel.Estimate) {
                & $Hf download $HfModel.Repo --revision $HfModel.Revision
                Report-Step "Hugging Face $($HfModel.Repo)" ($LASTEXITCODE -eq 0)
            } else {
                Report-Step "Hugging Face $($HfModel.Repo)" $false "Approval declined; first runtime use may need internet."
            }
        }
    }
} else {
    Report-Step "NLTK and Hugging Face assets" $false "Python virtual environment is missing."
}

$MongoService = Get-Service -Name "MongoDB" -ErrorAction SilentlyContinue
$MongoD = Get-Command mongod -ErrorAction SilentlyContinue
if ($null -eq $MongoD) {
    Report-Step "MongoDB version 6.0+" $false "Install MongoDB Server 6.0 or newer."
} else {
    $MongoVersionText = (& mongod --version 2>&1 | Out-String)
    $MongoVersionMatch = [regex]::Match($MongoVersionText, "db version v(\d+)\.(\d+)")
    $MongoVersionPassed = $false
    if ($MongoVersionMatch.Success) {
        $MongoMajor = [int]$MongoVersionMatch.Groups[1].Value
        $MongoMinor = [int]$MongoVersionMatch.Groups[2].Value
        $MongoVersionPassed = ($MongoMajor -gt 6 -or ($MongoMajor -eq 6 -and $MongoMinor -ge 0))
    }
    Report-Step "MongoDB version 6.0+" $MongoVersionPassed
}
if ($null -eq $MongoService) {
    Report-Step "MongoDB service" $false "Install MongoDB 6.0 or newer and start its service."
} else {
    if ($MongoService.Status -ne "Running") {
        try {
            Start-Service -Name $MongoService.Name -ErrorAction Stop
            $MongoService = Get-Service -Name $MongoService.Name
        } catch {
            $MongoService = Get-Service -Name $MongoService.Name
        }
    }
    Report-Step "MongoDB service" ($MongoService.Status -eq "Running") "service=$($MongoService.Name)"
}

if ([string]::IsNullOrWhiteSpace($MongoExportPath)) {
    $MongoExportPath = Read-Host "Enter the Drive/USB folder containing manifest.json and AgapAI_Database_Final"
}
if ((Test-Path -LiteralPath (Join-Path $MongoExportPath "manifest.json")) -and (Test-Path -LiteralPath $Python)) {
    & $Python (Join-Path $Root "restore-kit\import_mongo.py") --export $MongoExportPath
    Report-Step "Import MongoDB export" ($LASTEXITCODE -eq 0)
} else {
    Report-Step "Import MongoDB export" $false "Export folder, manifest.json, or project Python is missing."
}

Write-Host ""
Write-Host "Start the API from AgapAI\agapai\api: ..\.venv\Scripts\python.exe -m uvicorn agapai_api.app:app --reload --host 127.0.0.1 --port 8000"
Write-Host "Start the dashboard from AgapAI\agapai\dashboard: npm run dev -- --host 127.0.0.1 --port 5173 --strictPort"
Write-Host "Set required environment variables locally before starting the API; see RESTORE.md."
if ($FailureCount -gt 0) {
    Write-Host "Restore finished with $FailureCount failed or declined step(s)." -ForegroundColor Red
    exit 1
}
Write-Host "Restore steps passed."
