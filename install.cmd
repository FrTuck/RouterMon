@echo off
rem RouterMon: установка с любого ПК с Windows 10/11 двойным щелчком.
rem Спросит IP основного роутера (подставит шлюз ПК), поставит RouterMon и предложит поставить на другие найденные роутеры OpenWrt.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
