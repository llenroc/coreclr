@if not defined _echo @echo off
setlocal EnableDelayedExpansion EnableExtensions

:: Define a prefix for most output progress messages that come from this script. That makes
:: it easier to see where these are coming from. Note that there is a trailing space here.
set "__MsgPrefix=BUILD: "

echo %__MsgPrefix%Starting Build at %TIME%
set __ThisScriptFull="%~f0"
set __ThisScriptDir="%~dp0"

:: Default to highest Visual Studio version available
::
:: For VS2015 (and prior), only a single instance is allowed to be installed on a box
:: and VS140COMNTOOLS is set as a global environment variable by the installer. This
:: allows users to locate where the instance of VS2015 is installed.
::
:: For VS2017, multiple instances can be installed on the same box SxS and VS150COMNTOOLS
:: is no longer set as a global environment variable and is instead only set if the user
:: has launched the VS2017 Developer Command Prompt.
::
:: Following this logic, we will default to the VS2017 toolset if VS150COMNTOOLS tools is
:: set, as this indicates the user is running from the VS2017 Developer Command Prompt and
:: is already configured to use that toolset. Otherwise, we will fallback to using the VS2015
:: toolset if it is installed. Finally, we will fail the script if no supported VS instance
:: can be found.

if defined VisualStudioVersion (
    if not defined __VSVersion echo %__MsgPrefix%Detected Visual Studio %VisualStudioVersion% developer command ^prompt environment
    goto :Run
) 

echo %__MsgPrefix%"Searching for Visual Studio 2017 or 2015 installation"
set _VSWHERE="%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist %_VSWHERE% (
for /f "usebackq tokens=*" %%i in (`%_VSWHERE% -latest -prerelease -property installationPath`) do set _VSCOMNTOOLS=%%i\Common7\Tools
)
if not exist "%_VSCOMNTOOLS%" set _VSCOMNTOOLS=%VS140COMNTOOLS%
if not exist "%_VSCOMNTOOLS%" (
    echo %__MsgPrefix%Error: Visual Studio 2015 or 2017 required.
    echo        Please see https://github.com/dotnet/corefx/blob/master/Documentation/project-docs/developer-guide.md for build instructions.
    exit /b 1
)

call "%_VSCOMNTOOLS%\VsDevCmd.bat"

:Run

if defined VS150COMNTOOLS (
  set "__VSToolsRoot=%VS150COMNTOOLS%"
  set "__VCToolsRoot=%VS150COMNTOOLS%\..\..\VC\Auxiliary\Build"
  set __VSVersion=vs2017
) else (
  set "__VSToolsRoot=%VS140COMNTOOLS%"
  set "__VCToolsRoot=%VS140COMNTOOLS%\..\..\VC"
  set __VSVersion=vs2015
)

:: Note that the msbuild project files (specifically, dir.proj) will use the following variables, if set:
::      __BuildArch         -- default: x64
::      __BuildType         -- default: Debug
::      __BuildOS           -- default: Windows_NT
::      __ProjectDir        -- default: directory of the dir.props file
::      __SourceDir         -- default: %__ProjectDir%\src\
::      __PackagesDir       -- default: %__ProjectDir%\packages\
::      __RootBinDir        -- default: %__ProjectDir%\bin\
::      __BinDir            -- default: %__RootBinDir%\%__BuildOS%.%__BuildArch.%__BuildType%\
::      __IntermediatesDir
::      __PackagesBinDir    -- default: %__BinDir%\.nuget
::      __TestWorkingDir    -- default: %__RootBinDir%\tests\%__BuildOS%.%__BuildArch.%__BuildType%\
::
:: Thus, these variables are not simply internal to this script!

:: Set the default arguments for build
set __BuildArch=x64
set __BuildType=Debug
set __BuildOS=Windows_NT

:: Set the various build properties here so that CMake and MSBuild can pick them up
set "__ProjectDir=%~dp0"
:: remove trailing slash
if %__ProjectDir:~-1%==\ set "__ProjectDir=%__ProjectDir:~0,-1%"
set "__ProjectFilesDir=%__ProjectDir%"
set "__SourceDir=%__ProjectDir%\src"
set "__PackagesDir=%DotNetRestorePackagesPath%"
if [%__PackagesDir%]==[] set "__PackagesDir=%__ProjectDir%\packages"
set "__RootBinDir=%__ProjectDir%\bin"
set "__LogsDir=%__RootBinDir%\Logs"
set "__PgoOptDataVersion="
set "__IbcOptDataVersion="

set __BuildAll=

set __BuildArchX64=0
set __BuildArchX86=0
set __BuildArchArm=0
set __BuildArchArm64=0

set __BuildTypeDebug=0
set __BuildTypeChecked=0
set __BuildTypeRelease=0

set __PgoInstrument=0
set __PgoOptimize=1
set __EnforcePgo=0
set __IbcTuning=

REM __PassThroughArgs is a set of things that will be passed through to nested calls to build.cmd
REM when using "all".
set __PassThroughArgs=

REM __UnprocessedBuildArgs are args that we pass to msbuild (e.g. /p:__BuildArch=x64)
set "__args= %*"
set processedArgs=
set __UnprocessedBuildArgs=
set __RunArgs=

set __BuildCoreLib=1
set __BuildSOS=1
set __BuildNative=1
set __BuildTests=1
set __BuildPackages=1
set __BuildNativeCoreLib=1
set __RestoreOptData=1

:Arg_Loop
if "%1" == "" goto ArgsDone

if /i "%1" == "-?"    goto Usage
if /i "%1" == "-h"    goto Usage
if /i "%1" == "-help" goto Usage
if /i "%1" == "--help" goto Usage


if /i "%1" == "-all"                 (set __BuildAll=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-x64"                 (set __BuildArchX64=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-x86"                 (set __BuildArchX86=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-arm"                 (set __BuildArchArm=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-arm64"               (set __BuildArchArm64=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)

if /i "%1" == "-debug"               (set __BuildTypeDebug=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-checked"             (set __BuildTypeChecked=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-release"             (set __BuildTypeRelease=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)

REM TODO these are deprecated remove them eventually
REM don't add more, use the - syntax instead
if /i "%1" == "all"                 (set __BuildAll=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "x64"                 (set __BuildArchX64=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "x86"                 (set __BuildArchX86=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "arm"                 (set __BuildArchArm=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "arm64"               (set __BuildArchArm64=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)

if /i "%1" == "debug"               (set __BuildTypeDebug=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "checked"             (set __BuildTypeChecked=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "release"             (set __BuildTypeRelease=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)

REM All arguments after this point will be passed through directly to build.cmd on nested invocations
REM using the "all" argument, and must be added to the __PassThroughArgs variable.
if [!__PassThroughArgs!]==[] (
    set __PassThroughArgs=%1
) else (
    set __PassThroughArgs=%__PassThroughArgs% %1
)

if /i "%1" == "-freebsdmscorlib"     (set __BuildSOS=0&set __BuildNativeCoreLib=0&set __BuildNative=0&set __BuildTests=0&set __BuildPackages=0&set __BuildOS=FreeBSD&set __SkipNugetPackage=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-linuxmscorlib"       (set __BuildSOS=0&set __BuildNativeCoreLib=0&set __BuildNative=0&set __BuildTests=0&set __BuildPackages=0&set __BuildOS=Linux&set __SkipNugetPackage=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-netbsdmscorlib"      (set __BuildSOS=0&set __BuildNativeCoreLib=0&set __BuildNative=0&set __BuildTests=0&set __BuildPackages=0&set __BuildOS=NetBSD&set __SkipNugetPackage=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-osxmscorlib"         (set __BuildSOS=0&set __BuildNativeCoreLib=0&set __BuildNative=0&set __BuildTests=0&set __BuildPackages=0&set __BuildOS=OSX&set __SkipNugetPackage=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-windowsmscorlib"     (set __BuildSOS=0&set __BuildNativeCoreLib=0&set __BuildNative=0&set __BuildTests=0&set __BuildPackages=0&set __BuildOS=Windows_NT&set __SkipNugetPackage=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-nativemscorlib"      (set __BuildNativeCoreLib=1&set __BuildCoreLib=0&set __BuildNative=0&set __BuildTests=0&set __BuildPackages=0&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-configureonly"       (set __ConfigureOnly=1&set __BuildNative=1&set __BuildNativeCoreLib=0&set __BuildCoreLib=0&set __BuildTests=0&set __BuildPackages=0&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-skipconfigure"       (set __SkipConfigure=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-skipmscorlib"        (set __BuildCoreLib=0&set __BuildNativeCoreLib=0&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-skipnative"          (set __BuildNative=0&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-skiptests"           (set __BuildTests=0&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-skipbuildpackages"   (set __BuildPackages=0&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-skiprestoreoptdata"  (set __RestoreOptData=0&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-usenmakemakefiles"   (set __NMakeMakefiles=1&set __ConfigureOnly=1&set __BuildNative=1&set __BuildNativeCoreLib=0&set __BuildCoreLib=0&set __BuildTests=0&set __BuildPackages=0&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-pgoinstrument"       (set __PgoInstrument=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-enforcepgo"          (set __EnforcePgo=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-nopgooptimize"       (set __PgoOptimize=0&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-ibcinstrument"       (set __IbcTuning=/Tuning&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-toolset_dir"         (set __ToolsetDir=%2&set __PassThroughArgs=%__PassThroughArgs% %2&set processedArgs=!processedArgs! %1 %2&shift&shift&goto Arg_Loop)

REM TODO these are deprecated remove them eventually
REM don't add more, use the - syntax instead
if /i "%1" == "freebsdmscorlib"     (set __BuildSOS=0&set __BuildNativeCoreLib=0&set __BuildNative=0&set __BuildTests=0&set __BuildPackages=0&set __BuildOS=FreeBSD&set __SkipNugetPackage=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "linuxmscorlib"       (set __BuildSOS=0&set __BuildNativeCoreLib=0&set __BuildNative=0&set __BuildTests=0&set __BuildPackages=0&set __BuildOS=Linux&set __SkipNugetPackage=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "netbsdmscorlib"      (set __BuildSOS=0&set __BuildNativeCoreLib=0&set __BuildNative=0&set __BuildTests=0&set __BuildPackages=0&set __BuildOS=NetBSD&set __SkipNugetPackage=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "osxmscorlib"         (set __BuildSOS=0&set __BuildNativeCoreLib=0&set __BuildNative=0&set __BuildTests=0&set __BuildPackages=0&set __BuildOS=OSX&set __SkipNugetPackage=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "windowsmscorlib"     (set __BuildSOS=0&set __BuildNativeCoreLib=0&set __BuildNative=0&set __BuildTests=0&set __BuildPackages=0&set __BuildOS=Windows_NT&set __SkipNugetPackage=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "nativemscorlib"      (set __BuildNativeCoreLib=1&set __BuildCoreLib=0&set __BuildNative=0&set __BuildTests=0&set __BuildPackages=0&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "configureonly"       (set __ConfigureOnly=1&set __BuildNative=1&set __BuildNativeCoreLib=0&set __BuildCoreLib=0&set __BuildTests=0&set __BuildPackages=0&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "skipconfigure"       (set __SkipConfigure=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "skipmscorlib"        (set __BuildCoreLib=0&set __BuildNativeCoreLib=0&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "skipnative"          (set __BuildNative=0&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "skiptests"           (set __BuildTests=0&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "skipbuildpackages"   (set __BuildPackages=0&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "skiprestoreoptdata"  (set __RestoreOptData=0&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "usenmakemakefiles"   (set __NMakeMakefiles=1&set __ConfigureOnly=1&set __BuildNative=1&set __BuildNativeCoreLib=0&set __BuildCoreLib=0&set __BuildTests=0&set __BuildPackages=0&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "pgoinstrument"       (set __PgoInstrument=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "nopgooptimize"       (set __PgoOptimize=0&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "enforcepgo"          (set __EnforcePgo=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "ibcinstrument"       (set __IbcTuning=/Tuning&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "toolset_dir"         (set __ToolsetDir=%2&set __PassThroughArgs=%__PassThroughArgs% %2&set processedArgs=!processedArgs! %1 %2&shift&shift&goto Arg_Loop)

@REM The following can be deleted once the CI system that passes it is updated to not pass it.
if /i "%1" == "altjitcrossgen"      (set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)

if [!processedArgs!]==[] (
  set __UnprocessedBuildArgs=%__args%
) else (
  set __UnprocessedBuildArgs=%__args%
  for %%t in (!processedArgs!) do (
    set __UnprocessedBuildArgs=!__UnprocessedBuildArgs:*%%t=!
  )
)

:ArgsDone

if %__PgoOptimize%==0 set __RestoreOptData=0

if defined __BuildAll goto BuildAll

set /A __TotalSpecifiedBuildArch=__BuildArchX64 + __BuildArchX86 + __BuildArchArm + __BuildArchArm64
if %__TotalSpecifiedBuildArch% GTR 1 (
    echo Error: more than one build architecture specified, but "all" not specified.
    goto Usage
)

if %__BuildArchX64%==1      set __BuildArch=x64
if %__BuildArchX86%==1      set __BuildArch=x86
if %__BuildArchArm%==1 (
    set __BuildArch=arm
    set __CrossArch=x86
)
if %__BuildArchArm64%==1 (
    set __BuildArch=arm64
    set __CrossArch=x64
)

set /A __TotalSpecifiedBuildType=__BuildTypeDebug + __BuildTypeChecked + __BuildTypeRelease
if %__TotalSpecifiedBuildType% GTR 1 (
    echo Error: more than one build type specified, but "all" not specified.
    goto Usage
)

if %__BuildTypeDebug%==1    set __BuildType=Debug
if %__BuildTypeChecked%==1  set __BuildType=Checked
if %__BuildTypeRelease%==1  set __BuildType=Release

set __RunArgs=-BuildOS=%__BuildOS% -BuildType=%__BuildType% -BuildArch=%__BuildArch%

if %__EnforcePgo%==1 (
    if %__BuildArchArm%==1 (
        echo NOTICE: enforcepgo does nothing on arm architecture
    )
    if %__BuildArchArm64%==1 (
        echo NOTICE: enforcepgo does nothing on arm64 architecture
    )
)

:: Set the remaining variables based upon the determined build configuration
set "__BinDir=%__RootBinDir%\Product\%__BuildOS%.%__BuildArch%.%__BuildType%"
set "__IntermediatesDir=%__RootBinDir%\obj\%__BuildOS%.%__BuildArch%.%__BuildType%"
if "%__NMakeMakefiles%"=="1" (set "__IntermediatesDir=%__RootBinDir%\nmakeobj\%__BuildOS%.%__BuildArch%.%__BuildType%")
set "__PackagesBinDir=%__BinDir%\.nuget"
set "__TestRootDir=%__RootBinDir%\tests"
set "__TestBinDir=%__TestRootDir%\%__BuildOS%.%__BuildArch%.%__BuildType%"
set "__TestIntermediatesDir=%__RootBinDir%\tests\obj\%__BuildOS%.%__BuildArch%.%__BuildType%"
set "__CrossComponentBinDir=%__BinDir%"
set "__CrossCompIntermediatesDir=%__IntermediatesDir%\crossgen"


if NOT "%__CrossArch%" == "" set __CrossComponentBinDir=%__CrossComponentBinDir%\%__CrossArch%
set "__CrossGenCoreLibLog=%__LogsDir%\CrossgenCoreLib_%__BuildOS%__%__BuildArch%__%__BuildType%.log"
set "__CrossgenExe=%__CrossComponentBinDir%\crossgen.exe"

:: Generate path to be set for CMAKE_INSTALL_PREFIX to contain forward slash
set "__CMakeBinDir=%__BinDir%"
set "__CMakeBinDir=%__CMakeBinDir:\=/%"

if not exist "%__BinDir%"           md "%__BinDir%"
if not exist "%__IntermediatesDir%" md "%__IntermediatesDir%"
if not exist "%__LogsDir%"          md "%__LogsDir%"

REM It is convenient to have your Nuget search path include the location where the build
REM will place packages.  However nuget used during the build will fail if that directory
REM does not exist.   Avoid this in at least one case by aggressively creating the directory.
if not exist "%__BinDir%\.nuget\pkg"           md "%__BinDir%\.nuget\pkg"

echo %__MsgPrefix%Commencing CoreCLR Repo build

:: Set the remaining variables based upon the determined build configuration

echo %__MsgPrefix%Checking prerequisites
:: Eval the output from probe-win1.ps1
for /f "delims=" %%a in ('powershell -NoProfile -ExecutionPolicy ByPass "& ""%__SourceDir%\pal\tools\probe-win.ps1"""') do %%a

REM NumberOfEnabledCore is an WMI property providing number of enabled cores on machine
REM processor(s) and later is used to set optimal level of CL parallelism during native build step
if not defined NumberOfCores (
REM Determine number of physical processor cores available on machine
for /f "tokens=*" %%I in (
    'wmic cpu get NumberOfCores /value ^| find "=" 2^>NUL'
    ) do set %%I
)
echo %__MsgPrefix%Number of processor cores %NumberOfCores%

REM =========================================================================================
REM ===
REM === Start the build steps
REM ===
REM =========================================================================================

@if defined _echo @echo on

@call %__ProjectDir%\run.cmd build -Project=%__ProjectDir%\build.proj -generateHeaderWindows -NativeVersionHeaderFile="%__RootBinDir%\obj\_version.h" %__RunArgs% %__UnprocessedBuildArgs%

REM =========================================================================================
REM ===
REM === Restore optimization profile data
REM ===
REM =========================================================================================

if %__RestoreOptData% EQU 1 if %__BuildTypeRelease% EQU 1 (
    echo %__MsgPrefix%Restoring the OptimizationData Package
    @call %__ProjectDir%\run.cmd sync -optdata
    if not !errorlevel! == 0 (
        echo %__MsgPrefix%Error: Failed to restore the optimization data package.
        exit /b 1
    )
)

REM Parse the optdata package versions out of msbuild so that we can pass them on to CMake
set DotNetCli=%__ProjectDir%\Tools\dotnetcli\dotnet.exe
if not exist "%DotNetCli%" (
    echo %__MsgPrefix%Assertion failed: dotnet.exe not found at path "%DotNetCli%"
    exit /b 1
)
set OptDataProjectFilePath=%__ProjectDir%\src\.nuget\optdata\optdata.csproj
for /f "tokens=*" %%s in ('%DotNetCli% msbuild "%OptDataProjectFilePath%" /t:DumpPgoDataPackageVersion /nologo') do @(
    set __PgoOptDataVersion=%%s
)
for /f "tokens=*" %%s in ('%DotNetCli% msbuild "%OptDataProjectFilePath%" /t:DumpIbcDataPackageVersion /nologo') do @(
    set __IbcOptDataVersion=%%s
)

REM =========================================================================================
REM ===
REM === Build the CLR VM
REM ===
REM =========================================================================================

if %__BuildNative% EQU 1 (
    REM Scope environment changes start {
    setlocal

    echo %__MsgPrefix%Commencing build of native components for %__BuildOS%.%__BuildArch%.%__BuildType%

    set __NativePlatformArgs=-platform=%__BuildArch%
    if not "%__ToolsetDir%" == "" ( set __NativePlatformArgs=-useEnv )

    if not "%__ToolsetDir%" == "" (
        rem arm64 builds currently use private toolset which has not been released yet
        REM TODO, remove once the toolset is open.
        call :PrivateToolSet
        goto GenVSSolution
    )

    :: Set the environment for the native build
    set __VCBuildArch=x86_amd64
    if /i "%__BuildArch%" == "x86" ( set __VCBuildArch=x86 )
    if /i "%__BuildArch%" == "arm" (
        set __VCBuildArch=x86_arm

        REM Make CMake pick the highest installed version in the 10.0.* range
        set ___SDKVersion="-DCMAKE_SYSTEM_VERSION=10.0"
    )
    if /i "%__BuildArch%" == "arm64" (
        set __VCBuildArch=x86_arm64

        REM Make CMake pick the highest installed version in the 10.0.* range
        set ___SDKVersion="-DCMAKE_SYSTEM_VERSION=10.0"
    )

    echo %__MsgPrefix%Using environment: "%__VCToolsRoot%\vcvarsall.bat" !__VCBuildArch!
    call                                 "%__VCToolsRoot%\vcvarsall.bat" !__VCBuildArch!
    @if defined _echo @echo on

    if not defined VSINSTALLDIR (
        echo %__MsgPrefix%Error: VSINSTALLDIR variable not defined.
        exit /b 1
    )
    if not exist "!VSINSTALLDIR!DIA SDK" goto NoDIA

:GenVSSolution
    if defined __SkipConfigure goto SkipConfigure

    echo %__MsgPrefix%Regenerating the Visual Studio solution

    pushd "%__IntermediatesDir%"
    set __ExtraCmakeArgs=!___SDKVersion! "-DCLR_CMAKE_TARGET_OS=%__BuildOs%" "-DCLR_CMAKE_PACKAGES_DIR=%__PackagesDir%" "-DCLR_CMAKE_PGO_INSTRUMENT=%__PgoInstrument%" "-DCLR_CMAKE_OPTDATA_VERSION=%__PgoOptDataVersion%" "-DCLR_CMAKE_PGO_OPTIMIZE=%__PgoOptimize%"
    call "%__SourceDir%\pal\tools\gen-buildsys-win.bat" "%__ProjectDir%" %__VSVersion% %__BuildArch% !__ExtraCmakeArgs!
    @if defined _echo @echo on
    popd

:SkipConfigure
    if defined __ConfigureOnly goto SkipNativeBuild

    if not exist "%__IntermediatesDir%\install.vcxproj" (
        echo %__MsgPrefix%Error: failed to generate native component build project!
        exit /b 1
    )

    set __BuildLogRootName=CoreCLR
    set __BuildLog="%__LogsDir%\!__BuildLogRootName!_%__BuildOS%__%__BuildArch%__%__BuildType%.log"
    set __BuildWrn="%__LogsDir%\!__BuildLogRootName!_%__BuildOS%__%__BuildArch%__%__BuildType%.wrn"
    set __BuildErr="%__LogsDir%\!__BuildLogRootName!_%__BuildOS%__%__BuildArch%__%__BuildType%.err"
    set __MsbuildLog=/flp:Verbosity=normal;LogFile=!__BuildLog!
    set __MsbuildWrn=/flp1:WarningsOnly;LogFile=!__BuildWrn!
    set __MsbuildErr=/flp2:ErrorsOnly;LogFile=!__BuildErr!

    @call %__ProjectDir%\run.cmd build -Project=%__IntermediatesDir%\install.vcxproj -MsBuildLog=!__MsbuildLog! -MsBuildWrn=!__MsbuildWrn! -MsBuildErr=!__MsbuildErr! -configuration=%__BuildType% %__NativePlatformArgs% %__RunArgs% -ExtraParameters="/p:ForceImportBeforeCppTargets=%__ProjectDir%/clr.nativebuild.props /m:2" %__UnprocessedBuildArgs%

    if not !errorlevel! == 0 (
        echo %__MsgPrefix%Error: native component build failed. Refer to the build log files for details:
        echo     !__BuildLog!
        echo     !__BuildWrn!
        echo     !__BuildErr!
        exit /b 1
    )

:SkipNativeBuild
    REM } Scope environment changes end
    endlocal
)

REM =========================================================================================
REM ===
REM === Build Cross-Architecture Native Components (if applicable)
REM ===
REM =========================================================================================

if /i "%__BuildArch%"=="arm64" (
    set __DoCrossArchBuild=1
    )

if /i "%__BuildArch%"=="arm" (
    set __DoCrossArchBuild=1
    )

if /i "%__DoCrossArchBuild%"=="1" (
    REM Scope environment changes start {
    setlocal

    echo %__MsgPrefix%Commencing build of cross architecture native components for %__BuildOS%.%__BuildArch%.%__BuildType%

    :: Set the environment for the native build
    set __VCBuildArch=x86_amd64
    if /i "%__CrossArch%" == "x86" ( set __VCBuildArch=x86 )

    echo %__MsgPrefix%Using environment: "%__VCToolsRoot%\vcvarsall.bat" !__VCBuildArch!
    call                                 "%__VCToolsRoot%\vcvarsall.bat" !__VCBuildArch!
    @if defined _echo @echo on

    if not exist "%__CrossCompIntermediatesDir%" md "%__CrossCompIntermediatesDir%"
    if defined __SkipConfigure goto SkipConfigureCrossBuild

    pushd "%__CrossCompIntermediatesDir%"
    set __CMakeBinDir=%__CrossComponentBinDir%
    set "__CMakeBinDir=!__CMakeBinDir:\=/!"
    set __ExtraCmakeArgs="-DCLR_CROSS_COMPONENTS_BUILD=1" "-DCLR_CMAKE_TARGET_ARCH=%__BuildArch%" "-DCLR_CMAKE_TARGET_OS=%__BuildOs%" "-DCLR_CMAKE_PACKAGES_DIR=%__PackagesDir%" "-DCLR_CMAKE_PGO_INSTRUMENT=%__PgoInstrument%" "-DCLR_CMAKE_OPTDATA_VERSION=%__PgoOptDataVersion%" "-DCLR_CMAKE_PGO_OPTIMIZE=%__PgoOptimize%" "-DCMAKE_SYSTEM_VERSION=10.0"
    call "%__SourceDir%\pal\tools\gen-buildsys-win.bat" "%__ProjectDir%" %__VSVersion% %__CrossArch% !__ExtraCmakeArgs!
    @if defined _echo @echo on
    popd

:SkipConfigureCrossBuild
    if not exist "%__CrossCompIntermediatesDir%\install.vcxproj" (
        echo %__MsgPrefix%Error: failed to generate cross-arch components build project!
        exit /b 1
    )

    if defined __ConfigureOnly goto SkipCrossCompBuild

    set __BuildLogRootName=Cross
    set __BuildLog="%__LogsDir%\!__BuildLogRootName!_%__BuildOS%__%__BuildArch%__%__BuildType%.log"
    set __BuildWrn="%__LogsDir%\!__BuildLogRootName!_%__BuildOS%__%__BuildArch%__%__BuildType%.wrn"
    set __BuildErr="%__LogsDir%\!__BuildLogRootName!_%__BuildOS%__%__BuildArch%__%__BuildType%.err"
    set __MsbuildLog=/flp:Verbosity=normal;LogFile=!__BuildLog!
    set __MsbuildWrn=/flp1:WarningsOnly;LogFile=!__BuildWrn!
    set __MsbuildErr=/flp2:ErrorsOnly;LogFile=!__BuildErr!

    @call %__ProjectDir%\run.cmd build -Project=%__CrossCompIntermediatesDir%\install.vcxproj -configuration=%__BuildType% -platform=%__CrossArch% -MsBuildLog=!__MsbuildLog! -MsBuildWrn=!__MsbuildWrn! -MsBuildErr=!__MsbuildErr! %__RunArgs% -ExtraParameters="/p:ForceImportBeforeCppTargets=%__ProjectDir%/clr.nativebuild.props /m:2" %__UnprocessedBuildArgs%

        if not !errorlevel! == 0 (
        echo %__MsgPrefix%Error: cross-arch components build failed. Refer to the build log files for details:
        echo     !__BuildLog!
        echo     !__BuildWrn!
        echo     !__BuildErr!
        exit /b 1
    )

:SkipCrossCompBuild
    REM } Scope environment changes end
    endlocal
)

REM =========================================================================================
REM ===
REM === CoreLib and NuGet package build section.
REM ===
REM =========================================================================================

if %__BuildCoreLib% EQU 1 (
    REM Scope environment changes start {
    setlocal

    echo %__MsgPrefix%Commencing build of System.Private.CoreLib for %__BuildOS%.%__BuildArch%.%__BuildType%
    rem Explicitly set Platform causes conflicts in CoreLib project files. Clear it to allow building from VS x64 Native Tools Command Prompt
    set Platform=

    set __ExtraBuildArgs=
    if not defined __IbcTuning (
      set __ExtraBuildArgs=!__ExtraBuildArgs! -OptimizationDataDir="%__PackagesDir%/optimization.%__BuildOS%-%__BuildArch%.IBC.CoreCLR/%__IbcOptDataVersion%/data/"
      set __ExtraBuildArgs=!__ExtraBuildArgs! -EnableProfileGuidedOptimization=true
    )

    if "%__BuildSOS%" == "0" (
        set __ExtraBuildArgs=!__ExtraBuildArgs! -SkipSOS=true
    )

    if /i "%__BuildArch%" == "arm64" (
        set __nugetBuildArgs=-buildNugetPackage=false
    ) else if "%__SkipNugetPackage%" == "1" (
        set __nugetBuildArgs=-buildNugetPackage=false
    ) else (
        set __nugetBuildArgs=-buildNugetPackage=true
    )

    set __BuildLogRootName=System.Private.CoreLib
    set __BuildLog="%__LogsDir%\!__BuildLogRootName!_%__BuildOS%__%__BuildArch%__%__BuildType%.log"
    set __BuildWrn="%__LogsDir%\!__BuildLogRootName!_%__BuildOS%__%__BuildArch%__%__BuildType%.wrn"
    set __BuildErr="%__LogsDir%\!__BuildLogRootName!_%__BuildOS%__%__BuildArch%__%__BuildType%.err"
    set __MsbuildLog=/flp:Verbosity=normal;LogFile=!__BuildLog!
    set __MsbuildWrn=/flp1:WarningsOnly;LogFile=!__BuildWrn!
    set __MsbuildErr=/flp2:ErrorsOnly;LogFile=!__BuildErr!

    @call %__ProjectDir%\run.cmd build -Project=%__ProjectDir%\build.proj -MsBuildLog=!__MsbuildLog! -MsBuildWrn=!__MsbuildWrn! -MsBuildErr=!__MsbuildErr! !__nugetBuildArgs! %__RunArgs% !__ExtraBuildArgs! %__UnprocessedBuildArgs%

    if not !errorlevel! == 0 (
        echo %__MsgPrefix%Error: System.Private.CoreLib build failed. Refer to the build log files for details:
        echo     !__BuildLog!
        echo     !__BuildWrn!
        echo     !__BuildErr!
        exit /b 1
    )

    REM } Scope environment changes end
    endlocal
)

REM Scope environment changes start {
setlocal

REM Need diasymreader.dll on your path for /CreatePdb
set PATH=%PATH%;%WinDir%\Microsoft.Net\Framework64\V4.0.30319;%WinDir%\Microsoft.Net\Framework\V4.0.30319

if %__BuildNativeCoreLib% EQU 1 (
    echo %__MsgPrefix%Generating native image of System.Private.CoreLib for %__BuildOS%.%__BuildArch%.%__BuildType%

    REM Need VS native tools environment for the **target** arch when running instrumented binaries
    if %__PgoInstrument% EQU 1 (
        set __VCExecArch=%__BuildArch%
        if /i [%__BuildArch%] == [x64] set __VCExecArch=amd64
        echo %__MsgPrefix%Using environment: "%__VCToolsRoot%\vcvarsall.bat" !__VCExecArch!
        call                                 "%__VCToolsRoot%\vcvarsall.bat" !__VCExecArch!
        @if defined _echo @echo on
        if NOT !errorlevel! == 0 (
            echo %__MsgPrefix%Error: Failed to load native tools environment for !__VCExecArch!
            goto CrossgenFailure
        )

        REM HACK: Workaround for [dotnet/coreclr#13970](https://github.com/dotnet/coreclr/issues/13970)
        set __PgoRtPath=
        for /f "tokens=*" %%f in ('where pgort*.dll') do (
          if not defined __PgoRtPath set "__PgoRtPath=%%~f"
        )
        echo %__MsgPrefix%Copying "!__PgoRtPath!" into "%__BinDir%"
        copy /y "!__PgoRtPath!" "%__BinDir%" || (
          echo %__MsgPrefix%Error: copy failed
          goto CrossgenFailure
        )
        REM End HACK
    )

    set NEXTCMD="%__CrossgenExe%" %__IbcTuning% /Platform_Assemblies_Paths "%__BinDir%"\IL /out "%__BinDir%\System.Private.CoreLib.dll" "%__BinDir%\IL\System.Private.CoreLib.dll"
    echo %__MsgPrefix%!NEXTCMD!
    !NEXTCMD! > "%__CrossGenCoreLibLog%" 2>&1
    if NOT !errorlevel! == 0 (
        echo %__MsgPrefix%Error: CrossGen System.Private.CoreLib build failed. Refer to %__CrossGenCoreLibLog%
        :: Put it in the same log, helpful for Jenkins
        type %__CrossGenCoreLibLog%
        goto CrossgenFailure
    )

    set NEXTCMD="%__CrossgenExe%" /Platform_Assemblies_Paths "%__BinDir%" /CreatePdb "%__BinDir%\PDB" "%__BinDir%\System.Private.CoreLib.dll"
    echo %__MsgPrefix%!NEXTCMD!
    !NEXTCMD! >> "%__CrossGenCoreLibLog%" 2>&1
    if NOT !errorlevel! == 0 (
        echo %__MsgPrefix%Error: CrossGen /CreatePdb System.Private.CoreLib build failed. Refer to %__CrossGenCoreLibLog%
        :: Put it in the same log, helpful for Jenkins
        type %__CrossGenCoreLibLog%
        goto CrossgenFailure
    )
)

REM } Scope environment changes end
endlocal


if %__BuildPackages% EQU 1 (
    REM Scope environment changes start {
    setlocal

    echo %__MsgPrefix%Building Packages for %__BuildOS%.%__BuildArch%.%__BuildType%

    set __BuildLogRootName=Nuget
    set __BuildLog="%__LogsDir%\!__BuildLogRootName!_%__BuildOS%__%__BuildArch%__%__BuildType%.log"
    set __BuildWrn="%__LogsDir%\!__BuildLogRootName!_%__BuildOS%__%__BuildArch%__%__BuildType%.wrn"
    set __BuildErr="%__LogsDir%\!__BuildLogRootName!_%__BuildOS%__%__BuildArch%__%__BuildType%.err"
    set __MsbuildLog=/flp:Verbosity=normal;LogFile=!__BuildLog!
    set __MsbuildWrn=/flp1:WarningsOnly;LogFile=!__BuildWrn!
    set __MsbuildErr=/flp2:ErrorsOnly;LogFile=!__BuildErr!

    REM The conditions as to what to build are captured in the builds file.
    @call %__ProjectDir%\run.cmd build -Project=%__SourceDir%\.nuget\packages.builds -platform=%__BuildArch% -MsBuildLog=!__MsbuildLog! -MsBuildWrn=!__MsbuildWrn! -MsBuildErr=!__MsbuildErr! %__RunArgs% %__UnprocessedBuildArgs%

    if not !errorlevel! == 0 (
        echo %__MsgPrefix%Error: Nuget package generation failed build failed. Refer to the build log files for details:
        echo     !__BuildLog!
        echo     !__BuildWrn!
        echo     !__BuildErr!
        exit /b 1
    )

    REM } Scope environment changes end
    endlocal
)

REM =========================================================================================
REM ===
REM === Test build section
REM ===
REM =========================================================================================

if %__BuildTests% EQU 1 (
    echo %__MsgPrefix%Commencing build of tests for %__BuildOS%.%__BuildArch%.%__BuildType%

    REM Construct the arguments to pass to the test build script.

    rem arm64 builds currently use private toolset which has not been released yet
    REM TODO, remove once the toolset is open.
    if not "%__ToolsetDir%" == "" call :PrivateToolSet

    set NEXTCMD=call %__ProjectDir%\build-test.cmd %__BuildArch% %__BuildType% %__UnprocessedBuildArgs%
    echo %__MsgPrefix%!NEXTCMD!
    !NEXTCMD!

    if not !errorlevel! == 0 (
        REM buildtest.cmd has already emitted an error message and mentioned the build log file to examine.
        exit /b 1
    )
)

REM =========================================================================================
REM ===
REM === All builds complete!
REM ===
REM =========================================================================================

echo %__MsgPrefix%Repo successfully built.  Finished at %TIME%
echo %__MsgPrefix%Product binaries are available at !__BinDir!
if %__BuildTests% EQU 1 (
    echo %__MsgPrefix%Test binaries are available at !__TestBinDir!
)
exit /b 0

REM =========================================================================================
REM ===
REM === Handle the "all" case.
REM ===
REM =========================================================================================

:BuildAll

set __BuildArchList=

set /A __TotalSpecifiedBuildArch=__BuildArchX64 + __BuildArchX86 + __BuildArchArm + __BuildArchArm64
if %__TotalSpecifiedBuildArch% EQU 0 (
    REM Nothing specified means we want to build all architectures.
    set __BuildArchList=x64 x86 arm arm64
)

REM Otherwise, add all the specified architectures to the list.

if %__BuildArchX64%==1      set __BuildArchList=%__BuildArchList% x64
if %__BuildArchX86%==1      set __BuildArchList=%__BuildArchList% x86
if %__BuildArchArm%==1      set __BuildArchList=%__BuildArchList% arm
if %__BuildArchArm64%==1    set __BuildArchList=%__BuildArchList% arm64

set __BuildTypeList=

set /A __TotalSpecifiedBuildType=__BuildTypeDebug + __BuildTypeChecked + __BuildTypeRelease
if %__TotalSpecifiedBuildType% EQU 0 (
    REM Nothing specified means we want to build all build types.
    set __BuildTypeList=Debug Checked Release
)

if %__BuildTypeDebug%==1    set __BuildTypeList=%__BuildTypeList% Debug
if %__BuildTypeChecked%==1  set __BuildTypeList=%__BuildTypeList% Checked
if %__BuildTypeRelease%==1  set __BuildTypeList=%__BuildTypeList% Release

REM Create a temporary file to collect build results. We always build all flavors specified, and
REM report a summary of the results at the end.

set __AllBuildSuccess=true
set __BuildResultFile=%TEMP%\build-all-summary-%RANDOM%.txt
if exist %__BuildResultFile% del /f /q %__BuildResultFile%

for %%i in (%__BuildArchList%) do (
    for %%j in (%__BuildTypeList%) do (
        call :BuildOne %%i %%j
    )
)

if %__AllBuildSuccess%==true (
    echo %__MsgPrefix%All builds succeeded!
    exit /b 0
) else (
    echo %__MsgPrefix%Builds failed:
    type %__BuildResultFile%
    del /f /q %__BuildResultFile%
    exit /b 1
)

REM This code is unreachable, but leaving it nonetheless, just in case things change.
exit /b 99

:BuildOne
set __BuildArch=%1
set __BuildType=%2
set __NextCmd=call %__ThisScriptFull% %__BuildArch% %__BuildType% %__PassThroughArgs%
echo %__MsgPrefix%Invoking: %__NextCmd%
%__NextCmd%
if not !errorlevel! == 0 (
    echo %__MsgPrefix%    %__BuildArch% %__BuildType% %__PassThroughArgs% >> %__BuildResultFile%
    set __AllBuildSuccess=false
)
exit /b 0

REM =========================================================================================
REM ===
REM === Helper routines
REM ===
REM =========================================================================================

:CrossgenFailure
exit /b 1

:Usage
echo.
echo Build the CoreCLR repo.
echo.
echo Usage:
echo     build.cmd [option1] [option2]
echo or:
echo     build.cmd all [option1] [option2] -- ...
echo.
echo All arguments are optional. The options are:
echo.
echo.-? -h -help --help: view this message.
echo -all: Builds all configurations and platforms.
echo Build architecture: one of -x64, -x86, -arm, -arm64 ^(default: -x64^).
echo Build type: one of -Debug, -Checked, -Release ^(default: -Debug^).
echo -- ... : all arguments following this tag will be passed directly to msbuild.
echo mscorlib version: one of -freebsdmscorlib, -linuxmscorlib, -netbsdmscorlib, -osxmscorlib,
echo     or -windowsmscorlib. If one of these is passed, only System.Private.CoreLib is built,
echo     for the specified platform ^(FreeBSD, Linux, NetBSD, OS X or Windows,
echo     respectively^).
echo     add nativemscorlib to go further and build the native image for designated mscorlib.
echo -toolset_dir ^<dir^> : set the toolset directory -- Arm64 use only. Required for Arm64 builds.
echo -nopgooptimize: do not use profile guided optimizations.
echo -enforcepgo: verify after the build that PGO was used for key DLLs, and fail the build if not
echo -pgoinstrument: generate instrumented code for profile guided optimization enabled binaries.
echo -ibcinstrument: generate IBC-tuning-enabled native images when invoking crossgen.
echo -configureonly: skip all builds; only run CMake ^(default: CMake and builds are run^)
echo -skipconfigure: skip CMake ^(default: CMake is run^)
echo -skipmscorlib: skip building System.Private.CoreLib ^(default: System.Private.CoreLib is built^).
echo -skipnative: skip building native components ^(default: native components are built^).
echo -skiptests: skip building tests ^(default: tests are built^).
echo -skipbuildpackages: skip building nuget packages ^(default: packages are built^).
echo -skiprestoreoptdata: skip restoring optimization data used by profile-based optimizations.
echo -skiprestore: skip restoring packages ^(default: packages are restored during build^).
echo -disableoss: Disable Open Source Signing for System.Private.CoreLib.
echo -priority=^<N^> : specify a set of test that will be built and run, with priority N.
echo -officialbuildid=^<ID^>: specify the official build ID to be used by this build.
echo -Rebuild: passes /t:rebuild to the build projects.
echo portable : build for portable RID.
echo.
echo If "all" is specified, then all build architectures and types are built. If, in addition,
echo one or more build architectures or types is specified, then only those build architectures
echo and types are built.
echo.
echo For example:
echo     build -all
echo        -- builds all architectures, and all build types per architecture
echo     build -all -x86
echo        -- builds all build types for x86
echo     build -all -x64 -x86 -Checked -Release
echo        -- builds x64 and x86 architectures, Checked and Release build types for each
exit /b 1

:NoDIA
echo Error: DIA SDK is missing at "%VSINSTALLDIR%DIA SDK". ^
This is due to a bug in the Visual Studio installer. It does not install DIA SDK at "%VSINSTALLDIR%" but rather ^
at the install location of previous Visual Studio version. The workaround is to copy the DIA SDK folder from the Visual Studio install location ^
of the previous version to "%VSINSTALLDIR%" and then build.
:: DIA SDK not included in Express editions
echo Visual Studio Express does not include the DIA SDK. ^
You need Visual Studio 2015 or 2017 (Community is free).
echo See: https://github.com/dotnet/coreclr/blob/master/Documentation/project-docs/developer-guide.md#prerequisites
exit /b 1

:PrivateToolSet

echo %__MsgPrefix%Setting up the usage of __ToolsetDir:%__ToolsetDir%

if /i "%__ToolsetDir%" == "" (
    echo %__MsgPrefix%Error: A toolset directory is required for the Arm64 Windows build. Use the toolset_dir argument.
    exit /b 1
)

if not exist "%__ToolsetDir%"\buildenv_arm64.cmd goto :Not_EWDK
call "%__ToolsetDir%"\buildenv_arm64.cmd
exit /b 0

:Not_EWDK
set PATH=%__ToolsetDir%\VC_sdk\bin;%PATH%
set LIB=%__ToolsetDir%\VC_sdk\lib\arm64;%__ToolsetDir%\sdpublic\sdk\lib\arm64
set INCLUDE=^
%__ToolsetDir%\VC_sdk\inc;^
%__ToolsetDir%\sdpublic\sdk\inc;^
%__ToolsetDir%\sdpublic\shared\inc;^
%__ToolsetDir%\sdpublic\shared\inc\minwin;^
%__ToolsetDir%\sdpublic\sdk\inc\ucrt;^
%__ToolsetDir%\sdpublic\sdk\inc\minwin;^
%__ToolsetDir%\sdpublic\sdk\inc\mincore;^
%__ToolsetDir%\sdpublic\sdk\inc\abi;^
%__ToolsetDir%\sdpublic\sdk\inc\clientcore;^
%__ToolsetDir%\diasdk\include
exit /b 0
