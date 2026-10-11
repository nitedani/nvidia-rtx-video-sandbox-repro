@echo off
rem Puts the Visual Studio 2022 C++ tools (cl, 64-bit) on PATH for the caller: call "%~dp0vsenv.bat" || exit /b 1
where cl >nul 2>nul && exit /b 0
rem vcvars64.bat itself runs vswhere.exe from PATH.
set "PATH=%PATH%;%ProgramFiles(x86)%\Microsoft Visual Studio\Installer"
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do call "%%i\VC\Auxiliary\Build\vcvars64.bat" >nul
where cl >nul 2>nul || (echo Visual Studio C++ tools not found: install the "Desktop development with C++" workload. & exit /b 1)
