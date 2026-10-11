@echo off
rem Build sbx.exe and wvt.exe with the Visual Studio 2022 C++ tools (libraries are linked by #pragma in the sources).
call "%~dp0..\vsenv.bat" || exit /b 1
cd /d "%~dp0"
cl /nologo /O2 /TC sbx.c || exit /b 1
cl /nologo /O2 /TC wvt.c || exit /b 1
