
# Логирование событий
function Log-Event {
  param (
    [string]$Message
  )

    $Stamp = (Get-Date).toString("yyyy/MM/dd HH:mm:ss")
    $LogMessage = "$Stamp $Message"
    Add-content "C:\tasksheduler-scripts\CleanUsersFiles.log" -value $LogMessage
   
}

function SearchAndMoveFiles {
    param (
    [string]$UserPath,
    [string]$destinationPath
)
    # Ищем файлы
    $filesFound = @()
    
    if ((Get-ChildItem -Path $UserPath -Include "1Cv8.1CD", "*.cf", "*.dt" -Recurse).Count -gt 0) {
        
        foreach ($file in (Get-ChildItem -Path $UserPath -Include "1Cv8.1CD", "*.cf", "*.dt" -Recurse)) {
            if ((Test-Path -Path $file.FullName) -eq $true) {
                $filesFound += ,$file
            }
        }
    }
        
    foreach ($file in $filesFound) {
        
        # Создаем каталог если его нет
        if (-Not (Test-Path -Path $destinationPath))
            {
            New-Item -ItemType Directory -Path $destinationPath
        }
        
        if ($file.Name -eq "1Cv8.1CD") {
            
            ##Находим каталоги расположения файла 1Cv8.1CD и перемещаем их в созданный каталог:
            $PathInfobase1C = $file.FullName | Split-Path    
            Move-Item -Path $PathInfobase1C -Destination $destinationPath -Force
        
        } elseif ($file.Name -match ".*\.cf" -or $file.Name -match ".*\.dt") {
            
            Move-Item -Path $file.FullName -Destination $destinationPath -Force
        } 
    }
    
}


#_main

Log-Event -Message "---Start operation SearchAndMoveFiles"

$UsersPath = "C:\Users"

cd $UsersPath

$AllUsers = Get-ChildItem $UsersPath -Exclude "test" | Where-Object {$_.Name -match "^[a-z]"}

#---Очистка папок профилей пользователей---
ForEach ($U in $AllUsers) {
    #исключение пользователей при необходимости
    if ($U.Name -ne "username") {
        Remove-Item "$U\AppData\Local\1C\1Cv8\*"  -Force -Recurse -Exclude *.pfl
        Remove-Item "$U\AppData\Roaming\1C\1Cv8\*" -Force -Recurse -Exclude *.pfl
        Remove-Item "$U\AppData\Roaming\1C\1Cv82\*" -Force -Recurse -Exclude *.pfl
    }
}

# Для каждого пользователя ищем файлы
ForEach ($User in $AllUsers) {
    
    $username = $User.Name
    
    # Путь к каталогу текущего пользователя
    $UserPath = $UsersPath + "\" + $User.Name 
    $destinationPath = "R:\_FilesOnDelete\$($username)"

    # Ищем и перемещаем файлы
    try {
        
        SearchAndMoveFiles  -UserPath $UserPath -destinationPath $destinationPath
        Log-Event -Message "Successfully execution operation SearchAndMoveFiles for user $($username)"

    } catch {
        
        Log-Event -Message "Failed to execution SearchAndMoveFiles operation: $($Error[0].Message)"

    }

}

Log-Event -Message "---End operation SearchAndMoveFiles"
