param(
  [string]$NDK          = $env:ANDROID_NDK_HOME,
  [string]$OpenSSLVer   = "3.6.1",
  [int]   $ApiLevel     = 24,
  [string]$Msys2Bin     = "C:\tools\msys64\usr\bin",
  [string[]]$ABIs       = @("arm64-v8a","armeabi-v7a","x86_64"),
  [bool]  $BuildShared  = $true,
  [string]$BuildType    = "RelWithDebInfo", # options: RelWithDebInfo, Release, Debug
  [bool]  $Strip        = $false,
  [bool]  $OnlyStrip    = $false  # If true: copy install/<BuildType>-unstripped -> install/<BuildType>-stripped and strip only
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -ge 7) {
  $global:PSNativeCommandUseErrorActionPreference = $false
}

function Now { (Get-Date).ToString("HH:mm:ss") }
function LogInfo($m) { Write-Host "[$(Now)] [INFO] $m" }
function LogOk  ($m) { Write-Host "[$(Now)] [ OK ] $m" -ForegroundColor Green }
function LogFail($m) { Write-Host "[$(Now)] [FAIL] $m" -ForegroundColor Red }

function Require-Path($path, $label) {
  if (-not (Test-Path $path)) { LogFail "$label not found: $path"; throw "$label missing" }
  LogOk "$label found: $path"
}

function Ensure-Dir($path) { New-Item -ItemType Directory -Force -Path $path | Out-Null }

function To-MsysPath([string]$winPath) {
  $p = $winPath -replace "\\","/"
  if ($p -match '^([A-Za-z]):/(.*)$') {
    return "/$($matches[1].ToLower())/$($matches[2])"
  }
  return $p
}

function Write-Utf8NoBomLf([string]$path, [string]$content) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $lf = ($content -replace "`r`n", "`n")
  [System.IO.File]::WriteAllText($path, $lf, $utf8NoBom)
}

function Run-Bash([string]$bashExe, [string]$cmd, [string]$workingDirWin, [string]$logFile) {
  $wd = To-MsysPath $workingDirWin
  LogInfo "Running bash (-c) in: $workingDirWin"
  LogInfo "Log file: $logFile"
  LogInfo "Bash cmd: $cmd"
  Ensure-Dir (Split-Path -Parent $logFile)

  $full = "cd `"$wd`" && set -e && $cmd"

  $oldEAP = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & $bashExe --noprofile --norc -c $full 2>&1 | Tee-Object -FilePath $logFile
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldEAP
  }

  if ($code -ne 0) {
    LogFail "bash step failed with exit code $code (see log: $logFile)"
    throw "bash step failed ($code)"
  }
  LogOk "bash step succeeded"
}

# ---------------------------
# Preconditions
# ---------------------------
LogInfo "=== OpenSSL Android build script (Windows + MSYS2) ==="
LogInfo ("Target ABIs: " + ($ABIs -join ", "))
LogInfo "OpenSSL version: $OpenSSLVer"
LogInfo "Android API level: $ApiLevel"
if (-not $NDK) { throw "ANDROID_NDK_HOME not set and -NDK not provided" }

Require-Path $NDK "NDK root"

$bashExe = Join-Path $Msys2Bin "bash.exe"
$tarExe  = "$env:WINDIR\System32\tar.exe"
Require-Path $bashExe "MSYS2 bash.exe"
Require-Path $tarExe  "Windows tar.exe"

$env:ANDROID_NDK_HOME = $NDK
$env:ANDROID_NDK_ROOT = $NDK
$env:ANDROID_NDK      = $NDK
LogOk "ANDROID_NDK_HOME = $env:ANDROID_NDK_HOME"
LogOk "ANDROID_NDK_ROOT = $env:ANDROID_NDK_ROOT"

$ndkPrebuiltWin = Join-Path $NDK "toolchains\llvm\prebuilt\windows-x86_64"
$ndkBinWin      = Join-Path $ndkPrebuiltWin "bin"
$ndkSysrootWin  = Join-Path $ndkPrebuiltWin "sysroot"
Require-Path $ndkBinWin "NDK toolchain bin"
Require-Path $ndkSysrootWin "NDK sysroot"

$tempLog = Join-Path $env:TEMP "msys2_toolcheck_openssl.log"
Run-Bash $bashExe "command -v perl; perl -v | head -n 2; command -v make; make --version | head -n 1" $PWD.Path $tempLog
LogOk "MSYS2 perl/make check done"

# ---------------------------
# Download + extract
# ---------------------------
$workDir     = Split-Path -Parent $MyInvocation.MyCommand.Definition
$downloads   = Join-Path $workDir "downloads"
$srcRoot     = Join-Path $workDir "src"
$buildRoot   = Join-Path $workDir "build-openssl"
$installRoot = Join-Path $workDir "install"

Ensure-Dir $downloads
Ensure-Dir $srcRoot
Ensure-Dir $buildRoot
Ensure-Dir $installRoot

if ($OnlyStrip) {
  LogInfo "OnlyStrip mode: copy unstripped -> stripped and run strip"

  $srcTypeRoot = Join-Path $installRoot ("$($BuildType)-unstripped")
  if (-not (Test-Path $srcTypeRoot)) {
    LogFail "Source install not found: $srcTypeRoot"
    throw "Source install missing; build unstripped outputs first or provide the folder."
  }

  $dstTypeRoot = Join-Path $installRoot ("$($BuildType)-stripped")
  if (Test-Path $dstTypeRoot) { Remove-Item -Recurse -Force $dstTypeRoot }
  LogInfo "Copying $srcTypeRoot -> $dstTypeRoot"
  Copy-Item -Path $srcTypeRoot -Destination $dstTypeRoot -Recurse -Force

  # locate strip tool in NDK prebuilt or PATH
  $prebuiltDir = Get-ChildItem -Path (Join-Path $NDK "toolchains\llvm\prebuilt") -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
  $hostTag = if ($prebuiltDir) { $prebuiltDir.Name } else { $null }

  $stripTool = $null
  if ($hostTag) {
    $candidate = Join-Path $NDK "toolchains\llvm\prebuilt\$hostTag\bin\llvm-strip"
    $candidateExe = if ($env:OS -eq 'Windows_NT') { $candidate + '.exe' } else { $candidate }
    if (Test-Path $candidateExe) { $stripTool = $candidateExe }
  }
  if (-not $stripTool) {
    $g = Get-Command llvm-strip -ErrorAction SilentlyContinue
    if ($g) { $stripTool = $g.Source }
  }
  if (-not $stripTool) {
    $g2 = Get-Command strip -ErrorAction SilentlyContinue
    if ($g2) { $stripTool = $g2.Source }
  }

  if (-not $stripTool) {
    LogFail "Strip tool not found; aborting."
    throw "Strip tool not found"
  }

  $soFiles = Get-ChildItem -Path $dstTypeRoot -Recurse -Include *.so -File -ErrorAction SilentlyContinue
  $binFiles = @()
  if (Test-Path (Join-Path $dstTypeRoot 'bin')) { $binFiles = Get-ChildItem -Path (Join-Path $dstTypeRoot 'bin') -Recurse -File -ErrorAction SilentlyContinue }

  foreach ($f in @($soFiles + $binFiles)) {
    if ($f -and $f.Length -gt 0) {
      LogInfo "Stripping $($f.FullName)"
      & $stripTool --strip-unneeded $f.FullName
    }
  }

  LogOk "OnlyStrip completed. Stripped output: $dstTypeRoot"
  exit 0
}

$dist     = "openssl-$OpenSSLVer"
$archive  = Join-Path $downloads "$dist.tar.gz"
$url      = "https://www.openssl.org/source/$dist.tar.gz"
$srcDir   = Join-Path $srcRoot $dist

if (-not (Test-Path $archive)) {
  LogInfo "Downloading $url ..."
  Invoke-WebRequest -Uri $url -OutFile $archive
  LogOk "Downloaded: $archive"
} else {
  LogOk "Archive already exists: $archive"
}

if (-not (Test-Path $srcDir)) {
  LogInfo "Extracting source..."
  & $tarExe -xf $archive -C $srcRoot
  if ($LASTEXITCODE -ne 0) { throw "tar extract failed" }
  LogOk "Extracted: $srcDir"
} else {
  LogOk "Source folder already exists: $srcDir"
}

# ---------------------------
# Shims
# 1) gcc/g++ probe shims (für Configure checks)
# 2) *WICHTIG*: endungslose clang/clang++ shims (OpenSSL Makefile nutzt diese Namen!)
# ---------------------------
function Write-BashExecShim([string]$shimWinPath, [string]$execMsysPath, [string]$extraPrefixArgs) {
  $tmpl = @'
#!/usr/bin/env bash
set -e
EXEC="__EXEC__"
EXTRA="__EXTRA__"
# Debug: show what we execute (only once if you want)
# echo "[shim] $0 -> $EXEC $EXTRA $*" >&2
exec "$EXEC" $EXTRA "$@"
'@
  $content = $tmpl.Replace("__EXEC__", $execMsysPath).Replace("__EXTRA__", $extraPrefixArgs)
  Write-Utf8NoBomLf $shimWinPath $content
}

function Write-BashRspShim(
  [string]$outPathWin,
  [string]$execPathWin,
  [string[]]$extraArgs,
  [string]$rspTag
) {
  $outPathMsys = To-MsysPath $outPathWin
  $execMsys    = To-MsysPath $execPathWin

  $extraPrints = ""
  if ($extraArgs -and $extraArgs.Count -gt 0) {
    foreach ($a in $extraArgs) {
      # one arg per line in response file
      $extraPrints += "  printf '%s`n' '$a'`n"
    }
  }

  $content = @"
#!/usr/bin/env bash
set -euo pipefail

EXEC="$execMsys"

# Keep the response file path short to avoid Windows path limits.
RSP="\${PWD}/.\${rspTag}_\$\$.rsp"

cleanup() { rm -f "\$RSP"; }
trap cleanup EXIT

{
$extraPrints  for a in "\$@"; do
    printf '%s\n' "\$a"
  done
} > "\$RSP"

exec "\$EXEC" @"\$RSP"
"@

  Write-Utf8NoBomLf $outPathWin $content
}

function Create-ShimsForAbi(
  [string]$shimDirWin,
  [string]$ndkBinWin,
  [string]$ndkSysrootWin,
  [string]$tripleApi,    # e.g. aarch64-linux-android21
  [string]$tripleBase    # e.g. aarch64-linux-android   (WICHTIG!)
) {
  Ensure-Dir $shimDirWin

  $clangExeWin   = Join-Path $ndkBinWin "clang.exe"
  $clangppExeWin = Join-Path $ndkBinWin "clang++.exe"
  Require-Path $clangExeWin   "NDK clang.exe"
  Require-Path $clangppExeWin "NDK clang++.exe"

  $llvmArWin     = Join-Path $ndkBinWin "llvm-ar.exe"
  $llvmRanlibWin = Join-Path $ndkBinWin "llvm-ranlib.exe"
  Require-Path $llvmArWin     "NDK llvm-ar.exe"
  Require-Path $llvmRanlibWin "NDK llvm-ranlib.exe"

  $clangM   = To-MsysPath $clangExeWin
  $clangppM = To-MsysPath $clangppExeWin
  $sysrootM = To-MsysPath $ndkSysrootWin

  # (A) clang wrappers (werden im Build genutzt)
  Write-BashExecShim (Join-Path $shimDirWin "$tripleApi-clang")    $clangM   "--target=$tripleApi --sysroot=$sysrootM"
  Write-BashExecShim (Join-Path $shimDirWin "$tripleApi-clang++")  $clangppM "--target=$tripleApi --sysroot=$sysrootM"

  # (B) gcc/g++ wrappers (werden von OpenSSL Configure geprüft)
  Write-BashExecShim (Join-Path $shimDirWin "$tripleBase-gcc")     $clangM   "--target=$tripleApi --sysroot=$sysrootM"
  Write-BashExecShim (Join-Path $shimDirWin "$tripleBase-g++")     $clangppM "--target=$tripleApi --sysroot=$sysrootM"

  # (C) optional: ar/ranlib unter den “triple names” (sicherer)
  $llvmArM     = To-MsysPath $llvmArWin
  $llvmRanlibM = To-MsysPath $llvmRanlibWin
  Write-BashExecShim (Join-Path $shimDirWin "$tripleBase-ar")      $llvmArM     ""
  Write-BashExecShim (Join-Path $shimDirWin "$tripleBase-ranlib")  $llvmRanlibM ""

  LogOk "Created shims in: $shimDirWin (base=$tripleBase api=$tripleApi)"
}


# ---------------------------
# Build
# ---------------------------
$jobs = [Environment]::ProcessorCount
LogOk "Parallel jobs: $jobs"

foreach ($abi in $ABIs) {
  $target = switch ($abi) {
    "arm64-v8a"     { "android-arm64" }
    "armeabi-v7a"   { "android-arm" }
    "x86_64"        { "android-x86_64" }
    default         { throw "Unsupported ABI: $abi" }
  }

  $tripleApi = switch ($abi) {
  "arm64-v8a"   { "aarch64-linux-android$ApiLevel" }
  "armeabi-v7a" { "armv7a-linux-androideabi$ApiLevel" }
  "x86_64"      { "x86_64-linux-android$ApiLevel" }
}

$tripleBase = switch ($abi) {
  "arm64-v8a"   { "aarch64-linux-android" }
  "armeabi-v7a" { "arm-linux-androideabi" }   # WICHTIG: nicht armv7a-...
  "x86_64"      { "x86_64-linux-android" }
}

  LogInfo "==================== $abi ===================="
  LogInfo "OpenSSL target: $target"
  LogInfo "Tool triple: $tripleApi"

  $buildDirWin   = Join-Path $buildRoot $target
  $stripLabel = if ($Strip) { 'stripped' } else { 'unstripped' }
  $installTypeDir = Join-Path $installRoot ("$($BuildType)-$stripLabel")
  $installDirWin = Join-Path $installTypeDir $abi
  $shimDirWin    = Join-Path $buildDirWin "toolshims"

  if (Test-Path $buildDirWin)   { Remove-Item -Recurse -Force $buildDirWin }
  if (Test-Path $installDirWin) { Remove-Item -Recurse -Force $installDirWin }
  Ensure-Dir $buildDirWin
  Ensure-Dir $installDirWin

  LogInfo "Copying sources..."
  & robocopy $srcDir $buildDirWin /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
  LogOk "Source copy completed"

  Create-ShimsForAbi $shimDirWin $ndkBinWin $ndkSysrootWin $tripleApi $tripleBase

  $ndkBinM  = To-MsysPath $ndkBinWin
  $shimM    = To-MsysPath $shimDirWin
  $buildM   = To-MsysPath $buildDirWin
  $prefixM  = To-MsysPath $installDirWin

  $sharedArg = if ($BuildShared) { "shared" } else { "no-shared" }

  $logFile = Join-Path $buildDirWin "build.log"
  $runShWin = Join-Path $buildDirWin "run_build.sh"
  $runShM   = To-MsysPath $runShWin

  # choose CFLAGS/CXXFLAGS according to BuildType
  switch ($BuildType) {
    "RelWithDebInfo" { $cflags = "-O2 -g -fno-omit-frame-pointer"; $cxxflags = $cflags }
    "Debug" { $cflags = "-O0 -g -DDEBUG"; $cxxflags = $cflags }
    "Release" { $cflags = "-O3 -DNDEBUG"; $cxxflags = $cflags }
    default { $cflags = "-O2 -g"; $cxxflags = $cflags }
  }

  $bashScript = @'
set -euo pipefail
if [ "${TRACE:-0}" = "1" ]; then
  export PS4='+(${BASH_SOURCE}:${LINENO}): '
  export BASH_XTRACEFD=1
  set -x
fi

echo "[bash] ENTER run_build.sh"
date

PERL="/usr/bin/perl"
MAKE="/usr/bin/make"
export PERL MAKE

# Wichtig: POSIX PATH lassen (Cygwin Perl erwartet ':')
export PATH="__SHIM__:__NDKBIN__:/usr/bin:/bin:$PATH"
hash -r

echo "CFLAGS=__CFLAGS__"
export CFLAGS="__CFLAGS__"
export CXXFLAGS="__CXXFLAGS__"

echo "========== DEBUG PERL =========="
"$PERL" -MConfig -e 'print "[perl] osname=$Config{osname}\n[perl] path_sep=$Config{path_sep}\n"'
echo "========== DEBUG TOOL RESOLUTION =========="
command -v "__TRIPLE__-clang" || true
command -v "aarch64-linux-android-gcc" || true
"__TRIPLE__-clang" --version || true

cd "__BUILDDIR__"

echo "========== PATCH SHIMS (response-file aware) =========="
SHIM_DIR="__SHIM__"
TRIPLE="__TRIPLE__"
NDK_ROOT="__NDKROOTPOSIX__"
SYSROOT="$NDK_ROOT/toolchains/llvm/prebuilt/windows-x86_64/sysroot"
CLANG_EXE="$NDK_ROOT/toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe"

write_rsp_shim() {
  local out="$1"
  local target="$2"
  cat > "$out" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

EXEC="__EXEC__"
EXTRA=(__EXTRA__)

# grobe Längenabschätzung (reicht, um Windows-Limit zu umgehen)
len=0
for a in "$@"; do len=$((len + ${#a} + 1)); done

if [ "$len" -gt 700 ]; then
  rsp="$(mktemp -t clangargs.XXXXXX.rsp)"

  for a in "$@"; do
    if [[ "$a" == *[[:space:]\"]* ]]; then
      esc="${a//\\/\\\\}"
      esc="${esc//\"/\\\"}"
      printf '"%s"\n' "$esc" >> "$rsp"
    else
      printf '%s\n' "$a" >> "$rsp"
    fi
  done

  if command -v cygpath >/dev/null 2>&1; then
    rspw="$(cygpath -w "$rsp")"
  else
    rspw="$rsp"
  fi

  "$EXEC" "${EXTRA[@]}" "@$rspw"
  rm -f "$rsp"
else
  "$EXEC" "${EXTRA[@]}" "$@"
fi
EOF

  # Platzhalter ersetzen (ohne sed -i Abhängigkeit)
  tmp="$(mktemp)"
  sed \
    -e "s|__EXEC__|$CLANG_EXE|g" \
    -e "s|__EXTRA__|--target=$target --sysroot=$SYSROOT|g" \
    "$out" > "$tmp"
  mv "$tmp" "$out"
  chmod +x "$out"
}

# Schreibe/überschreibe die shims (clang + clang++)
write_rsp_shim "$SHIM_DIR/$TRIPLE-clang"   "$TRIPLE"
write_rsp_shim "$SHIM_DIR/$TRIPLE-clang++" "$TRIPLE"

hash -r

echo "[bash] shim clang path: $(command -v "$TRIPLE-clang" || true)"
"$SHIM_DIR/$TRIPLE-clang" --version || true
echo "==========================================="

# Optional: erzwinge, dass Configure wirklich unsere Tools nimmt (EXPLIZITER PFAD!)
export CC="$SHIM_DIR/$TRIPLE-clang"
export CXX="$SHIM_DIR/$TRIPLE-clang++"
export AR="llvm-ar"
export RANLIB="llvm-ranlib"

echo "========== RUN CONFIGURE =========="
# Force NDK vars to POSIX paths (OpenSSL Configure reads these!)
export ANDROID_NDK_ROOT="$NDK_ROOT"
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
export ANDROID_NDK="$ANDROID_NDK_ROOT"

echo "[bash] ANDROID_NDK_ROOT=$ANDROID_NDK_ROOT"
echo "[bash] ANDROID_NDK_HOME=$ANDROID_NDK_HOME"
echo "[bash] ANDROID_NDK=$ANDROID_NDK"

"$PERL" Configure __TARGET__ __SHARED__ no-tests --prefix="__PREFIX__" --openssldir="__PREFIX__/ssl"

echo "========== AFTER CONFIGURE =========="
"$PERL" configdata.pm --dump | egrep '^(CC|CXX|AR|RANLIB|CFLAGS|CXXFLAGS)=' || true
grep -nE '^(CC|CXX)\s*=' Makefile || true

echo "========== BUILD =========="
"$MAKE" -j__JOBS__ CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB"

echo "========== INSTALL =========="
"$MAKE" CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$RANLIB" install_sw
'@





  $bashScript = $bashScript.Replace("__SHIM__",     $shimM)
  $bashScript = $bashScript.Replace("__NDKBIN__",   $ndkBinM)
  $bashScript = $bashScript.Replace("__TRIPLE__",   $tripleApi)
  $bashScript = $bashScript.Replace("__BUILDDIR__", $buildM)
  $bashScript = $bashScript.Replace("__TARGET__",   $target)
  $bashScript = $bashScript.Replace("__SHARED__",   $sharedArg)
  $bashScript = $bashScript.Replace("__API__",      [string]$ApiLevel)
  $bashScript = $bashScript.Replace("__PREFIX__",   $prefixM)
  $bashScript = $bashScript.Replace("__JOBS__",     [string]$jobs)
  $bashScript = $bashScript.Replace("__CFLAGS__",   $cflags)
  $bashScript = $bashScript.Replace("__CXXFLAGS__", $cxxflags)
  # $ndkBinM looks like: /c/Users/.../ndk/28.x.x/toolchains/llvm/prebuilt/windows-x86_64/bin
  $ndkRootM = $ndkBinM -replace '/toolchains/llvm/prebuilt/[^/]+/bin$',''
  if (-not $ndkRootM) { throw "Failed to derive ndkRootM from ndkBinM=$ndkBinM" }
  $bashScript = $bashScript.Replace("__NDKROOTPOSIX__", $ndkRootM)

  Write-Utf8NoBomLf $runShWin $bashScript
  LogOk "Wrote bash script: $runShWin"

  Run-Bash $bashExe "ls -la $runShM; TRACE=0; . $runShM" $workDir $logFile

  $sslH = Join-Path $installDirWin "include\openssl\ssl.h"
  if (-not (Test-Path $sslH)) { throw "Missing expected header: $sslH (see $logFile)" }

  LogOk "Built + installed OpenSSL for $abi"
}

LogOk "All ABIs finished. Internal output under: $installRoot"

# ---------------------------
# Standardize output for this repo
# ---------------------------
LogInfo "Standardizing output to build/android..."
$finalBuildDir = Join-Path $workDir "build\android"
$finalJniLibs  = Join-Path $finalBuildDir "jniLibs"
$finalInclude  = Join-Path $finalBuildDir "include"

Ensure-Dir $finalJniLibs
Ensure-Dir $finalInclude

# Use the currently built variant as the source for the standardized build folder
foreach ($abi in $ABIs) {
    # Determine which install dir to pull from (based on current script params)
    $stripLabel = if ($Strip) { 'stripped' } else { 'unstripped' }
    $sourceAbiDir = Join-Path $installRoot ("$($BuildType)-$stripLabel\$abi")
    
    if (Test-Path $sourceAbiDir) {
        $destAbiDir = Join-Path $finalJniLibs $abi
        Ensure-Dir $destAbiDir
        
        LogInfo "Copying $abi binaries to $destAbiDir"
        # Copy .so and .a files
        Get-ChildItem -Path $sourceAbiDir -Recurse -Include *.so, *.a | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination $destAbiDir -Force
        }
        
        # Copy headers (only once or every time, it doesn't matter much)
        if (Test-Path (Join-Path $sourceAbiDir "include\openssl")) {
            LogInfo "Copying headers for $abi"
            Copy-Item -Path (Join-Path $sourceAbiDir "include\openssl") -Destination $finalInclude -Recurse -Force
        }
    }
}

LogOk "Standardized output completed at: $finalBuildDir"
