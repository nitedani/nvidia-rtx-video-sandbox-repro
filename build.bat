@echo off
rem Build repro.exe with the Visual Studio 2022 C++ tools. Libraries are linked by #pragma in the source.
call "%~dp0vsenv.bat" || exit /b 1
cd /d "%~dp0"
cl /nologo /EHsc /O2 /Zi repro.cpp
