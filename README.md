# README (English)

This repository contains a PowerShell script designed to clean up user profiles and move specific files from those profiles to a designated directory.

**Functionality**

The script performs the following tasks:

1. Logs event messages in a log file.
2. Scans user profiles for specified files and moves them to a destination directory.
3. Cleans up temporary files and directories within user profiles.

**Requirements**

* PowerShell 5 or later
* Windows operating system

**Installation**

To use this script, simply clone the repository and run the `CleanUsersFiles.ps1` file in PowerShell.

**Usage**

The script requires minimal input and can be run with the following command:
```powershell
.\CleanUsersFiles.ps1
```
This will execute the script and perform the necessary cleaning and moving of files.

# README (Russian)

Этот репозиторий содержит скрипт на PowerShell, который предназначен для очистки профилей пользователей 
и перемещает определенные файлы из этих профилей в назначенный каталог.

**Функциональность**

скрипт выполняет следующие задачи:

1. Регистрирует сообщения событий в файле логов.
2. Анализирует профили пользователей и перемещает определенные файлы в назначенный каталог.
3. Очищает temporary файлы и директории из профилей пользователей.

**Правила**

* PowerShell 5 или большей версии
* ОС Windows

**Установка**

Чтобы использовать этот скрипт, просто клонируйте репозиторий и запустите файл `CleanUsersFiles.ps1` в PowerShell.

**Использование**

Скрипт требует минимального входа и может быть запущен с помощью следующей команды:
```powershell
.\CleanUsersFiles.ps1
```
Эта команда выполнит скрипт и проведет необходимые очистки и перемещение файлов.

**Заметки**

* Скрипт записывает логи событий в файл `C:\tasksheduler-scripts\CleanUsersFiles.log`.
* Этот скрипт следует использовать с осторожностью, поскольку он может удалить важные файлы или директории.