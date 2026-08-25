#Requires -Version 5.1
<#
.SYNOPSIS
    Audit complet d'une infrastructure Veeam Backup & Replication.
    Compatible Veeam B&R v12.x et v13.x.
    Par TCR - boosté par Claude Code

.DESCRIPTION
    Collecte et restitue :
      - Les jobs de sauvegarde disque (type, planification, retention, GFS, chiffrement, CBT, dernier resultat...)
      - Les repositories (type, hote, capacite, immuabilite, hardened, SOBR, jobs associes...)
      - L'infrastructure (serveur VBR, version/build, OS, licence, proxies, serveurs manages, base de donnees, services)
      - Les sauvegardes sur bande, traitees separement : jobs, media pools, etat des bandes,
        serveurs de bande, bibliotheques et lecteurs
      - SureBackup : virtual labs, application groups et jobs de verification
      - La storage infrastructure : baies SAN integrees (snapshots SAN / SanHost) uniquement

    Le script est ecrit de maniere defensive : chaque cmdlet et chaque propriete est sondee
    au moment de l'execution. Les differences de modele objet entre la v12 et la v13
    (cmdlets renommees/depreciees, proprietes deplacees) n'interrompent donc pas l'audit :
    une valeur non disponible est restituee en "N/A" et tracee dans le journal.

.PARAMETER Server
    Serveur Veeam Backup & Replication a auditer. Par défaut : localhost.

.PARAMETER Port
    Port de la console VBR (9392 par defaut).

.PARAMETER Credential
    Compte utilise pour la connexion au serveur VBR. Si omis, le compte courant est utilise.

.PARAMETER OutputPath
    Dossier de sortie des rapports. Cree s'il n'existe pas.

.PARAMETER Format
    Formats de sortie : HTML, CSV, JSON ou All. Par défaut : HTML et CSV.

.PARAMETER TapeMediaLimit
    Nombre maximal de bandes detaillees dans le rapport (500 par defaut).
    La synthese par media pool porte toujours sur la totalite des bandes.

.PARAMETER SkipRemoteQueries
    N'interroge pas les serveurs distants (WMI/CIM, services, registre).
    Accelere l'audit et evite les erreurs si le RPC/WinRM est filtre.

.PARAMETER KeepConnection
    Ne ferme pas la session VBR a la fin du script.

.PARAMETER PassThru
    Retourne l'objet d'audit complet sur le pipeline.

.EXAMPLE
    .\Invoke-VeeamAudit.ps1

.EXAMPLE
    .\Invoke-VeeamAudit.ps1 -Server vbr01.contoso.local -Credential (Get-Credential) -Format All

.EXAMPLE
    .\Invoke-VeeamAudit.ps1 -SkipRemoteQueries -OutputPath D:\Audits\Veeam

.NOTES
    Necessite la console Veeam Backup & Replication (module Veeam.Backup.PowerShell)
    installee sur la machine d'execution.
    Droits recommandes : Veeam Backup Administrator + lecture WMI sur les serveurs manages.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Server = 'localhost',

    [Parameter()]
    [int]$Port = 9392,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [string]$OutputPath = (Join-Path -Path (Get-Location).Path -ChildPath 'VeeamAudit'),

    [Parameter()]
    [ValidateSet('HTML', 'CSV', 'JSON', 'All')]
    [string[]]$Format = @('HTML', 'CSV'),

    [Parameter()]
    [ValidateRange(0, 100000)]
    [int]$TapeMediaLimit = 500,

    [Parameter()]
    [switch]$SkipRemoteQueries,

    [Parameter()]
    [switch]$KeepConnection,

    [Parameter()]
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$script:StartTime  = Get-Date
$script:AuditLog   = New-Object System.Collections.Generic.List[psobject]
$script:Connected  = $false
$script:NA         = 'N/A'

if ($Format -contains 'All') { $Format = @('HTML', 'CSV', 'JSON') }

#region ---------------------------------------------------------------- Utilitaires

function Write-AuditLog {
    <#  Journalise et affiche un evenement d'audit. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'STEP', 'OK')][string]$Level = 'INFO'
    )

    $script:AuditLog.Add([pscustomobject]@{
        Horodatage = Get-Date
        Niveau     = $Level
        Message    = $Message
    })

    $color = switch ($Level) {
        'STEP'  { 'Cyan' }
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }
    $prefix = switch ($Level) {
        'STEP'  { '==>' }
        'OK'    { ' [OK]   ' }
        'WARN'  { ' [WARN]  ' }
        'ERROR' { ' [ERREUR]' }
        default { ' [INFO]  ' }
    }
    Write-Host ("{0} {1}" -f $prefix, $Message) -ForegroundColor $color
}

function Test-VBRCommand {
    <#  Indique si une cmdlet existe dans la version de module chargee. #>
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Invoke-VBRCommand {
    <#
        Execute une cmdlet Veeam si elle existe dans la version installee.
        Retourne toujours un tableau (vide en cas d'absence ou d'erreur).
        C'est le principal mecanisme de compatibilite v12 / v13.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Parameters = @{},
        [switch]$Quiet
    )

    if (-not (Test-VBRCommand -Name $Name)) {
        if (-not $Quiet) { Write-AuditLog "Cmdlet '$Name' absente de cette version de Veeam - ignorée." -Level INFO }
        return @()
    }

    try {
        $result = & $Name @Parameters -ErrorAction Stop -WarningAction SilentlyContinue
        if ($null -eq $result) { return @() }
        return @($result)
    }
    catch {
        if (-not $Quiet) { Write-AuditLog "Échec de '$Name' : $($_.Exception.Message)" -Level WARN }
        return @()
    }
}

function Get-Prop {
    <#
        Lit la premiere propriete disponible parmi plusieurs chemins candidats.
        Permet d'absorber les deplacements de proprietes entre v12 et v13.
        Exemple : Get-Prop $job @('Info.LatestStatus','LastResult') -Default 'N/A'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [Parameter(Mandatory)][string[]]$Path,
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }

    foreach ($candidate in $Path) {
        try {
            $current = $InputObject
            foreach ($segment in $candidate.Split('.')) {
                if ($null -eq $current) { break }
                $current = $current.$segment
            }
            if ($null -eq $current) { continue }

            # Le test de presence ne doit jamais passer par une conversion en chaine :
            # un tableau d'objets Veeam (extents d'un SOBR, objets sources d'un job...)
            # se stringifie en chaine vide et serait alors ecarte a tort.
            if ($current -is [string]) {
                if ($current -ne '') { return $current }
            }
            elseif ($current -isnot [System.Collections.IEnumerable]) {
                return $current
            }
            elseif (@($current).Count -gt 0) {
                return $current
            }
        }
        catch { continue }
    }
    return $Default
}

function Invoke-SafeMethod {
    <#  Appelle une methode uniquement si elle existe sur l'objet (jamais d'exception). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Method,
        [object[]]$Arguments = @()
    )

    if ($null -eq $InputObject) { return $null }
    try {
        $member = $InputObject.PSObject.Methods[$Method]
        if ($null -eq $member) { return $null }
        if ($Arguments.Count -gt 0) { return $member.Invoke($Arguments) }
        return $member.Invoke()
    }
    catch { return $null }
}

function ConvertTo-YesNo {
    <#  Normalise un booleen (ou null) en Oui / Non / N/A. #>
    param([AllowNull()]$Value, [string]$Unknown = $script:NA)
    if ($null -eq $Value) { return $Unknown }
    if ($Value -is [bool]) { if ($Value) { return 'Oui' } else { return 'Non' } }
    switch -Regex ("$Value") {
        '^(True|1|Enabled|Yes)$'  { return 'Oui' }
        '^(False|0|Disabled|No)$' { return 'Non' }
        default                   { return "$Value" }
    }
}

function Format-Size {
    <#  Convertit un nombre d'octets en unite lisible. #>
    param([AllowNull()]$Bytes)
    if ($null -eq $Bytes) { return $script:NA }
    try { $value = [double]$Bytes } catch { return $script:NA }
    if ($value -le 0) { return '0 o' }

    $units = @('o', 'Ko', 'Mo', 'Go', 'To', 'Po')
    $index = 0
    while ($value -ge 1024 -and $index -lt ($units.Count - 1)) {
        $value = $value / 1024
        $index++
    }
    return ('{0:N2} {1}' -f $value, $units[$index])
}

function Format-DateValue {
    <#  Formate une date en jj/MM/aaaa HH:mm, en filtrant les dates sentinelles Veeam. #>
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $script:NA }
    try {
        $date = [datetime]$Value
        if ($date.Year -le 1900 -or $date.Year -ge 9999) { return $script:NA }
        return $date.ToString('dd/MM/yyyy HH:mm')
    }
    catch { return $script:NA }
}

function ConvertTo-Percent {
    param([AllowNull()]$Part, [AllowNull()]$Total)
    if ($null -eq $Part -or $null -eq $Total) { return $null }
    try {
        $t = [double]$Total
        if ($t -le 0) { return $null }
        return [math]::Round((([double]$Part) / $t) * 100, 1)
    }
    catch { return $null }
}

function Join-Values {
    <#  Concatene une collection en chaine lisible, en ignorant les valeurs vides. #>
    param([AllowNull()]$Values, [string]$Separator = ', ', [string]$Empty = $script:NA)
    if ($null -eq $Values) { return $Empty }
    $items = @($Values | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { "$_" })
    if ($items.Count -eq 0) { return $Empty }
    return ($items -join $Separator)
}

#endregion


#region ---------------------------------------------------------------- Connexion & version

function Connect-VeeamServer {
    <#  Charge le module Veeam (module v12/v13, ou snap-in historique) et ouvre la session. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerName,
        [int]$ServerPort = 9392,
        [System.Management.Automation.PSCredential]$ServerCredential
    )

    Write-AuditLog "Chargement du module PowerShell Veeam..." -Level STEP

    $loaded = $false
    foreach ($moduleName in @('Veeam.Backup.PowerShell', 'Veeam.Backup.PowerShell.Cmdlets')) {
        if (Get-Module -Name $moduleName) { $loaded = $true; break }
        try {
            Import-Module -Name $moduleName -DisableNameChecking -ErrorAction Stop -WarningAction SilentlyContinue
            Write-AuditLog "Module '$moduleName' charge." -Level OK
            $loaded = $true
            break
        }
        catch { }
    }

    if (-not $loaded) {
        # Repli sur le snap-in des versions anterieures (Windows PowerShell uniquement).
        try {
            if (Get-Command -Name Add-PSSnapin -ErrorAction SilentlyContinue) {
                Add-PSSnapin -Name VeeamPSSnapIn -ErrorAction Stop
                Write-AuditLog "Snap-in 'VeeamPSSnapIn' chargé (version antérieure détectée)." -Level WARN
                $loaded = $true
            }
        }
        catch { }
    }

    if (-not $loaded -or -not (Test-VBRCommand -Name 'Connect-VBRServer')) {
        throw "Module PowerShell Veeam introuvable. Installez la console Veeam Backup & Replication sur cette machine, puis relancez le script."
    }

    # Session deja ouverte sur le bon serveur ?
    $existing = Invoke-VBRCommand -Name 'Get-VBRServerSession' -Quiet
    if ($existing -and $existing.Count -gt 0) {
        $currentName = Get-Prop $existing[0] @('Server.Name', 'Server', 'Name')
        if ($currentName -and ($ServerName -in @('localhost', '.', $env:COMPUTERNAME) -or "$currentName" -like "$ServerName*")) {
            Write-AuditLog "Session VBR déjà ouverte sur '$currentName' - réutilisation." -Level OK
            return $true
        }
        Invoke-VBRCommand -Name 'Disconnect-VBRServer' -Quiet | Out-Null
    }

    Write-AuditLog "Connexion a '$ServerName' (port $ServerPort)..." -Level STEP
    $connectParams = @{ Server = $ServerName; Port = $ServerPort }
    if ($ServerCredential) { $connectParams['Credential'] = $ServerCredential }

    try {
        Connect-VBRServer @connectParams -ErrorAction Stop
    }
    catch {
        # Certaines builds n'exposent pas -Port : nouvel essai sans ce parametre.
        $connectParams.Remove('Port') | Out-Null
        Connect-VBRServer @connectParams -ErrorAction Stop
    }

    Write-AuditLog "Connecté au serveur Veeam '$ServerName'." -Level OK
    return $true
}

function Get-VeeamVersionInfo {
    <#
        Determine version et build. Plusieurs sources sont sondees car aucune
        n'est disponible sur toutes les editions (v13 en appliance Linux notamment).
    #>
    [CmdletBinding()]
    param([string]$ServerName)

    $result = [ordered]@{
        Version       = $script:NA
        Build         = $script:NA
        VersionMajeur = $script:NA
        Source        = $script:NA
    }

    # 1. Session VBR (fonctionne y compris sur serveur distant / appliance)
    $session = Invoke-VBRCommand -Name 'Get-VBRServerSession' -Quiet
    if ($session -and $session.Count -gt 0) {
        $ver = Get-Prop $session[0] @('Server.Version', 'Server.ProductVersion', 'Version')
        if ($ver) {
            $result.Version = "$ver"
            $result.Source  = 'Session VBR'
        }
    }

    # 2. Assembly Veeam chargee en memoire par le module
    if ($result.Version -eq $script:NA) {
        try {
            $asm = [AppDomain]::CurrentDomain.GetAssemblies() |
                   Where-Object { $_.GetName().Name -eq 'Veeam.Backup.Core' } |
                   Select-Object -First 1
            if ($asm -and -not [string]::IsNullOrWhiteSpace($asm.Location)) {
                $fileVersion = (Get-Item -LiteralPath $asm.Location).VersionInfo.ProductVersion
                if ($fileVersion) {
                    $result.Version = "$fileVersion"
                    $result.Source  = 'Assembly Veeam.Backup.Core'
                }
            }
        }
        catch { }
    }

    # 3. Registre local (serveur VBR sous Windows)
    if ($result.Version -eq $script:NA) {
        try {
            $regPath = 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication'
            if (Test-Path -LiteralPath $regPath) {
                $reg = Get-ItemProperty -LiteralPath $regPath -ErrorAction Stop
                $ver = Get-Prop $reg @('CurrentVersion', 'ProductVersion', 'Version')
                if ($ver) {
                    $result.Version = "$ver"
                    $result.Source  = 'Registre local'
                }
                $corePath = Get-Prop $reg @('CorePath')
                if ($corePath) {
                    $dll = Join-Path -Path $corePath -ChildPath 'Veeam.Backup.Core.dll'
                    if (Test-Path -LiteralPath $dll) {
                        $result.Build  = (Get-Item -LiteralPath $dll).VersionInfo.ProductVersion
                        $result.Source = 'Registre local + DLL noyau'
                    }
                }
            }
        }
        catch { }
    }

    # 4. Cle de desinstallation (donne le build complet)
    if ($result.Build -eq $script:NA) {
        try {
            $uninstall = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                         Where-Object { $_.DisplayName -like 'Veeam Backup & Replication Server*' -or $_.DisplayName -like 'Veeam Backup*Replication*Server*' } |
                         Select-Object -First 1
            if ($uninstall -and $uninstall.DisplayVersion) {
                $result.Build = "$($uninstall.DisplayVersion)"
                if ($result.Version -eq $script:NA) {
                    $result.Version = "$($uninstall.DisplayVersion)"
                }
                if ($result.Source -eq $script:NA) { $result.Source = 'Registre (desinstallation)' }
            }
        }
        catch { }
    }

    if ($result.Build -eq $script:NA -and $result.Version -ne $script:NA) {
        $result.Build = $result.Version
    }

    # Version majeure : sert a adapter les traitements v12 / v13
    $reference = if ($result.Build -ne $script:NA) { $result.Build } else { $result.Version }
    if ($reference -match '^(\d+)\.') {
        $result.VersionMajeur = [int]$Matches[1]
    }

    return [pscustomobject]$result
}

#endregion

#region ---------------------------------------------------------------- Decodage des options

function ConvertFrom-CompressionLevel {
    <#  Traduit le niveau de compression numerique Veeam en libelle. #>
    param([AllowNull()]$Level)
    if ($null -eq $Level) { return $script:NA }
    switch ([string]$Level) {
        '-1'    { return 'Automatique' }
        '0'     { return 'Aucune' }
        '4'     { return 'Dedup-friendly' }
        '5'     { return 'Optimal (recommandé)' }
        '6'     { return 'High' }
        '9'     { return 'Extreme' }
        default { return "Niveau $Level" }
    }
}

function ConvertFrom-BlockSize {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $script:NA }
    switch -Regex ("$Value") {
        'KbBlockSize256|Local'   { return '256 Ko (Local target - large blocks)' }
        'KbBlockSize512|LAN'     { return '512 Ko (Local target)' }
        'KbBlockSize1024|WAN'    { return '1 Mo (LAN target)' }
        'KbBlockSize4096'        { return '4 Mo (WAN target)' }
        'KbBlockSize8192'        { return '8 Mo' }
        default                  { return "$Value" }
    }
}

function Get-JobRetentionText {
    <#  Restitue la retention (points de restauration ou jours) quelle que soit la version. #>
    [CmdletBinding()]
    param($JobOptions)

    if ($null -eq $JobOptions) { return $script:NA }

    $storage = Get-Prop $JobOptions @('BackupStorageOptions')

    $type   = Get-Prop $storage @('RetentionType')
    $days   = Get-Prop $storage @('RetainDaysToKeep', 'RetainDays')
    $cycles = Get-Prop $storage @('RetainCycles')
    # GenerationPolicy.SimpleRetentionRestorePoints : specifique aux Backup Copy Jobs (repli).
    if ($null -eq $cycles) {
        $generationLegacy = Get-Prop $storage @('GenerationPolicy') -Default (Get-Prop $JobOptions @('GenerationPolicy'))
        $cycles = Get-Prop $generationLegacy @('SimpleRetentionRestorePoints')
    }

    $parts = New-Object System.Collections.Generic.List[string]

    if ("$type" -match 'Day') {
        if ($days) { $parts.Add("$days jour(s)") }
    }
    elseif ($cycles) {
        $parts.Add("$cycles point(s) de restauration")
    }
    elseif ($days) {
        $parts.Add("$days jour(s)")
    }

    # Retention des VM supprimees (deleted items retention) : propriete de BackupStorageOptions,
    # pas de l'objet GFS.
    $deletedEnabled = Get-Prop $storage @('EnableDeletedVmDataRetention')
    $deletedPeriod  = Get-Prop $storage @('DeletedVmsDataRetentionPeriodDays', 'RetainDaysToKeep')
    if ($deletedEnabled -eq $true -and $deletedPeriod) {
        $parts.Add("éléments supprimés : $deletedPeriod jour(s)")
    }

    if ($parts.Count -eq 0) { return $script:NA }
    return ($parts -join ' | ')
}

function Get-JobGfsText {
    <#
        Restitue la politique GFS (hebdo / mensuel / trimestriel / annuel).
        Depuis la v12, la GFS est portee par la propriete GfsPolicy directement sous les
        options du job (pas sous BackupStorageOptions). L'ancien chemin GenerationPolicy
        (Backup Copy Jobs) reste sonde en repli.
    #>
    [CmdletBinding()]
    param($JobOptions)

    if ($null -eq $JobOptions) { return $script:NA }

    $storage    = Get-Prop $JobOptions @('BackupStorageOptions')
    $generation = Get-Prop $JobOptions @('GfsPolicy')
    if ($null -eq $generation) { $generation = Get-Prop $storage @('GenerationPolicy') }
    if ($null -eq $generation) { $generation = Get-Prop $JobOptions @('GenerationPolicy') }
    if ($null -eq $generation) { return 'Non activée' }

    $enabled = Get-Prop $generation @('IsEnabled', 'IsGFSOptionsEnabled', 'EnableGfsRetentionPolicy')
    $type    = Get-Prop $storage    @('RetentionType')

    $weekly    = Get-Prop $generation @('Weekly.KeepBackupsForNumberOfWeeks',       'GFSWeeklyBackups',    'WeeklyBackup.DesiredTime',    'GFSWeekly')
    $monthly   = Get-Prop $generation @('Monthly.KeepBackupsForNumberOfMonths',     'GFSMonthlyBackups',   'MonthlyBackup.DesiredTime',   'GFSMonthly')
    $quarterly = Get-Prop $generation @('Quarterly.KeepBackupsForNumberOfQuarters', 'GFSQuarterlyBackups', 'QuarterlyBackup.DesiredTime', 'GFSQuarterly')
    $yearly    = Get-Prop $generation @('Yearly.KeepBackupsForNumberOfYears',       'GFSYearlyBackups',    'YearlyBackup.DesiredTime',    'GFSYearly')

    $weeklyOn    = Get-Prop $generation @('Weekly.IsEnabled',    'WeeklyBackup.Enabled')
    $monthlyOn   = Get-Prop $generation @('Monthly.IsEnabled',   'MonthlyBackup.Enabled')
    $quarterlyOn = Get-Prop $generation @('Quarterly.IsEnabled', 'QuarterlyBackup.Enabled')
    $yearlyOn    = Get-Prop $generation @('Yearly.IsEnabled',    'YearlyBackup.Enabled')

    $parts = New-Object System.Collections.Generic.List[string]
    if ($weekly    -and [int]"$weekly"    -gt 0 -and $weeklyOn    -ne $false) { $parts.Add("Hebdo : $weekly")          }
    if ($monthly   -and [int]"$monthly"   -gt 0 -and $monthlyOn   -ne $false) { $parts.Add("Mensuel : $monthly")       }
    if ($quarterly -and [int]"$quarterly" -gt 0 -and $quarterlyOn -ne $false) { $parts.Add("Trimestriel : $quarterly") }
    if ($yearly    -and [int]"$yearly"    -gt 0 -and $yearlyOn    -ne $false) { $parts.Add("Annuel : $yearly")         }

    if ($parts.Count -gt 0) { return ($parts -join ' | ') }
    if ($enabled -eq $true -or "$type" -match 'GFS') { return 'Activée (détails indisponibles)' }
    return 'Non activée'
}

function Get-JobScheduleText {
    <#
        Analyse les options de planification et retourne un objet
        { Planification ; HeureExecution ; Jours ; ProchaineExecution }.
    #>
    [CmdletBinding()]
    param($Schedule)

    $result = [ordered]@{
        Planification      = 'Manuelle (aucune planification)'
        HeureExecution     = $script:NA
        Jours              = $script:NA
        ProchaineExecution = $script:NA
    }

    if ($null -eq $Schedule) { return [pscustomobject]$result }

    $nextRun = Get-Prop $Schedule @('NextRun')
    if ($nextRun) { $result.ProchaineExecution = Format-DateValue $nextRun }

    # --- Quotidien / jours selectionnes
    $daily = Get-Prop $Schedule @('OptionsDaily')
    if ($daily -and (Get-Prop $daily @('Enabled')) -eq $true) {
        $kind = "$(Get-Prop $daily @('Kind') -Default 'Everyday')"
        $result.Planification  = switch -Regex ($kind) {
            'Everyday'     { 'Quotidienne - tous les jours' }
            'WeekDays'     { 'Quotidienne - jours ouvrés' }
            'SelectedDays' { 'Quotidienne - jours sélectionnés' }
            default        { "Quotidienne ($kind)" }
        }
        $result.HeureExecution = Format-TimeValue (Get-Prop $daily @('TimeLocal', 'TimeSrv', 'Time'))
        $days = Get-Prop $daily @('Days', 'DaysSrv')
        $result.Jours = if ($kind -match 'Everyday') { 'Tous les jours' } else { Join-Values $days }
        return [pscustomobject]$result
    }

    # --- Mensuel
    $monthly = Get-Prop $Schedule @('OptionsMonthly')
    if ($monthly -and (Get-Prop $monthly @('Enabled')) -eq $true) {
        $dayNumber = Get-Prop $monthly @('DayNumberInMonth')
        $dayOfWeek = Get-Prop $monthly @('DayOfWeek')
        $dayOfMonth = Get-Prop $monthly @('DayOfMonth')
        $months    = Get-Prop $monthly @('Months')

        $result.Planification  = 'Mensuelle'
        $result.HeureExecution = Format-TimeValue (Get-Prop $monthly @('TimeLocal', 'TimeSrv', 'Time'))

        $detail = New-Object System.Collections.Generic.List[string]
        if ("$dayNumber" -match 'OnDay' -and $dayOfMonth) { $detail.Add("le $dayOfMonth du mois") }
        elseif ($dayNumber -or $dayOfWeek)                { $detail.Add((Join-Values @($dayNumber, $dayOfWeek) -Separator ' ')) }
        if ($months) { $detail.Add("mois : $(Join-Values $months)") }
        $result.Jours = Join-Values $detail -Separator ' - '
        return [pscustomobject]$result
    }

    # --- Periodique (toutes les N heures/minutes)
    $periodically = Get-Prop $Schedule @('OptionsPeriodically')
    if ($periodically -and (Get-Prop $periodically @('Enabled')) -eq $true) {
        $period = Get-Prop $periodically @('FullPeriod')
        $unit   = "$(Get-Prop $periodically @('PeriodicallyKind') -Default 'Hours')"
        $unitFr = if ($unit -match 'Min') { 'minute(s)' } else { 'heure(s)' }
        $result.Planification  = "Périodique - toutes les $period $unitFr"
        $result.HeureExecution = 'En continu (fenêtre planifiée)'
        $result.Jours          = 'Selon fenêtre horaire'
        return [pscustomobject]$result
    }

    # --- Continu (CDP / near-CDP)
    $continuous = Get-Prop $Schedule @('OptionsContinuous')
    if ($continuous -and (Get-Prop $continuous @('Enabled')) -eq $true) {
        $result.Planification  = 'Continue'
        $result.HeureExecution = 'Permanent'
        $result.Jours          = 'Tous les jours'
        return [pscustomobject]$result
    }

    # --- Chainage apres un autre job
    $afterJob = Get-Prop $Schedule @('OptionsScheduleAfterJob')
    if ($afterJob -and ((Get-Prop $afterJob @('IsEnabled', 'Enabled')) -eq $true)) {
        $result.Planification  = 'Après un autre job (chaînage)'
        $result.HeureExecution = 'Déclenchement par job parent'
        $result.Jours          = 'Selon job parent'
        return [pscustomobject]$result
    }

    return [pscustomobject]$result
}

function Format-TimeValue {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $script:NA }
    try {
        if ($Value -is [timespan]) { return ([timespan]$Value).ToString('hh\:mm') }
        return ([datetime]$Value).ToString('HH:mm')
    }
    catch { return "$Value" }
}

#endregion


#region ---------------------------------------------------------------- Collecte des jobs

function Get-AllVeeamJobs {
    <#
        Recupere les jobs via toutes les cmdlets disponibles puis dedoublonne par Id.
        En v12 Get-VBRJob couvre l'essentiel ; en v13 certains types de jobs ne sont
        exposes que par leurs cmdlets dediees, d'ou l'agregation.
    #>
    [CmdletBinding()]
    param()

    $cmdlets = @(
        'Get-VBRJob',
        'Get-VBRComputerBackupJob',
        'Get-VBRUnstructuredBackupJob',
        'Get-VBRCDPPolicy',
        'Get-VBRBackupCopyJob'
    )

    $all  = New-Object System.Collections.Generic.List[psobject]
    $seen = New-Object System.Collections.Generic.HashSet[string]

    foreach ($cmdlet in $cmdlets) {
        $jobs = Invoke-VBRCommand -Name $cmdlet -Quiet
        if ($jobs.Count -eq 0) { continue }

        $added   = 0
        $skipped = 0
        foreach ($job in $jobs) {
            # Les jobs de bande et SureBackup ont leurs propres sections : Get-VBRJob
            # les remonte aussi, on les ecarte ici pour eviter les doublons.
            $jobType = "$(Get-Prop $job @('JobType', 'TypeToString', 'Type'))"
            if ($jobType -match 'Tape|SureBackup') { $skipped++; continue }

            $id = "$(Get-Prop $job @('Id', 'Info.Id', 'JobId'))"
            if ([string]::IsNullOrWhiteSpace($id)) { $id = "$(Get-Prop $job @('Name'))|$cmdlet" }
            if ($seen.Add($id)) {
                $all.Add($job) | Out-Null
                $added++
            }
        }
        $message = "$cmdlet : $added job(s) ajoute(s)."
        if ($skipped -gt 0) { $message += " $skipped job(s) bande/SureBackup renvoye(s) vers leur section dediee." }
        Write-AuditLog $message -Level INFO
    }

    return $all
}

function Get-JobProxyText {
    <#  Determine les proxies affectes au job (ou le mode automatique). #>
    [CmdletBinding()]
    param($Job, $JobOptions)

    # Detection automatique demandee dans les options de la source ?
    $autoVi = Get-Prop $JobOptions @('ViSourceOptions.BackupProxyAutoDetect')
    $autoHv = Get-Prop $JobOptions @('HvSourceOptions.BackupProxyAutoDetect')
    if ($autoVi -eq $true -or $autoHv -eq $true) { return 'Automatique (sélection auto)' }

    # Methode portee par l'objet job (v12 et v13)
    $proxies = Invoke-SafeMethod -InputObject $Job -Method 'GetProxy'
    if ($null -eq $proxies -or @($proxies).Count -eq 0) {
        $proxies = Invoke-SafeMethod -InputObject $Job -Method 'GetProxies'
    }

    # Repli : cmdlet dediee
    if ($null -eq $proxies -or @($proxies).Count -eq 0) {
        if (Test-VBRCommand -Name 'Get-VBRJobProxy') {
            $proxies = Invoke-VBRCommand -Name 'Get-VBRJobProxy' -Parameters @{ Job = $Job } -Quiet
        }
    }

    if ($null -eq $proxies -or @($proxies).Count -eq 0) { return 'Automatique / non applicable' }

    $names = @($proxies | ForEach-Object { Get-Prop $_ @('Name', 'Info.Name', 'Host.Name') } | Where-Object { $_ })
    if ($names.Count -eq 0) { return 'Automatique / non applicable' }
    return (Join-Values $names)
}

function Get-JobRepositoryInfo {
    <#  Identifie le repository cible du job, quelle que soit la version. #>
    [CmdletBinding()]
    param($Job, [hashtable]$RepositoryIndex)

    $repo = Invoke-SafeMethod -InputObject $Job -Method 'GetTargetRepository'
    if ($null -eq $repo) { $repo = Invoke-SafeMethod -InputObject $Job -Method 'FindTargetRepository' }

    if ($null -eq $repo) {
        $repoId = "$(Get-Prop $Job @('Info.TargetRepositoryId', 'TargetRepositoryId', 'BackupRepository.Id', 'Storage.Id'))"
        if ($repoId -and $RepositoryIndex.ContainsKey($repoId)) {
            $repo = $RepositoryIndex[$repoId]
        }
    }

    if ($null -eq $repo) {
        # Jobs agent / unstructured : le repository est parfois expose directement.
        $direct = Get-Prop $Job @('BackupRepository.Name', 'Storage.Name', 'TargetRepository.Name')
        if ($direct) {
            return [pscustomobject]@{ Nom = "$direct"; Id = $null }
        }
        return [pscustomobject]@{ Nom = $script:NA; Id = $null }
    }

    return [pscustomobject]@{
        Nom = "$(Get-Prop $repo @('Name', 'Info.Name') -Default $script:NA)"
        Id  = "$(Get-Prop $repo @('Id', 'Info.Id'))"
    }
}

function Get-JobObjectsText {
    <#
        Liste des objets (VM, ordinateurs, dossiers, fichiers, bases...) inclus dans le job.
        La methode portee par l'objet job couvre la plupart des types ; a defaut,
        la cmdlet Get-VBRJobObject sert de repli.
    #>
    [CmdletBinding()]
    param($Job)

    $objects = Invoke-SafeMethod -InputObject $Job -Method 'GetObjectsInJob'
    if ($null -eq $objects -or @($objects).Count -eq 0) {
        $objects = Invoke-SafeMethod -InputObject $Job -Method 'GetViOijs'
    }
    if ($null -eq $objects -or @($objects).Count -eq 0) {
        if (Test-VBRCommand -Name 'Get-VBRJobObject') {
            $objects = Invoke-VBRCommand -Name 'Get-VBRJobObject' -Parameters @{ Job = $Job } -Quiet
        }
    }
    if ($null -eq $objects -or @($objects).Count -eq 0) {
        # Jobs unstructured/agents : les objets sont parfois exposes directement sur le job.
        $objects = Get-Prop $Job @('Includes', 'BackupObject')
    }

    $names = @(@($objects) | ForEach-Object {
        Get-Prop $_ @('Name', 'Object.Name', 'ObjectName', 'VmName', 'Info.Name')
    } | Where-Object { $_ })

    if ($names.Count -eq 0) { return $script:NA }
    return (Join-Values $names)
}

function Get-JobCbtText {
    <#  Change Block Tracking : l'option vit dans les options de la source (VI ou HV). #>
    [CmdletBinding()]
    param($JobOptions)

    $vi = Get-Prop $JobOptions @('ViSourceOptions.UseChangeTracking', 'ViSourceOptions.EnableChangeTracking')
    if ($null -ne $vi) {
        $text = ConvertTo-YesNo $vi
        $reset = Get-Prop $JobOptions @('ViSourceOptions.EnableChangeTracking')
        if ($vi -eq $true -and $reset -eq $true) { $text = 'Oui (activation auto si désactivé)' }
        return $text
    }

    $hv = Get-Prop $JobOptions @('HvSourceOptions.UseChangeTracking', 'HvSourceOptions.EnableChangeTracking')
    if ($null -ne $hv) { return (ConvertTo-YesNo $hv) }

    return 'Non applicable'
}

function Get-JobRetryText {
    <#  Nombre de tentatives et delai entre tentatives (ScheduleOptions puis JobOptions). #>
    [CmdletBinding()]
    param($Schedule, $JobOptions)

    $enabled = Get-Prop $Schedule @('RetrySpecified', 'RetryEnabled')
    $times   = Get-Prop $Schedule @('RetryTimes')   -Default (Get-Prop $JobOptions @('JobOptions.RetryTimes', 'RetryTimes'))
    $timeout = Get-Prop $Schedule @('RetryTimeout') -Default (Get-Prop $JobOptions @('JobOptions.RetryTimeout', 'RetryTimeout'))

    if ($enabled -eq $false) { return 'Désactivé' }
    if ($null -eq $times)    { return $script:NA }

    $text = "$times tentative(s)"
    if ($timeout) { $text += " - attente $timeout min" }
    return $text
}

function Get-JobAppAwareText {
    <#  Application-aware processing (VSS) + indexation invite. #>
    [CmdletBinding()]
    param($Job, $JobOptions)

    $vss = Get-Prop $JobOptions @('VssOptions')
    if ($null -eq $vss) { $vss = Invoke-SafeMethod -InputObject $Job -Method 'GetVssOptions' }
    if ($null -eq $vss) { $vss = Get-Prop $Job @('VssOptions') }
    if ($null -eq $vss) { return $script:NA }

    $enabled = Get-Prop $vss @('Enabled')
    if ($null -eq $enabled) { return $script:NA }
    if ($enabled -ne $true) { return 'Non' }

    $details = New-Object System.Collections.Generic.List[string]
    $details.Add('Oui')

    $indexing = Get-Prop $vss @('GuestFSIndexingType')
    if ($indexing -and "$indexing" -notmatch 'None|Disable') { $details.Add("indexation : $indexing") }

    $ignoreErrors = Get-Prop $vss @('IgnoreErrors')
    if ($ignoreErrors -eq $true) { $details.Add('erreurs VSS ignorees') }

    $truncation = Get-Prop $vss @('SqlBackupOptions.TransactionLogsProcessing', 'WinGuestFSExclusionOptions')
    if ($truncation -and "$truncation" -notmatch 'OnlyOnSuccessJob$') { }

    return (Join-Values $details -Separator ' - ')
}

function Get-VeeamJobAudit {
    <#  Construit la table d'audit des jobs. #>
    [CmdletBinding()]
    param([hashtable]$RepositoryIndex = @{})

    Write-AuditLog "Collecte des jobs..." -Level STEP

    $jobs   = Get-AllVeeamJobs
    $result = New-Object System.Collections.Generic.List[psobject]

    if ($jobs.Count -eq 0) {
        Write-AuditLog "Aucun job retourné par le serveur." -Level WARN
        return $result
    }

    $index = 0
    foreach ($job in $jobs) {
        $index++
        $jobName = "$(Get-Prop $job @('Name', 'Info.Name') -Default 'Job inconnu')"
        Write-Progress -Activity 'Audit des jobs Veeam' -Status $jobName -PercentComplete ([int](($index / $jobs.Count) * 100))

        try {
            $options  = $null
            # Get-VBRJobOptions est le point d'entree documente/supporte (la methode interne
            # .GetOptions() est deconseillee et peut ne pas refleter la config a jour).
            if (Test-VBRCommand -Name 'Get-VBRJobOptions') {
                $options = Invoke-VBRCommand -Name 'Get-VBRJobOptions' -Parameters @{ Job = $job } -Quiet | Select-Object -First 1
            }
            if ($null -eq $options) { $options = Invoke-SafeMethod -InputObject $job -Method 'GetOptions' }
            if ($null -eq $options) { $options = Get-Prop $job @('Options') }

            $schedule = $null
            # Get-VBRJobScheduleOptions est le point d'entree correct pour NextRun : la methode
            # interne .GetScheduleOptions() est depreciee et NextRun y est frequemment vide
            # (probleme connu et documente cote Veeam), d'ou l'echec recurrent de cette colonne.
            if (Test-VBRCommand -Name 'Get-VBRJobScheduleOptions') {
                $schedule = Invoke-VBRCommand -Name 'Get-VBRJobScheduleOptions' -Parameters @{ Job = $job } -Quiet | Select-Object -First 1
            }
            if ($null -eq $schedule) { $schedule = Invoke-SafeMethod -InputObject $job -Method 'GetScheduleOptions' }
            if ($null -eq $schedule) { $schedule = Get-Prop $job @('ScheduleOptions') }

            $storage      = Get-Prop $options @('BackupStorageOptions')
            $scheduleText = Get-JobScheduleText -Schedule $schedule
            $repository   = Get-JobRepositoryInfo -Job $job -RepositoryIndex $RepositoryIndex

            # Activation : methode, puis propriete Info
            $enabled = Invoke-SafeMethod -InputObject $job -Method 'IsScheduleEnabled'
            if ($null -eq $enabled) { $enabled = Get-Prop $job @('IsScheduleEnabled', 'Info.IsScheduleEnabled', 'IsEnabled') }
            $enabledText = if ($null -eq $enabled) { $script:NA } elseif ($enabled -eq $true) { 'Activé' } else { 'Désactivé' }

            # Dernier resultat / derniere execution
            $lastResult = Invoke-SafeMethod -InputObject $job -Method 'GetLastResult'
            if ($null -eq $lastResult) { $lastResult = Get-Prop $job @('Info.LatestStatus', 'LastResult', 'LastStatus') }
            $lastResultText = if ($null -eq $lastResult -or "$lastResult" -in @('None', 'Undefined')) { 'Jamais exécuté' } else { "$lastResult" }

            $lastRun = Get-Prop $job @('LatestRunLocal', 'Info.LatestRunLocal', 'Info.EndTime', 'LastRun')
            if ($null -eq $lastRun) {
                $lastSession = Invoke-SafeMethod -InputObject $job -Method 'FindLastSession'
                $lastRun = Get-Prop $lastSession @('EndTimeUTC', 'EndTime', 'CreationTime')
            }

            # Chiffrement
            $encryptionEnabled = Get-Prop $storage @('StorageEncryptionEnabled', 'EncryptionEnabled')
            $encryptionText    = ConvertTo-YesNo $encryptionEnabled
            if ($encryptionEnabled -eq $true) {
                $keyId = Get-Prop $storage @('PwdKeyId')
                if ($keyId -and (Test-VBRCommand -Name 'Get-VBREncryptionKey')) {
                    $key = Invoke-VBRCommand -Name 'Get-VBREncryptionKey' -Quiet |
                           Where-Object { "$(Get-Prop $_ @('Id'))" -eq "$keyId" } | Select-Object -First 1
                    $keyDesc = Get-Prop $key @('Description', 'Id')
                    if ($keyDesc) { $encryptionText = "Oui (cle : $keyDesc)" }
                }
            }

            $result.Add([pscustomobject]@{
                'Nom du job'                 = $jobName
                'Type'                       = "$(Get-Prop $job @('TypeToString', 'JobType', 'Type', 'Info.JobType') -Default $script:NA)"
                'Activation'                 = $enabledText
                'Description'                = "$(Get-Prop $job @('Description', 'Info.Description') -Default '')"
                'Éléments sauvegardés'       = Get-JobObjectsText -Job $job
                'Repository'                 = $repository.Nom
                'Proxy'                      = Get-JobProxyText -Job $job -JobOptions $options
                'Planification'              = $scheduleText.Planification
                'Heure d''exécution'         = $scheduleText.HeureExecution
                'Jours'                      = $scheduleText.Jours
                'Prochaine exécution'        = $scheduleText.ProchaineExecution
                'Rétention'                  = Get-JobRetentionText -JobOptions $options
                'GFS'                        = Get-JobGfsText -JobOptions $options
                'Compression'                = ConvertFrom-CompressionLevel (Get-Prop $storage @('CompressionLevel'))
                'Taille de bloc'             = ConvertFrom-BlockSize (Get-Prop $storage @('StgBlockSize'))
                'Déduplication'              = ConvertTo-YesNo (Get-Prop $storage @('EnableDeduplication'))
                'Chiffrement'                = $encryptionText
                'Application-aware'          = Get-JobAppAwareText -Job $job -JobOptions $options
                'CBT'                        = Get-JobCbtText -JobOptions $options
                'Retry'                      = Get-JobRetryText -Schedule $schedule -JobOptions $options
                'Dernière exécution'         = Format-DateValue $lastRun
                'Dernier résultat'           = $lastResultText
                'Id'                         = "$(Get-Prop $job @('Id', 'Info.Id'))"
                'RepositoryId'               = $repository.Id
            }) | Out-Null
        }
        catch {
            Write-AuditLog "Job '$jobName' : erreur d'analyse - $($_.Exception.Message)" -Level WARN
            $result.Add([pscustomobject]@{
                'Nom du job'         = $jobName
                'Type'               = "$(Get-Prop $job @('TypeToString', 'JobType') -Default $script:NA)"
                'Activation'         = $script:NA
                'Description'        = 'Erreur lors de la collecte des détails'
                'Éléments sauvegardés' = $script:NA
                'Repository'         = $script:NA
                'Proxy'              = $script:NA
                'Planification'      = $script:NA
                'Heure d''exécution' = $script:NA
                'Jours'              = $script:NA
                'Prochaine exécution'= $script:NA
                'Rétention'          = $script:NA
                'GFS'                = $script:NA
                'Compression'        = $script:NA
                'Taille de bloc'     = $script:NA
                'Déduplication'      = $script:NA
                'Chiffrement'        = $script:NA
                'Application-aware'  = $script:NA
                'CBT'                = $script:NA
                'Retry'              = $script:NA
                'Dernière exécution' = $script:NA
                'Dernier résultat'   = $script:NA
                'Id'                 = "$(Get-Prop $job @('Id'))"
                'RepositoryId'       = $null
            }) | Out-Null
        }
    }

    Write-Progress -Activity 'Audit des jobs Veeam' -Completed
    Write-AuditLog "$($result.Count) job(s) audité(s)." -Level OK
    return $result
}

#endregion


#region ---------------------------------------------------------------- Collecte des repositories

function Get-RepositoryImmutability {
    <#
        Retourne { Active ; Periode ; Texte }.
        L'immuabilite est exposee differemment selon le type de repository
        (XFS/ReFS durci, object storage, DataDomain...) et selon la version.
    #>
    [CmdletBinding()]
    param($Repository)

    $settings = Invoke-SafeMethod -InputObject $Repository -Method 'GetImmutabilitySettings'

    $enabled = Get-Prop $settings   @('IsEnabled', 'Enabled')
    if ($null -eq $enabled) {
        $enabled = Get-Prop $Repository @(
            'Options.ImmutabilityEnabled',
            'ImmutabilityEnabled',
            'Info.IsImmutabilityEnabled',
            'BackupImmutabilityEnabled'
        )
    }

    $period = Get-Prop $settings @('ImmutabilityPeriod', 'Period')
    if ($null -eq $period) {
        $period = Get-Prop $Repository @(
            'Options.ImmutabilityPeriod',
            'ImmutabilityPeriod',
            'ImmutabilityPeriodDays',
            'Info.ImmutabilityPeriod'
        )
    }

    $text = ConvertTo-YesNo $enabled
    if ($enabled -eq $true -and $period) { $text = "Oui - $period jour(s)" }

    return [pscustomobject]@{
        Active  = $enabled
        Periode = $period
        Texte   = $text
    }
}

function Get-RepositoryLinuxInfo {
    <#
        Retourne { EstLinux ; ModeTexte ; Hardened }.
        "Mode Linux" = type de data mover (persistant / non persistant) et
        credentials à usage unique, qui conditionnent le mode Hardened Repository.
    #>
    [CmdletBinding()]
    param($Repository, $ImmutabilityEnabled)

    $type     = "$(Get-Prop $Repository @('Type', 'Info.Type'))"
    $hostObj  = Invoke-SafeMethod -InputObject $Repository -Method 'GetHost'
    $hostType = "$(Get-Prop $hostObj @('Type', 'Info.Type'))"

    # NB : ne pas nommer cette variable $isLinux / $IsLinux : PowerShell est insensible a la
    # casse et $IsLinux est une variable automatique EN LECTURE SEULE depuis PowerShell 7+
    # (indique l'OS d'execution du script). Toute affectation a $isLinux y leve donc
    # "Cannot overwrite variable IsLinux because it is read-only or constant." sous pwsh,
    # ce qui faisait echouer l'analyse de chaque repository (silencieusement absorbe par le
    # catch de l'appelant, d'ou des CSV/rapports vides malgre des entrees dans le journal).
    $repoIsLinux = ($type -match 'Linux') -or ($hostType -match 'Linux')

    if (-not $repoIsLinux) {
        return [pscustomobject]@{
            EstLinux  = $false
            ModeTexte = 'Non applicable (repository non Linux)'
            Hardened  = 'Non'
        }
    }

    $singleUse = Get-Prop $Repository @(
        'UseSingleUseCredentials',
        'Info.IsSingleUseCredentials',
        'Options.UseSingleUseCredentials',
        'IsSingleUseCredentials'
    )
    $persistent = Get-Prop $Repository @(
        'UsePersistentDataMover',
        'IsPersistentDataMoverEnabled',
        'Info.IsPersistentAgent',
        'UsePersistentAgent'
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add('Linux')
    if ($null -ne $persistent) {
        $parts.Add($(if ($persistent -eq $true) { 'data mover persistant' } else { 'data mover non persistant' }))
    }
    if ($null -ne $singleUse) {
        $parts.Add($(if ($singleUse -eq $true) { 'credentials à usage unique' } else { 'credentials permanents' }))
    }

    # Un repository durci = Linux + immuabilite (usuellement + credentials à usage unique)
    $hardenedFlag = Get-Prop $Repository @('IsHardened', 'Info.IsHardened', 'UseHardenedRepository')
    $hardened = if ($hardenedFlag -eq $true) { 'Oui' }
                elseif ($ImmutabilityEnabled -eq $true -and $singleUse -eq $true) { 'Oui' }
                elseif ($ImmutabilityEnabled -eq $true) { 'Oui (immuabilité active)' }
                else { 'Non' }

    return [pscustomobject]@{
        EstLinux  = $true
        ModeTexte = (Join-Values $parts -Separator ' - ')
        Hardened  = $hardened
    }
}

function Get-RepositorySpace {
    <#  Capacite / espace libre : le conteneur porte les valeurs mises en cache. #>
    [CmdletBinding()]
    param($Repository)

    $container = Invoke-SafeMethod -InputObject $Repository -Method 'GetContainer'

    $total = Get-Prop $container @('CachedTotalSpace.InBytes', 'TotalSpace.InBytes', 'CachedTotalSpace')
    $free  = Get-Prop $container @('CachedFreeSpace.InBytes',  'FreeSpace.InBytes',  'CachedFreeSpace')

    if ($null -eq $total) { $total = Get-Prop $Repository @('Info.CachedTotalSpace.InBytes', 'Info.CachedTotalSpace') }
    if ($null -eq $free)  { $free  = Get-Prop $Repository @('Info.CachedFreeSpace.InBytes',  'Info.CachedFreeSpace') }

    $used = $null
    if ($null -ne $total -and $null -ne $free) {
        try { $used = [double]$total - [double]$free } catch { $used = $null }
    }

    return [pscustomobject]@{
        TotalBytes = $total
        FreeBytes  = $free
        UsedBytes  = $used
        Taux       = ConvertTo-Percent -Part $used -Total $total
    }
}

function Get-VeeamRepositoryAudit {
    <#  Construit la table d'audit des repositories, SOBR compris. #>
    [CmdletBinding()]
    param(
        [System.Collections.Generic.List[psobject]]$Jobs
    )

    Write-AuditLog "Collecte des repositories..." -Level STEP

    $simple  = @(Invoke-VBRCommand -Name 'Get-VBRBackupRepository')
    $sobrs   = @(Invoke-VBRCommand -Name 'Get-VBRBackupRepository' -Parameters @{ ScaleOut = $true } -Quiet)
    $objects = @(Invoke-VBRCommand -Name 'Get-VBRObjectStorageRepository' -Quiet)

    # Table : Id d'extent -> nom du SOBR parent
    $extentToSobr = @{}
    foreach ($sobr in $sobrs) {
        $sobrName = "$(Get-Prop $sobr @('Name') -Default 'SOBR')"
        $extents  = Get-Prop $sobr @('Extent', 'Extents')
        foreach ($extent in @($extents)) {
            $repoId = "$(Get-Prop $extent @('Repository.Id', 'Id'))"
            if ($repoId) { $extentToSobr[$repoId] = $sobrName }
        }
        # Capacity tier / archive tier
        foreach ($tierPath in @('CapacityExtent.Repository.Id', 'ArchiveExtent.Repository.Id')) {
            $tierId = "$(Get-Prop $sobr @($tierPath))"
            if ($tierId) { $extentToSobr[$tierId] = "$sobrName (tier objet)" }
        }
    }

    # Comptage des jobs par repository (nom + id, car les deux ne sont pas toujours resolus)
    $jobCountById   = @{}
    $jobCountByName = @{}
    foreach ($job in @($Jobs)) {
        $rid = "$($job.RepositoryId)"
        $rname = "$($job.Repository)"
        if ($rid   -and $rid   -ne '')          { $jobCountById[$rid]   = [int]$jobCountById[$rid]   + 1 }
        if ($rname -and $rname -ne $script:NA)  { $jobCountByName[$rname] = [int]$jobCountByName[$rname] + 1 }
    }

    $result = New-Object System.Collections.Generic.List[psobject]
    $skippedSan = 0

    # --- Repositories classiques -------------------------------------------------
    foreach ($repo in $simple) {
        $repoName = "$(Get-Prop $repo @('Name', 'Info.Name') -Default 'Repository inconnu')"
        $repoType = "$(Get-Prop $repo @('Type', 'Info.Type') -Default $script:NA)".Trim()

        # Les repositories "SanSnapshotOnly" ne stockent pas de donnees a proprement parler
        # (ils representent l'integration snapshots SAN) : ils sont deja restitues dans la
        # storage infrastructure et n'ont pas leur place dans la liste des repositories.
        # Comparaison stricte (egalite, pas de sous-chaine) pour ne jamais ecarter un
        # repository classique par erreur.
        if ($repoType -ieq 'SanSnapshotOnly') { $skippedSan++; continue }

        try {
            $repoId  = "$(Get-Prop $repo @('Id', 'Info.Id'))"
            $space   = Get-RepositorySpace -Repository $repo
            $immut   = Get-RepositoryImmutability -Repository $repo
            $linux   = Get-RepositoryLinuxInfo -Repository $repo -ImmutabilityEnabled $immut.Active
            $hostObj = Invoke-SafeMethod -InputObject $repo -Method 'GetHost'

            $unavailable = Get-Prop $repo @('IsUnavailable', 'Info.IsUnavailable')
            $status = if ($unavailable -eq $true) { 'Indisponible' } else { 'Disponible' }
            if ($null -ne $space.Taux -and $space.Taux -ge 90) { $status = "$status (espace critique)" }
            elseif ($null -ne $space.Taux -and $space.Taux -ge 80) { $status = "$status (espace faible)" }

            $count = [int]$jobCountById[$repoId]
            if ($count -eq 0) { $count = [int]$jobCountByName[$repoName] }

            $result.Add([pscustomobject]@{
                'Nom'                = $repoName
                'Type'               = $repoType
                'Serveur hébergeant' = "$(Get-Prop $hostObj @('Name', 'Info.Name') -Default (Get-Prop $repo @('HostName', 'Host.Name') -Default $script:NA))"
                'Chemin'             = "$(Get-Prop $repo @('FriendlyPath', 'Path', 'Info.Path') -Default $script:NA)"
                'Capacité'           = Format-Size $space.TotalBytes
                'Espace libre'       = Format-Size $space.FreeBytes
                'Espace utilisé'     = Format-Size $space.UsedBytes
                "Taux d'utilisation" = $(if ($null -ne $space.Taux) { "$($space.Taux) %" } else { $script:NA })
                'Immutabilité'       = $immut.Texte
                'Hardened Repository'= $linux.Hardened
                'Mode Linux'         = $linux.ModeTexte
                'SOBR associe'       = $(if ($extentToSobr.ContainsKey($repoId)) { $extentToSobr[$repoId] } else { 'Aucun' })
                'Jobs utilisateurs'  = $count
                'Tâches max'         = "$(Get-Prop $repo @('Options.MaxTaskCount', 'MaxTaskCount', 'Info.MaxTaskCount') -Default $script:NA)"
                'Statut'             = $status
                'TauxNumerique'      = $space.Taux
            }) | Out-Null
        }
        catch {
            Write-AuditLog "Repository '$repoName' : erreur d'analyse - $($_.Exception.Message)" -Level WARN
        }
    }

    # --- Object storage (utilise seul ou en capacity tier) -----------------------
    foreach ($repo in $objects) {
        $repoName = "$(Get-Prop $repo @('Name') -Default 'Object storage')"
        try {
            $repoId = "$(Get-Prop $repo @('Id'))"
            $immut  = Get-RepositoryImmutability -Repository $repo
            $limit  = Get-Prop $repo @('SizeLimit', 'SizeLimitGB')
            $count  = [int]$jobCountById[$repoId]
            if ($count -eq 0) { $count = [int]$jobCountByName[$repoName] }

            $result.Add([pscustomobject]@{
                'Nom'                = $repoName
                'Type'               = "Object storage - $(Get-Prop $repo @('Type') -Default 'inconnu')"
                'Serveur hébergeant' = "$(Get-Prop $repo @('ServicePoint', 'Endpoint', 'ConnectionPoint') -Default 'Cloud / S3')"
                'Chemin'             = "$(Get-Prop $repo @('Folder', 'Bucket.Name', 'Container.Name', 'Path') -Default $script:NA)"
                'Capacité'           = $(if ($limit) { "$limit (quota)" } else { 'Illimitée / quota non défini' })
                'Espace libre'       = $script:NA
                'Espace utilisé'     = $script:NA
                "Taux d'utilisation" = $script:NA
                'Immutabilité'       = $immut.Texte
                'Hardened Repository'= 'Non applicable'
                'Mode Linux'         = 'Non applicable'
                'SOBR associe'       = $(if ($extentToSobr.ContainsKey($repoId)) { $extentToSobr[$repoId] } else { 'Aucun' })
                'Jobs utilisateurs'  = $count
                'Tâches max'         = "$(Get-Prop $repo @('MaxTaskCount') -Default $script:NA)"
                'Statut'             = 'Disponible'
                'TauxNumerique'      = $null
            }) | Out-Null
        }
        catch {
            Write-AuditLog "Object storage '$repoName' : erreur d'analyse - $($_.Exception.Message)" -Level WARN
        }
    }

    Write-AuditLog "$($result.Count) repository(s) audité(s)." -Level OK
    if ($skippedSan -gt 0) { Write-AuditLog "$skippedSan repository(s) SanSnapshotOnly écarté(s) (déjà restitué(s) dans la storage infrastructure)." -Level INFO }
    if ($simple.Count -gt 0 -and $result.Count -eq 0 -and $skippedSan -eq 0) {
        Write-AuditLog "Attention : $($simple.Count) repository(s) renvoyé(s) par Get-VBRBackupRepository mais aucun n'a pu être analysé (voir avertissements ci-dessus)." -Level WARN
    }
    return $result
}

function Get-VeeamSobrAudit {
    <#  Table dediee aux Scale-Out Backup Repositories. #>
    [CmdletBinding()]
    param()

    Write-AuditLog "Collecte des Scale-Out Backup Repositories..." -Level STEP

    $sobrs  = @(Invoke-VBRCommand -Name 'Get-VBRBackupRepository' -Parameters @{ ScaleOut = $true } -Quiet)
    $result = New-Object System.Collections.Generic.List[psobject]

    foreach ($sobr in $sobrs) {
        $sobrName = "$(Get-Prop $sobr @('Name') -Default 'SOBR')"
        try {
            $extents     = @(Get-Prop $sobr @('Extent', 'Extents'))
            $extentNames = @($extents | ForEach-Object { Get-Prop $_ @('Name', 'Repository.Name') } | Where-Object { $_ })

            $totalBytes = 0.0
            $freeBytes  = 0.0
            $hasSpace   = $false
            foreach ($extent in $extents) {
                $extentRepo = Get-Prop $extent @('Repository')
                if ($null -eq $extentRepo) { continue }
                $space = Get-RepositorySpace -Repository $extentRepo
                if ($null -ne $space.TotalBytes) { $totalBytes += [double]$space.TotalBytes; $hasSpace = $true }
                if ($null -ne $space.FreeBytes)  { $freeBytes  += [double]$space.FreeBytes }
            }

            $capacityTier = Get-Prop $sobr @('CapacityExtent.Repository.Name', 'CapacityExtent.Name')
            $archiveTier  = Get-Prop $sobr @('ArchiveExtent.Repository.Name', 'ArchiveExtent.Name')

            $result.Add([pscustomobject]@{
                'Nom SOBR'            = $sobrName
                'Description'         = "$(Get-Prop $sobr @('Description') -Default '')"
                'Politique de place'  = "$(Get-Prop $sobr @('PolicyType', 'PlacementPolicy') -Default $script:NA)"
                'Nombre d''extents'   = $extents.Count
                'Extents'             = Join-Values $extentNames
                'Capacité totale'     = $(if ($hasSpace) { Format-Size $totalBytes } else { $script:NA })
                'Espace libre total'  = $(if ($hasSpace) { Format-Size $freeBytes }  else { $script:NA })
                "Taux d'utilisation"  = $(if ($hasSpace -and $totalBytes -gt 0) { "$(ConvertTo-Percent -Part ($totalBytes - $freeBytes) -Total $totalBytes) %" } else { $script:NA })
                'Capacity tier'       = "$(if ($capacityTier) { $capacityTier } else { 'Non configuré' })"
                'Archive tier'        = "$(if ($archiveTier)  { $archiveTier }  else { 'Non configuré' })"
                'Per-VM backup files' = ConvertTo-YesNo (Get-Prop $sobr @('UsePerVMBackupFiles', 'PerVMBackupFiles'))
            }) | Out-Null
        }
        catch {
            Write-AuditLog "SOBR '$sobrName' : erreur d'analyse - $($_.Exception.Message)" -Level WARN
        }
    }

    Write-AuditLog "$($result.Count) SOBR audité(s)." -Level OK
    return $result
}

#endregion


#region ---------------------------------------------------------------- Collecte de l'infrastructure

function Get-RemoteOsInfo {
    <#
        Type d'OS d'un serveur/proxy manage.
        1) Sonde d'abord les proprietes exposees par Veeam lui-meme (Host.Type / Info.Type...),
           qui indiquent Windows ou Linux independamment de toute connectivite reseau.
           C'est la seule methode fiable pour les proxies/serveurs Linux : CIM/WMI ne
           fonctionne jamais vers Linux (pas de WinRM), il ne faut donc pas en dependre.
        2) Complete ensuite, uniquement pour les hotes Windows, avec CIM/WMI pour
           obtenir le libelle et le build precis.
    #>
    [CmdletBinding()]
    param(
        [string]$ComputerName,
        [AllowNull()]$VeeamObject
    )

    $veeamType = "$(Get-Prop $VeeamObject @('Type', 'Info.Type', 'HostType', 'Info.HostType', 'Platform', 'Info.Platform'))"
    $isLinuxByVeeam   = $veeamType -match 'Linux'
    $isWindowsByVeeam = $veeamType -match 'Windows|Win32|Win64'

    if ($isLinuxByVeeam) {
        # Ne jamais tenter CIM/WMI vers un hote Linux : cela echoue toujours et ralentit l'audit.
        return "Linux ($veeamType)"
    }

    if ($SkipRemoteQueries -or [string]::IsNullOrWhiteSpace($ComputerName)) {
        if ($isWindowsByVeeam) { return "Windows ($veeamType)" }
        if ($veeamType) { return $veeamType }
        return $script:NA
    }

    $isLocal = $ComputerName -in @('localhost', '.', '127.0.0.1', $env:COMPUTERNAME) -or
               $ComputerName -like "$env:COMPUTERNAME.*"

    try {
        $params = @{ ClassName = 'Win32_OperatingSystem'; ErrorAction = 'Stop' }
        if (-not $isLocal) { $params['ComputerName'] = $ComputerName }
        $os = Get-CimInstance @params | Select-Object -First 1
        if ($os) {
            $caption = "$($os.Caption)".Trim()
            $build   = "$($os.Version)"
            return "$caption (build $build)"
        }
    }
    catch {
        Write-AuditLog "OS de '$ComputerName' non interrogeable via CIM ($($_.Exception.Message.Split([char]10)[0]))." -Level INFO
    }

    # CIM indisponible (WinRM filtre, hote non joignable...) : on retombe sur le type Veeam si connu.
    if ($isWindowsByVeeam) { return "Windows ($veeamType - détail indisponible)" }
    if ($veeamType) { return $veeamType }
    return $script:NA
}

function Get-VeeamLicenseAudit {
    <#  Licence : type, edition, expiration, instances consommees. #>
    [CmdletBinding()]
    param()

    Write-AuditLog "Collecte des informations de licence..." -Level STEP

    $licenses = @(Invoke-VBRCommand -Name 'Get-VBRInstalledLicense')
    if ($licenses.Count -eq 0) {
        Write-AuditLog "Aucune information de licence récupérée." -Level WARN
        return [pscustomobject]@{
            'Statut'                  = $script:NA
            'Type'                    = $script:NA
            'Edition'                 = $script:NA
            'Licencié à'              = $script:NA
            'Expiration licence'      = $script:NA
            'Jours restants'          = $script:NA
            'Expiration support'      = $script:NA
            'Instances licenciées'    = $script:NA
            'Instances utilisees'     = $script:NA
            'Instances restantes'     = $script:NA
            'Sockets licenciés'       = $script:NA
            'Sockets utilises'        = $script:NA
        }
    }

    $license    = $licenses[0]
    $expiration = Get-Prop $license @('ExpirationDate')

    $daysLeft = $script:NA
    if ($expiration) {
        try {
            $span = ([datetime]$expiration) - (Get-Date)
            $daysLeft = [math]::Floor($span.TotalDays)
            if ($daysLeft -lt 0) { $daysLeft = "Expirée depuis $([math]::Abs($daysLeft)) jour(s)" }
        }
        catch { }
    }

    $licensedInstances = Get-Prop $license @('InstanceLicenseSummary.LicensedInstancesNumber', 'LicensedInstancesNumber')
    $usedInstances     = Get-Prop $license @('InstanceLicenseSummary.UsedInstancesNumber',     'UsedInstancesNumber')
    $remaining         = $script:NA
    if ($null -ne $licensedInstances -and $null -ne $usedInstances) {
        try { $remaining = [int]$licensedInstances - [int]$usedInstances } catch { }
    }

    return [pscustomobject]@{
        'Statut'               = "$(Get-Prop $license @('Status') -Default $script:NA)"
        'Type'                 = "$(Get-Prop $license @('Type', 'LicenseType') -Default $script:NA)"
        'Edition'              = "$(Get-Prop $license @('Edition') -Default $script:NA)"
        'Licencié à'           = "$(Get-Prop $license @('LicensedTo') -Default $script:NA)"
        'Expiration licence'   = Format-DateValue $expiration
        'Jours restants'       = "$daysLeft"
        'Expiration support'   = Format-DateValue (Get-Prop $license @('SupportExpirationDate'))
        'Instances licenciées' = "$(if ($null -ne $licensedInstances) { $licensedInstances } else { $script:NA })"
        'Instances utilisees'  = "$(if ($null -ne $usedInstances)     { $usedInstances }     else { $script:NA })"
        'Instances restantes'  = "$remaining"
        'Sockets licenciés'    = "$(Get-Prop $license @('SocketLicenseSummary.LicensedSocketsNumber') -Default $script:NA)"
        'Sockets utilises'     = "$(Get-Prop $license @('SocketLicenseSummary.UsedSocketsNumber')     -Default $script:NA)"
    }
}

function Get-VeeamProxyAudit {
    <#  Proxies de sauvegarde : VMware, Hyper-V, fichiers/NAS, agents. #>
    [CmdletBinding()]
    param()

    Write-AuditLog "Collecte des proxies..." -Level STEP

    $sources = @(
        @{ Cmdlet = 'Get-VBRViProxy';         Categorie = 'VMware vSphere' },
        @{ Cmdlet = 'Get-VBRHvProxy';         Categorie = 'Hyper-V' },
        @{ Cmdlet = 'Get-VBRNASProxyServer';  Categorie = 'NAS / fichiers' },
        @{ Cmdlet = 'Get-VBRFileProxy';       Categorie = 'Fichiers' },
        @{ Cmdlet = 'Get-VBRComputerProxy';   Categorie = 'Agents' }
    )

    $result = New-Object System.Collections.Generic.List[psobject]
    $seen   = New-Object System.Collections.Generic.HashSet[string]

    foreach ($source in $sources) {
        $proxies = Invoke-VBRCommand -Name $source.Cmdlet -Quiet
        foreach ($proxy in $proxies) {
            $proxyName = "$(Get-Prop $proxy @('Name', 'Host.Name', 'Server.Name') -Default 'Proxy inconnu')"
            $key = "$($source.Categorie)|$proxyName"
            if (-not $seen.Add($key)) { continue }

            $hostObj  = Get-Prop $proxy @('Host', 'Server')
            $hostName = "$(Get-Prop $hostObj @('Name') -Default $proxyName)"

            $enabled = Get-Prop $proxy @('IsDisabled', 'Info.IsDisabled')
            $enabledText = if ($null -eq $enabled) { $script:NA } elseif ($enabled -eq $true) { 'Désactivé' } else { 'Activé' }

            $result.Add([pscustomobject]@{
                'Nom'                 = $proxyName
                'Categorie'           = $source.Categorie
                'Serveur hôte'        = $hostName
                'État'                = $enabledText
                'Mode de transport'   = "$(Get-Prop $proxy @('TransportMode', 'Options.TransportMode', 'Info.TransportMode') -Default $script:NA)"
                'Tâches simultanées'  = "$(Get-Prop $proxy @('MaxTasksCount', 'Options.MaxTasksCount', 'MaxTaskCount', 'Info.MaxTasksCount') -Default $script:NA)"
                'Failover réseau'     = ConvertTo-YesNo (Get-Prop $proxy @('FailoverToNetwork', 'Options.FailoverToNetwork'))
                'Chiffrement réseau'  = ConvertTo-YesNo (Get-Prop $proxy @('UseSsl', 'Options.UseSsl', 'IsEncryptionEnabled'))
                'Cache / dossier'     = "$(Get-Prop $proxy @('CachePath', 'Options.CachePath') -Default '')"
                'Description'         = "$(Get-Prop $proxy @('Description', 'Info.Description') -Default '')"
                'OS'                  = Get-RemoteOsInfo -ComputerName $hostName -VeeamObject $hostObj
            }) | Out-Null
        }
    }

    Write-AuditLog "$($result.Count) proxy(s) audité(s)." -Level OK
    return $result
}

function Get-VeeamManagedServerAudit {
    <#  Serveurs de management ajoutes a l'infrastructure Veeam. #>
    [CmdletBinding()]
    param()

    Write-AuditLog "Collecte des serveurs de management..." -Level STEP

    $servers = @(Invoke-VBRCommand -Name 'Get-VBRServer')
    $result  = New-Object System.Collections.Generic.List[psobject]
    $skipped = 0

    foreach ($srv in $servers) {
        $srvName = "$(Get-Prop $srv @('Name', 'Info.Name') -Default 'Serveur inconnu')"
        try {
            $srvType = "$(Get-Prop $srv @('Type', 'Info.Type') -Default $script:NA)"

            # Les SanHost (baies de stockage integrees pour les snapshots SAN) sont des
            # serveurs techniques, pas des serveurs de management : ils sont restitues
            # uniquement dans la storage infrastructure (cf. Get-VeeamStorageInfrastructureAudit).
            if ($srvType -match 'SanHost') { $skipped++; continue }

            $unavailable = Get-Prop $srv @('IsUnavailable', 'Info.IsUnavailable')
            $result.Add([pscustomobject]@{
                'Nom'          = $srvName
                'Type'         = $srvType
                'Description'  = "$(Get-Prop $srv @('Description', 'Info.Description') -Default '')"
                'Version API'  = "$(Get-Prop $srv @('ApiVersion', 'Info.ApiVersion') -Default $script:NA)"
                'Statut'       = $(if ($unavailable -eq $true) { 'Indisponible' } else { 'Disponible' })
                'OS'           = Get-RemoteOsInfo -ComputerName $srvName -VeeamObject $srv
            }) | Out-Null
        }
        catch {
            Write-AuditLog "Serveur '$srvName' : erreur d'analyse - $($_.Exception.Message)" -Level WARN
        }
    }

    if ($skipped -gt 0) { Write-AuditLog "$skipped SanHost écarté(s) de la liste des serveurs de management (restitué(s) dans la storage infrastructure)." -Level INFO }
    Write-AuditLog "$($result.Count) serveur(s) géré(s) audité(s)." -Level OK
    return $result
}

function ConvertTo-DatabaseAuditResult {
    <#  Met en forme le resultat final a partir des valeurs brutes recuperees (registre ou fichier). #>
    param($SqlHostName, $SqlInstanceName, $SqlDatabaseName, $SqlHostPort, $SqlLogin, [string]$ActiveConfig, [string]$Source)

    $engine = if ("$ActiveConfig" -match 'Postgre') { 'PostgreSQL' } else { 'Microsoft SQL Server' }
    return [pscustomobject]@{
        'Moteur'           = $engine
        'Serveur'          = "$SqlHostName"
        'Instance'         = "$(if ($SqlInstanceName) { $SqlInstanceName } else { 'Par défaut' })"
        'Base'             = "$SqlDatabaseName"
        'Port'             = "$(if ($SqlHostPort) { $SqlHostPort } else { $script:NA })"
        'Authentification' = "$(if ($SqlLogin) { "SQL ($SqlLogin)" } else { 'Windows / intégrée' })"
        'Source'           = $Source
    }
}

function Get-VeeamDatabaseAudit {
    <#
        Base de configuration : SQL Server ou PostgreSQL (v12+).
        Uniquement via le registre local/distant (source officielle Veeam) : cle courante
        DatabaseConfigurations, puis repli sur l'ancienne cle a plat (pre-v11). A defaut,
        N/A (ex. registre inaccessible, Remote Registry desactive, appliance Linux v13).
    #>
    [CmdletBinding()]
    param([string]$ServerName)

    Write-AuditLog "Collecte de la configuration de base de données..." -Level STEP

    $unknown = [pscustomobject]@{
        'Moteur'          = $script:NA
        'Serveur'         = $script:NA
        'Instance'        = $script:NA
        'Base'            = $script:NA
        'Port'            = $script:NA
        'Authentification'= $script:NA
        'Source'          = 'Non déterminée (registre inaccessible ou serveur non Windows)'
    }

    if ($SkipRemoteQueries) { return $unknown }

    $basePath = 'SOFTWARE\Veeam\Veeam Backup and Replication\DatabaseConfigurations'
    $legacyPath = 'SOFTWARE\Veeam\Veeam Backup and Replication'
    $isLocal  = $ServerName -in @('localhost', '.', '127.0.0.1', $env:COMPUTERNAME)

    try {
        if ($isLocal) {
            try {
                $root = Get-Item -LiteralPath "HKLM:\$basePath" -ErrorAction Stop
                $active = "$($root.GetValue('SqlActiveConfiguration'))"
                if ([string]::IsNullOrWhiteSpace($active)) { $active = 'MsSql' }

                $subKey = Get-Item -LiteralPath "HKLM:\$basePath\$active" -ErrorAction Stop
                return ConvertTo-DatabaseAuditResult -SqlHostName $subKey.GetValue('SqlHostName') -SqlInstanceName $subKey.GetValue('SqlInstanceName') `
                    -SqlDatabaseName $subKey.GetValue('SqlDatabaseName') -SqlHostPort $subKey.GetValue('SqlHostPort') -SqlLogin $subKey.GetValue('SqlLogin') `
                    -ActiveConfig $active -Source 'Registre local'
            }
            catch {
                # Repli : ancienne cle a plat (versions anterieures a la v11, encore presente
                # sur certaines installations mises a niveau).
                $legacy = Get-Item -LiteralPath "HKLM:\$legacyPath" -ErrorAction Stop
                if ($legacy.GetValue('SqlServerName')) {
                    return ConvertTo-DatabaseAuditResult -SqlHostName $legacy.GetValue('SqlServerName') -SqlInstanceName $legacy.GetValue('SqlInstanceName') `
                        -SqlDatabaseName $legacy.GetValue('SqlDatabaseName') -SqlHostPort $null -SqlLogin $legacy.GetValue('SqlLogin') `
                        -ActiveConfig 'MsSql' -Source 'Registre local (ancienne clé à plat)'
                }
                throw
            }
        }

        # Serveur distant : registre a distance (necessite le service Remote Registry)
        $remote = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $ServerName)
        try {
            $root = $remote.OpenSubKey($basePath)
            if ($null -ne $root) {
                $active = "$($root.GetValue('SqlActiveConfiguration'))"
                if ([string]::IsNullOrWhiteSpace($active)) { $active = 'MsSql' }

                $subKey = $root.OpenSubKey($active)
                if ($null -ne $subKey) {
                    return ConvertTo-DatabaseAuditResult -SqlHostName $subKey.GetValue('SqlHostName') -SqlInstanceName $subKey.GetValue('SqlInstanceName') `
                        -SqlDatabaseName $subKey.GetValue('SqlDatabaseName') -SqlHostPort $subKey.GetValue('SqlHostPort') -SqlLogin $subKey.GetValue('SqlLogin') `
                        -ActiveConfig $active -Source 'Registre distant'
                }
            }

            $legacy = $remote.OpenSubKey($legacyPath)
            if ($null -ne $legacy -and $legacy.GetValue('SqlServerName')) {
                return ConvertTo-DatabaseAuditResult -SqlHostName $legacy.GetValue('SqlServerName') -SqlInstanceName $legacy.GetValue('SqlInstanceName') `
                    -SqlDatabaseName $legacy.GetValue('SqlDatabaseName') -SqlHostPort $null -SqlLogin $legacy.GetValue('SqlLogin') `
                    -ActiveConfig 'MsSql' -Source 'Registre distant (ancienne clé à plat)'
            }
        }
        finally { $remote.Close() }
    }
    catch {
        Write-AuditLog "Registre de configuration de base de données non lisible : $($_.Exception.Message.Split([char]10)[0])" -Level INFO
    }

    return $unknown
}

function Get-VeeamServiceAudit {
    <#  Services Veeam du serveur VBR (nom, etat, demarrage, compte). #>
    [CmdletBinding()]
    param([string]$ServerName)

    Write-AuditLog "Collecte des services Veeam..." -Level STEP

    $result = New-Object System.Collections.Generic.List[psobject]
    if ($SkipRemoteQueries) {
        Write-AuditLog "Interrogation des services ignorée (-SkipRemoteQueries)." -Level INFO
        return $result
    }

    $isLocal = $ServerName -in @('localhost', '.', '127.0.0.1', $env:COMPUTERNAME)

    try {
        $params = @{ ClassName = 'Win32_Service'; Filter = "Name LIKE 'Veeam%'"; ErrorAction = 'Stop' }
        if (-not $isLocal) { $params['ComputerName'] = $ServerName }

        foreach ($svc in (Get-CimInstance @params | Sort-Object DisplayName)) {
            $result.Add([pscustomobject]@{
                'Service'      = "$($svc.DisplayName)"
                'Nom système'  = "$($svc.Name)"
                'État'         = "$($svc.State)"
                'Démarrage'    = "$($svc.StartMode)"
                'Compte'       = "$($svc.StartName)"
            }) | Out-Null
        }
        Write-AuditLog "$($result.Count) service(s) Veeam recensé(s)." -Level OK
    }
    catch {
        Write-AuditLog "Services Veeam non interrogeables sur '$ServerName' : $($_.Exception.Message.Split([char]10)[0])" -Level WARN
    }

    return $result
}

function Get-VeeamBackupServerAudit {
    <#  Fiche d'identite du ou des serveurs VBR. #>
    [CmdletBinding()]
    param([string]$ServerName, $VersionInfo, $License)

    Write-AuditLog "Collecte des informations du serveur de sauvegarde..." -Level STEP

    $result = New-Object System.Collections.Generic.List[psobject]

    # Le serveur VBR lui-meme
    $localhost = Invoke-VBRCommand -Name 'Get-VBRLocalhost' -Quiet | Select-Object -First 1
    $vbrName   = "$(Get-Prop $localhost @('Name', 'Info.Name') -Default $ServerName)"

    $result.Add([pscustomobject]@{
        'Serveur VBR'          = $vbrName
        'Role'                 = 'Backup Server (console / configuration)'
        'Version'              = "$($VersionInfo.Version)"
        'Build'                = "$($VersionInfo.Build)"
        'Source version'       = "$($VersionInfo.Source)"
        'OS'                   = Get-RemoteOsInfo -ComputerName $vbrName
        'Licence'              = "$($License.'Type') / $($License.'Edition') - $($License.'Statut')"
        'Expiration licence'   = "$($License.'Expiration licence')"
        'Instances utilisees'  = "$($License.'Instances utilisees') / $($License.'Instances licenciées')"
    }) | Out-Null

    # Serveurs VBR additionnels declares dans l'infrastructure (configurations distribuees)
    $others = @(Invoke-VBRCommand -Name 'Get-VBRServer' -Quiet |
                Where-Object { "$(Get-Prop $_ @('Type'))" -match 'Backup|Local' -and "$(Get-Prop $_ @('Name'))" -ne $vbrName })

    foreach ($srv in $others) {
        $srvName = "$(Get-Prop $srv @('Name'))"
        $result.Add([pscustomobject]@{
            'Serveur VBR'         = $srvName
            'Role'                = "Serveur Veeam déclaré ($(Get-Prop $srv @('Type') -Default 'type inconnu'))"
            'Version'             = $script:NA
            'Build'               = $script:NA
            'Source version'      = $script:NA
            'OS'                  = Get-RemoteOsInfo -ComputerName $srvName
            'Licence'             = 'Hérité du serveur principal'
            'Expiration licence'  = $script:NA
            'Instances utilisees' = $script:NA
        }) | Out-Null
    }

    return $result
}

#endregion


#region ---------------------------------------------------------------- Sauvegardes sur bande

function Get-TapeIndex {
    <#
        Construit les index bande (media pools, bibliotheques, coffres, serveurs)
        pour resoudre les references par Id sans multiplier les appels.
    #>
    [CmdletBinding()]
    param()

    $index = @{
        MediaPools  = @{}
        Libraries   = @{}
        Vaults      = @{}
        TapeServers = @{}
    }

    foreach ($pool in @(Invoke-VBRCommand -Name 'Get-VBRTapeMediaPool' -Quiet)) {
        $id = "$(Get-Prop $pool @('Id'))"
        if ($id) { $index.MediaPools[$id] = $pool }
    }
    foreach ($library in @(Invoke-VBRCommand -Name 'Get-VBRTapeLibrary' -Quiet)) {
        $id = "$(Get-Prop $library @('Id'))"
        if ($id) { $index.Libraries[$id] = $library }
    }
    foreach ($vault in @(Invoke-VBRCommand -Name 'Get-VBRTapeVault' -Quiet)) {
        $id = "$(Get-Prop $vault @('Id'))"
        if ($id) { $index.Vaults[$id] = $vault }
    }
    foreach ($tapeServer in @(Invoke-VBRCommand -Name 'Get-VBRTapeServer' -Quiet)) {
        $id = "$(Get-Prop $tapeServer @('Id'))"
        if ($id) { $index.TapeServers[$id] = $tapeServer }
    }

    return $index
}

function Resolve-IndexName {
    <#  Retourne le nom de l'objet reference par un Id, ou une valeur de repli. #>
    param([hashtable]$Index, $Id, [string]$Default = $script:NA)
    $key = "$Id"
    if ([string]::IsNullOrWhiteSpace($key)) { return $Default }
    if ($Index.ContainsKey($key)) {
        return "$(Get-Prop $Index[$key] @('Name', 'Info.Name') -Default $Default)"
    }
    return $Default
}

function Resolve-TapeLibraryNames {
    <#
        Nom(s) de la/les bibliotheque(s) associee(s) a un media pool, avec plusieurs
        strategies de repli car la relation Pool <-> Library est exposee differemment
        selon les versions (Id porte par le pool, ou inversement par la bibliotheque).
    #>
    [CmdletBinding()]
    param($Pool, [hashtable]$TapeIndex)

    if ($null -eq $Pool) { return @() }
    $poolId = "$(Get-Prop $Pool @('Id'))"

    # 1) Chemin direct : le pool porte l'Id (ou les Ids) de sa/ses bibliotheque(s).
    $libraryIds = Get-Prop $Pool @('LibraryId', 'Library', 'LibraryIds')
    $names = @(@($libraryIds) | ForEach-Object {
        $lid = "$(Get-Prop $_ @('Id') -Default $_)"
        Resolve-IndexName -Index $TapeIndex.Libraries -Id $lid -Default $null
    } | Where-Object { $_ })
    if ($names.Count -gt 0) { return $names }

    # 2) Repli : recherche inverse parmi les bibliotheques connues.
    if ($poolId -and $TapeIndex.Libraries) {
        $names = @($TapeIndex.Libraries.Values | Where-Object {
            $libPoolIds = @(Get-Prop $_ @('MediaPoolIds', 'MediaPools') | ForEach-Object { Get-Prop $_ @('Id') -Default $_ })
            $poolId -in $libPoolIds
        } | ForEach-Object { Get-Prop $_ @('Name') } | Where-Object { $_ })
        if ($names.Count -gt 0) { return $names }
    }

    # 3) Dernier repli : methode portee par l'objet pool lui-meme.
    $libObj = Invoke-SafeMethod -InputObject $Pool -Method 'GetLibrary'
    if ($libObj) { return @(Get-Prop $libObj @('Name') | Where-Object { $_ }) }

    return @()
}

function Get-TapeRetentionText {
    <#
        La retention des sauvegardes sur bande est portee par le media pool
        (jamais par le job), d'ou ce decodage separe.
        Structure reelle de RetentionPolicy : { Type ; Value ; Period } ou "Period" est
        l'UNITE (Days/Weeks/Months/Years) et "Value" est le nombre de periodes.
    #>
    [CmdletBinding()]
    param($Pool)

    if ($null -eq $Pool) { return $script:NA }

    $retention = Get-Prop $Pool @('RetentionPolicy', 'Retention')
    $type      = "$(Get-Prop $retention @('Type')            -Default (Get-Prop $Pool @('RetentionType')))"
    $value     = Get-Prop $retention @('Value')              -Default (Get-Prop $Pool @('RetentionValue'))
    $unit      = "$(Get-Prop $retention @('Period', 'PeriodType', 'Unit') -Default '')"

    if ($type -match 'Never|Protect|Permanent') { return 'Protection permanente (bandes jamais ecrasees)' }
    if ($value) {
        $unitFr = switch -Regex ($unit) {
            'Day'    { 'jour(s)' }
            'Week'   { 'semaine(s)' }
            'Month'  { 'mois' }
            'Year'   { 'an(s)' }
            default  { 'periode(s)' }
        }
        return "$value $unitFr"
    }
    if ($type) { return $type }
    return $script:NA
}

function Get-TapeFullBackupScheduleText {
    <#
        Planification des sauvegardes completes sur bande.
        Portee par FullBackupPolicy (Type + DailyOptions/WeeklyOnDays/MonthlyOptions).
        Quand le media pool cible est GFS, l'ordonnancement peut etre porte par
        GFSScheduleOptions plutot que FullBackupPolicy : on sonde la source pertinente
        en priorite selon le type de pool, d'ou l'incoherence observee auparavant.
    #>
    [CmdletBinding()]
    param($Job, [bool]$IsGfsPool)

    $sourcePaths = if ($IsGfsPool) { @('GFSScheduleOptions', 'FullBackupPolicy') } else { @('FullBackupPolicy', 'GFSScheduleOptions') }

    foreach ($sourcePath in $sourcePaths) {
        $policy = Get-Prop $Job @($sourcePath)
        if ($null -eq $policy) { continue }

        $type = "$(Get-Prop $policy @('Type'))"
        if ([string]::IsNullOrWhiteSpace($type) -or $type -match '^(None|Disabled)$') { continue }

        switch -Regex ($type) {
            'Daily' {
                $daily = Get-Prop $policy @('DailyOptions')
                return [pscustomobject]@{
                    Planification  = 'Quotidienne'
                    HeureExecution = Format-TimeValue (Get-Prop $daily @('Period', 'TimeLocal', 'Time'))
                    Jours          = Join-Values (Get-Prop $daily @('DayOfWeek', 'Days'))
                }
            }
            'WeeklyOnDays|Weekly' {
                return [pscustomobject]@{
                    Planification  = 'Hebdomadaire'
                    HeureExecution = Format-TimeValue (Get-Prop $policy @('DailyOptions.Period', 'Period', 'Time'))
                    Jours          = Join-Values (Get-Prop $policy @('WeeklyOnDays', 'DaysOfWeek'))
                }
            }
            'Monthly' {
                $monthly = Get-Prop $policy @('MonthlyOptions')
                return [pscustomobject]@{
                    Planification  = 'Mensuelle'
                    HeureExecution = Format-TimeValue (Get-Prop $monthly @('Period', 'TimeLocal', 'Time'))
                    Jours          = Join-Values @((Get-Prop $monthly @('DayOfWeek')), (Get-Prop $monthly @('DayOfMonth')), (Get-Prop $monthly @('Months'))) -Separator ' - '
                }
            }
            default {
                return [pscustomobject]@{
                    Planification  = $type
                    HeureExecution = $script:NA
                    Jours          = $script:NA
                }
            }
        }
    }

    return [pscustomobject]@{ Planification = 'Manuelle / après job source'; HeureExecution = $script:NA; Jours = $script:NA }
}

function Get-VeeamTapeJobAudit {
    <#  Audit des jobs de sauvegarde sur bande (separes des jobs disque). #>
    [CmdletBinding()]
    param([hashtable]$TapeIndex = @{})

    Write-AuditLog "Collecte des jobs de sauvegarde sur bande..." -Level STEP

    $jobs   = @(Invoke-VBRCommand -Name 'Get-VBRTapeJob')
    $result = New-Object System.Collections.Generic.List[psobject]

    foreach ($job in $jobs) {
        $jobName = "$(Get-Prop $job @('Name', 'Info.Name') -Default 'Job bande inconnu')"
        try {
            # FullBackupMediaPool / IncrementalBackupMediaPool sont des proprietes DIRECTES
            # (objets media pool complets) sur le job de bande - pas d'Id a resoudre via
            # FullBackupPolicy.MediaPoolId, qui n'existe pas et renvoyait systematiquement N/A.
            $fullPool = Get-Prop $job @('FullBackupMediaPool')
            $incrPool = Get-Prop $job @('IncrementalBackupMediaPool')
            $processIncremental = Get-Prop $job @('ProcessIncrementalBackup')

            $fullPoolName = "$(Get-Prop $fullPool @('Name') -Default $script:NA)"
            $isGfsPool    = "$(Get-Prop $fullPool @('Type'))" -match 'Gfs'

            $schedule = Get-TapeFullBackupScheduleText -Job $job -IsGfsPool $isGfsPool

            # Objets sources (jobs disque, repositories ou dossiers selon le type de job)
            $sources = Get-Prop $job @('Object', 'Objects', 'BackupJob')
            $sourceNames = @($sources | ForEach-Object { Get-Prop $_ @('Name', 'Info.Name', 'Job.Name') } | Where-Object { $_ })

            $enabled = Get-Prop $job @('Enabled', 'IsEnabled', 'Info.IsScheduleEnabled')
            $enabledText = if ($null -eq $enabled) { $script:NA } elseif ($enabled -eq $true) { 'Activé' } else { 'Désactivé' }

            $lastResult = Get-Prop $job @('LastResult', 'Info.LatestStatus', 'LastState')
            $lastResultText = if ($null -eq $lastResult -or "$lastResult" -in @('None', 'Undefined')) { 'Jamais exécuté' } else { "$lastResult" }

            # Derniere execution : comme pour les jobs disque, la methode FindLastSession
            # est la source la plus fiable ; les proprietes directes (LastRun...) ne sont
            # pas exposees sur les jobs de bande.
            $lastRun = Get-Prop $job @('LatestRunLocal', 'LastRun')
            if ($null -eq $lastRun) {
                $lastSession = Invoke-SafeMethod -InputObject $job -Method 'FindLastSession'
                $lastRun = Get-Prop $lastSession @('EndTimeUTC', 'EndTime', 'CreationTime')
            }

            $result.Add([pscustomobject]@{
                'Nom du job'            = $jobName
                'Type'                  = "$(Get-Prop $job @('Type', 'JobType', 'TypeToString') -Default 'Backup to Tape')"
                'Activation'            = $enabledText
                'Description'           = "$(Get-Prop $job @('Description', 'Info.Description') -Default '')"
                'Sources'               = Join-Values $sourceNames
                'Media pool (complet)'  = $fullPoolName
                'Media pool (incr.)'    = $(if ($processIncremental -eq $true) { "$(Get-Prop $incrPool @('Name') -Default $script:NA)" } else { 'Non utilisé' })
                'Planification'         = $schedule.Planification
                "Heure d'exécution"     = $schedule.HeureExecution
                'Jours'                 = $schedule.Jours
                'Compression matérielle'= ConvertTo-YesNo (Get-Prop $job @('UseHardwareCompression', 'HardwareCompressionEnabled'))
                'Éjection après job'    = ConvertTo-YesNo (Get-Prop $job @('EjectCurrentMedium', 'EjectMedium'))
                'Export jeu de médias'  = ConvertTo-YesNo (Get-Prop $job @('ExportCurrentMediaSet', 'ExportMediaSet'))
                'Dernière exécution'    = Format-DateValue $lastRun
                'Prochaine exécution'   = Format-DateValue (Get-Prop $job @('NextRun', 'ScheduleOptions.NextRun'))
                'Dernier résultat'      = $lastResultText
            }) | Out-Null
        }
        catch {
            Write-AuditLog "Job bande '$jobName' : erreur d'analyse - $($_.Exception.Message)" -Level WARN
        }
    }

    Write-AuditLog "$($result.Count) job(s) de bande audité(s)." -Level OK
    return $result
}

function Get-VeeamTapeMediaPoolAudit {
    <#  Audit des media pools (retention, chiffrement, WORM, bibliotheques). #>
    [CmdletBinding()]
    param([hashtable]$TapeIndex = @{})

    Write-AuditLog "Collecte des media pools..." -Level STEP

    $result = New-Object System.Collections.Generic.List[psobject]
    if (-not $TapeIndex.MediaPools) { return $result }

    foreach ($pool in $TapeIndex.MediaPools.Values) {
        $poolName = "$(Get-Prop $pool @('Name') -Default 'Media pool')"
        try {
            $poolId = "$(Get-Prop $pool @('Id'))"

            $libraryNames = Resolve-TapeLibraryNames -Pool $pool -TapeIndex $TapeIndex

            $isGfs = "$(Get-Prop $pool @('Type'))" -match 'Gfs'
            $gfsDetailText = 'Non applicable'
            if ($isGfs) {
                # Structure reelle des pools GFS : une propriete <Periode>MediaSetOptions
                # (VBRTapeGFSMediaSetOptions) par periode, portant OverwritePeriod (le nombre
                # de semaines/mois/trimestres/annees a conserver). 0 ou absent = periode non activee.
                $gfsParts = New-Object System.Collections.Generic.List[string]
                foreach ($period in @(
                    @{ Label = 'Hebdo';       Prop = 'WeeklyMediaSetOptions' },
                    @{ Label = 'Mensuel';     Prop = 'MonthlyMediaSetOptions' },
                    @{ Label = 'Trimestriel'; Prop = 'QuarterlyMediaSetOptions' },
                    @{ Label = 'Annuel';      Prop = 'YearlyMediaSetOptions' }
                )) {
                    $periodOptions = Get-Prop $pool @($period.Prop)
                    $value = Get-Prop $periodOptions @('OverwritePeriod') -Default (Get-Prop $pool @("$($period.Prop).OverwritePeriod"))
                    if ($value -and [int]"$value" -gt 0) { $gfsParts.Add("$($period.Label) : $value") }
                }
                $gfsDetailText = if ($gfsParts.Count -gt 0) { $gfsParts -join ' | ' } else { 'Activé (détails indisponibles)' }
            }

            $result.Add([pscustomobject]@{
                'Nom'                   = $poolName
                'Type'                  = "$(Get-Prop $pool @('Type') -Default $script:NA)"
                'Description'           = "$(Get-Prop $pool @('Description') -Default '')"
                'Bibliothèque(s)'       = $(if ($libraryNames.Count -gt 0) { Join-Values $libraryNames } else { $script:NA })
                'Rétention'             = Get-TapeRetentionText -Pool $pool
                'Chiffrement'           = ConvertTo-YesNo (Get-Prop $pool @('EncryptionOptions.Enabled', 'EncryptionOptions', 'EncryptionEnabled', 'IsEncryptionEnabled'))
                'WORM'                  = ConvertTo-YesNo (Get-Prop $pool @('Worm', 'IsWormEnabled', 'WormEnabled'))
                'Traitement parallèle'  = ConvertTo-YesNo (Get-Prop $pool @('MultiStreamingOptions.Enabled', 'MultiStreamingOptions.IsEnabled', 'ParallelProcessing', 'IsParallelProcessingEnabled'))
                'Nouveau jeu de médias' = "$(Get-Prop $pool @('MediaSetCreationPolicy', 'MediaSetPolicy.CreateNewMediaSet', 'MediaSetPolicy.Type') -Default $script:NA)"
                'GFS'                   = ConvertTo-YesNo $isGfs
                'Détail GFS'            = $gfsDetailText
            }) | Out-Null
        }
        catch {
            Write-AuditLog "Media pool '$poolName' : erreur d'analyse - $($_.Exception.Message)" -Level WARN
        }
    }

    Write-AuditLog "$($result.Count) media pool(s) audité(s)." -Level OK
    return $result
}

function Get-VeeamTapeMediumAudit {
    <#
        Etat des bandes : statut, emplacement, occupation, expiration.
        Le nombre de bandes pouvant etre tres eleve, le detail est plafonne
        par -TapeMediaLimit ; la synthese par media pool reste toujours complete.
    #>
    [CmdletBinding()]
    param([hashtable]$TapeIndex = @{}, [int]$Limit = 500)

    Write-AuditLog "Collecte de l'état des bandes..." -Level STEP

    $media   = @(Invoke-VBRCommand -Name 'Get-VBRTapeMedium')
    $detail  = New-Object System.Collections.Generic.List[psobject]
    $summary = New-Object System.Collections.Generic.List[psobject]

    if ($media.Count -eq 0) {
        Write-AuditLog "Aucune bande recensée." -Level INFO
        return [pscustomobject]@{ Detail = $detail; Synthese = $summary; Total = 0; Expirees = 0; Tronque = $false }
    }

    $stats = @{}

    foreach ($medium in $media) {
        $poolId   = "$(Get-Prop $medium @('MediaPoolId', 'MediaPool.Id'))"
        $poolName = Resolve-IndexName -Index $TapeIndex.MediaPools -Id $poolId -Default 'Hors pool'

        $isFree      = Get-Prop $medium @('IsFree')
        $isExpired   = Get-Prop $medium @('IsExpired')
        $isProtected = Get-Prop $medium @('IsProtected', 'Protected')
        $isWorm      = Get-Prop $medium @('IsWorm', 'Worm')
        $isRetired   = Get-Prop $medium @('IsRetired', 'Retired')

        # Une bande "retired" est definitivement sortie de rotation (defaillante / mise au rebut) :
        # c'est la seule situation a signaler en rouge. Une bande "expiree" a simplement depasse sa
        # retention et redeviendra disponible a la prochaine ecriture : simple avertissement (jaune).
        $status = if ($isRetired -eq $true)   { 'Retirée' }
                  elseif ($isProtected -eq $true) { 'Protégée' }
                  elseif ($isExpired -eq $true)   { 'Expirée' }
                  elseif ($isFree -eq $true)      { 'Libre' }
                  else                             { 'Utilisée' }
        if ($isWorm -eq $true) { $status = "$status (WORM)" }

        $capacity = Get-Prop $medium @('Capacity', 'Capacity.InBytes')
        $free     = Get-Prop $medium @('FreeSpace', 'Free', 'FreeSpace.InBytes')

        # Synthese par pool
        if (-not $stats.ContainsKey($poolName)) {
            $stats[$poolName] = [ordered]@{ Total = 0; Libres = 0; Utilisees = 0; Expirees = 0; Protegees = 0; Retirees = 0; Capacite = 0.0; Libre = 0.0 }
        }
        $stats[$poolName].Total++
        if ($isFree -eq $true)      { $stats[$poolName].Libres++ }    else { $stats[$poolName].Utilisees++ }
        if ($isExpired -eq $true)   { $stats[$poolName].Expirees++ }
        if ($isProtected -eq $true) { $stats[$poolName].Protegees++ }
        if ($isRetired -eq $true)   { $stats[$poolName].Retirees++ }
        try { if ($capacity) { $stats[$poolName].Capacite += [double]$capacity } } catch { }
        try { if ($free)     { $stats[$poolName].Libre    += [double]$free } }     catch { }

        if ($detail.Count -lt $Limit) {
            $location = "$(Get-Prop $medium @('Location') -Default $script:NA)"
            $slot     = Get-Prop $medium @('SlotAddress', 'Address', 'Slot')
            if ($slot) { $location = "$location $slot" }
            $vaultId = "$(Get-Prop $medium @('VaultId', 'Vault.Id'))"
            if ($vaultId) {
                $vaultName = Resolve-IndexName -Index $TapeIndex.Vaults -Id $vaultId -Default $null
                if ($vaultName) { $location = "Coffre : $vaultName" }
            }

            $detail.Add([pscustomobject]@{
                'Code-barres'        = "$(Get-Prop $medium @('Barcode', 'Name') -Default $script:NA)"
                'Nom'                = "$(Get-Prop $medium @('Name') -Default $script:NA)"
                'Media pool'         = $poolName
                'Bibliothèque'       = Resolve-IndexName -Index $TapeIndex.Libraries -Id "$(Get-Prop $medium @('LibraryId', 'Library.Id'))"
                'Emplacement'        = $location
                'Statut'             = $status
                'Capacité'           = Format-Size $capacity
                'Espace libre'       = Format-Size $free
                'Jeu de médias'      = "$(Get-Prop $medium @('MediaSetName', 'MediaSet.Name') -Default $script:NA)"
                'Séquence'           = "$(Get-Prop $medium @('SequenceNumber') -Default $script:NA)"
                'Dernière écriture'  = Format-DateValue (Get-Prop $medium @('LastWriteTime', 'LastWrite'))
                "Date d'expiration"  = Format-DateValue (Get-Prop $medium @('ExpirationDate', 'ExpirationTime'))
            }) | Out-Null
        }
    }

    foreach ($poolName in ($stats.Keys | Sort-Object)) {
        $s = $stats[$poolName]
        $summary.Add([pscustomobject]@{
            'Media pool'        = $poolName
            'Bandes'            = $s.Total
            'Libres'            = $s.Libres
            'Utilisées'         = $s.Utilisees
            'Expirées'          = $s.Expirees
            'Protégées'         = $s.Protegees
            'Retirées'          = $s.Retirees
            'Capacité totale'   = Format-Size $s.Capacite
            'Espace libre'      = Format-Size $s.Libre
        }) | Out-Null
    }

    $totalExpired = ($stats.Values | ForEach-Object { $_.Expirees } | Measure-Object -Sum).Sum
    $truncated = $media.Count -gt $Limit
    if ($truncated) {
        Write-AuditLog "$($media.Count) bandes recensées : le détail est limité aux $Limit premières (voir -TapeMediaLimit)." -Level WARN
    }
    Write-AuditLog "$($media.Count) bande(s) recensée(s) dans $($stats.Count) pool(s)." -Level OK

    return [pscustomobject]@{
        Detail   = $detail
        Synthese = $summary
        Total    = $media.Count
        Expirees = [int]$totalExpired
        Tronque  = $truncated
    }
}

function Get-VeeamTapeInfrastructureAudit {
    <#  Serveurs de bande, bibliotheques et lecteurs. #>
    [CmdletBinding()]
    param([hashtable]$TapeIndex = @{})

    Write-AuditLog "Collecte de l'infrastructure bande (bibliothèques et lecteurs)..." -Level STEP

    $libraries = New-Object System.Collections.Generic.List[psobject]
    $drives    = New-Object System.Collections.Generic.List[psobject]

    foreach ($library in @($TapeIndex.Libraries.Values)) {
        $libName = "$(Get-Prop $library @('Name') -Default 'Bibliothèque')"
        try {
            $serverId   = "$(Get-Prop $library @('ServerId', 'TapeServerId', 'Server.Id'))"
            $serverName = Resolve-IndexName -Index $TapeIndex.TapeServers -Id $serverId

            $libraryDrives = @(Invoke-VBRCommand -Name 'Get-VBRTapeDrive' -Parameters @{ Library = $library } -Quiet)
            if ($libraryDrives.Count -eq 0) {
                $libraryDrives = @(Invoke-VBRCommand -Name 'Get-VBRTapeDrive' -Quiet |
                                   Where-Object { "$(Get-Prop $_ @('LibraryId'))" -eq "$(Get-Prop $library @('Id'))" })
            }

            $enabled = Get-Prop $library @('IsEnabled', 'Enabled')
            $state   = "$(Get-Prop $library @('State', 'Status') -Default $script:NA)"

            $libraries.Add([pscustomobject]@{
                'Bibliothèque'      = $libName
                'Modèle'            = "$(Get-Prop $library @('Model') -Default $script:NA)"
                'Type'              = "$(Get-Prop $library @('Type') -Default $script:NA)"
                'Serveur de bande'  = $serverName
                'État'              = $(if ($enabled -eq $false) { 'Désactivé' } elseif ($state -ne $script:NA) { $state } else { 'Activé' })
                'Nombre de lecteurs'= $libraryDrives.Count
                'Nombre de slots'   = "$(Get-Prop $library @('SlotCount', 'NumberOfSlots') -Default $script:NA)"
            }) | Out-Null

            foreach ($drive in $libraryDrives) {
                $driveState = "$(Get-Prop $drive @('State', 'Status') -Default $script:NA)"
                $driveEnabled = Get-Prop $drive @('IsEnabled', 'Enabled')
                $mediumName = Get-Prop $drive @('Medium.Barcode', 'Medium.Name', 'MediumName')

                $drives.Add([pscustomobject]@{
                    'Lecteur'        = "$(Get-Prop $drive @('Name') -Default 'Lecteur')"
                    'Bibliothèque'   = $libName
                    'Modèle'         = "$(Get-Prop $drive @('Model') -Default $script:NA)"
                    'Adresse'        = "$(Get-Prop $drive @('Address', 'DriveAddress') -Default $script:NA)"
                    'État'           = $(if ($driveEnabled -eq $false) { 'Désactivé' } else { $driveState })
                    'Bande chargée'  = "$(if ($mediumName) { $mediumName } else { 'Aucune' })"
                    'Serveur'        = $serverName
                }) | Out-Null
            }
        }
        catch {
            Write-AuditLog "Bibliothèque '$libName' : erreur d'analyse - $($_.Exception.Message)" -Level WARN
        }
    }

    # Lecteurs autonomes (hors bibliotheque)
    if ($libraries.Count -eq 0) {
        foreach ($drive in @(Invoke-VBRCommand -Name 'Get-VBRTapeDrive' -Quiet)) {
            $drives.Add([pscustomobject]@{
                'Lecteur'       = "$(Get-Prop $drive @('Name') -Default 'Lecteur')"
                'Bibliothèque'  = 'Autonome'
                'Modèle'        = "$(Get-Prop $drive @('Model') -Default $script:NA)"
                'Adresse'       = "$(Get-Prop $drive @('Address') -Default $script:NA)"
                'État'          = "$(Get-Prop $drive @('State') -Default $script:NA)"
                'Bande chargée' = "$(Get-Prop $drive @('Medium.Barcode', 'Medium.Name') -Default 'Aucune')"
                'Serveur'       = $script:NA
            }) | Out-Null
        }
    }

    $servers = New-Object System.Collections.Generic.List[psobject]
    foreach ($tapeServer in @($TapeIndex.TapeServers.Values)) {
        $available = Get-Prop $tapeServer @('IsAvailable', 'IsUnavailable')
        $statut = if ($null -eq $available) { $script:NA }
                  elseif ((Get-Prop $tapeServer @('IsUnavailable')) -eq $true) { 'Indisponible' }
                  elseif ($available -eq $false) { 'Indisponible' }
                  else { 'Disponible' }

        $serverName = "$(Get-Prop $tapeServer @('Name') -Default $script:NA)"
        $servers.Add([pscustomobject]@{
            'Serveur de bande' = $serverName
            'Description'      = "$(Get-Prop $tapeServer @('Description') -Default '')"
            'Statut'           = $statut
            'OS'               = Get-RemoteOsInfo -ComputerName $serverName
        }) | Out-Null
    }

    Write-AuditLog "$($libraries.Count) bibliothèque(s), $($drives.Count) lecteur(s), $($servers.Count) serveur(s) de bande." -Level OK

    return [pscustomobject]@{
        Serveurs       = $servers
        Bibliotheques  = $libraries
        Lecteurs       = $drives
    }
}

#endregion

#region ---------------------------------------------------------------- SureBackup

function Get-VeeamSureBackupAudit {
    <#
        Verifie si SureBackup est configure : virtual labs, application groups
        et jobs de verification. Retourne egalement l'indicateur Configure.
    #>
    [CmdletBinding()]
    param()

    Write-AuditLog "Collecte de la configuration SureBackup..." -Level STEP

    $labs   = New-Object System.Collections.Generic.List[psobject]
    $groups = New-Object System.Collections.Generic.List[psobject]
    $jobs   = New-Object System.Collections.Generic.List[psobject]

    # --- Virtual labs
    foreach ($lab in @(Invoke-VBRCommand -Name 'Get-VBRVirtualLab')) {
        $labName = "$(Get-Prop $lab @('Name') -Default 'Virtual lab')"
        try {
            $labs.Add([pscustomobject]@{
                'Virtual lab'        = $labName
                'Description'        = "$(Get-Prop $lab @('Description') -Default '')"
                'Plateforme'         = "$(Get-Prop $lab @('Platform', 'Type') -Default $script:NA)"
                'Serveur hôte'       = "$(Get-Prop $lab @('Server.Name', 'Host.Name', 'ServerName') -Default $script:NA)"
                'Datastore'          = "$(Get-Prop $lab @('Datastore.Name', 'DatastoreName', 'RedirectDatastore.Name') -Default $script:NA)"
                'Dossier'            = "$(Get-Prop $lab @('Folder.Name', 'FolderName', 'Path') -Default $script:NA)"
                'Appliance proxy'    = "$(Get-Prop $lab @('ProxyAppliance.Name', 'ProxyApplianceName', 'ProxyAppliance.IpAddress') -Default $script:NA)"
                'Mode réseau'        = "$(Get-Prop $lab @('NetworkOptions.Type', 'NetworkingType', 'NetworkType') -Default $script:NA)"
            }) | Out-Null
        }
        catch {
            Write-AuditLog "Virtual lab '$labName' : erreur d'analyse - $($_.Exception.Message)" -Level WARN
        }
    }

    # --- Application groups
    foreach ($group in @(Invoke-VBRCommand -Name 'Get-VBRApplicationGroup')) {
        $groupName = "$(Get-Prop $group @('Name') -Default 'Application group')"
        try {
            $members = Get-Prop $group @('VM', 'Object', 'Objects', 'ApplicationGroupObject')
            $memberNames = @(@($members) | ForEach-Object { Get-Prop $_ @('Name', 'Object.Name', 'VmName') } | Where-Object { $_ })
            $roles = @(@($members) | ForEach-Object { Get-Prop $_ @('Role', 'Roles') } | Where-Object { $_ } | ForEach-Object { "$_" })

            $groups.Add([pscustomobject]@{
                'Application group' = $groupName
                'Description'       = "$(Get-Prop $group @('Description') -Default '')"
                'Nombre de machines'= @($members).Count
                'Machines'          = Join-Values $memberNames
                'Rôles'             = Join-Values ($roles | Select-Object -Unique)
            }) | Out-Null
        }
        catch {
            Write-AuditLog "Application group '$groupName' : erreur d'analyse - $($_.Exception.Message)" -Level WARN
        }
    }

    # --- Jobs SureBackup (cmdlet dediee, sinon filtrage des jobs generiques)
    $sureJobs = @(Invoke-VBRCommand -Name 'Get-VBRSureBackupJob' -Quiet)
    if ($sureJobs.Count -eq 0) {
        $sureJobs = @(Invoke-VBRCommand -Name 'Get-VBRJob' -Quiet |
                      Where-Object { "$(Get-Prop $_ @('JobType', 'TypeToString'))" -match 'SureBackup' })
    }

    foreach ($job in $sureJobs) {
        $jobName = "$(Get-Prop $job @('Name') -Default 'Job SureBackup')"
        try {
            $enabled = Get-Prop $job @('IsEnabled', 'Enabled', 'Info.IsScheduleEnabled')
            if ($null -eq $enabled) { $enabled = Invoke-SafeMethod -InputObject $job -Method 'IsScheduleEnabled' }
            $enabledText = if ($null -eq $enabled) { $script:NA } elseif ($enabled -eq $true) { 'Activé' } else { 'Désactivé' }

            $linked = Get-Prop $job @('LinkedJob', 'LinkedJobs', 'BackupJob')
            $linkedNames = @(@($linked) | ForEach-Object { Get-Prop $_ @('Name', 'Job.Name') } | Where-Object { $_ })

            $schedule = Get-Prop $job @('ScheduleOptions')
            $scheduleText = Get-JobScheduleText -Schedule $schedule

            $lastResult = Get-Prop $job @('LastResult', 'Info.LatestStatus')
            if ($null -eq $lastResult) { $lastResult = Invoke-SafeMethod -InputObject $job -Method 'GetLastResult' }
            $lastResultText = if ($null -eq $lastResult -or "$lastResult" -in @('None', 'Undefined')) { 'Jamais exécuté' } else { "$lastResult" }

            $jobs.Add([pscustomobject]@{
                'Job SureBackup'      = $jobName
                'Activation'          = $enabledText
                'Description'         = "$(Get-Prop $job @('Description', 'Info.Description') -Default '')"
                'Virtual lab'         = "$(Get-Prop $job @('VirtualLab.Name', 'VirtualLabName', 'VirtualLab') -Default $script:NA)"
                'Application group'   = "$(Get-Prop $job @('ApplicationGroup.Name', 'ApplicationGroupName', 'ApplicationGroup') -Default 'Aucun')"
                'Jobs vérifiés'       = Join-Values $linkedNames
                'Planification'       = $scheduleText.Planification
                "Heure d'exécution"   = $scheduleText.HeureExecution
                'Jours'               = $scheduleText.Jours
                'Groupe maintenu actif' = ConvertTo-YesNo (Get-Prop $job @('KeepApplicationGroupRunning', 'KeepApplicationGroup'))
                'Test intégrité (CRC)'  = ConvertTo-YesNo (Get-Prop $job @('VerificationOptions.EnableValidation', 'EnableValidation', 'BackupValidation'))
                'Analyse antimalware'   = ConvertTo-YesNo (Get-Prop $job @('VerificationOptions.EnableMalwareScan', 'EnableMalwareScan', 'MalwareScanEnabled'))
                'Dernière exécution'    = Format-DateValue (Get-Prop $job @('LastRun', 'Info.LatestRunLocal', 'LatestRunLocal'))
                'Dernier résultat'      = $lastResultText
            }) | Out-Null
        }
        catch {
            Write-AuditLog "Job SureBackup '$jobName' : erreur d'analyse - $($_.Exception.Message)" -Level WARN
        }
    }

    $configured = ($labs.Count -gt 0 -or $groups.Count -gt 0 -or $jobs.Count -gt 0)
    if ($configured) {
        Write-AuditLog "SureBackup : $($jobs.Count) job(s), $($labs.Count) virtual lab(s), $($groups.Count) application group(s)." -Level OK
    }
    else {
        Write-AuditLog "SureBackup n'est pas configuré sur cette infrastructure." -Level WARN
    }

    return [pscustomobject]@{
        Configure         = $configured
        VirtualLabs       = $labs
        ApplicationGroups = $groups
        Jobs              = $jobs
    }
}

#endregion

#region ---------------------------------------------------------------- Storage infrastructure

function Get-VeeamStorageInfrastructureAudit {
    <#
        Baies de stockage integrees (snapshots SAN / SanHost) UNIQUEMENT.
        Les cmdlets varient fortement selon les versions et les constructeurs :
        une liste connue est completee par une decouverte dynamique des cmdlets
        'Get-*Host' exposees par les modules Veeam, puis par un filet de securite
        sur les serveurs Get-VBRServer de type SanHost.
    #>
    [CmdletBinding()]
    param()

    Write-AuditLog "Collecte de la storage infrastructure..." -Level STEP

    # Cmdlets connues : nom -> libelle constructeur
    $known = [ordered]@{
        'Get-NetAppHost'                = 'NetApp ONTAP'
        'Get-VBRNetAppHost'             = 'NetApp ONTAP'
        'Get-HP3PARHost'                = 'HPE 3PAR / Primera / Alletra'
        'Get-HPStoreVirtualHost'        = 'HPE StoreVirtual'
        'Get-NimbleHost'                = 'HPE Nimble / Alletra'
        'Get-VBRIsilonHost'             = 'Dell PowerScale (Isilon)'
        'Get-VBRUniversalStorageHost'   = 'Universal Storage API (Pure, INFINIDAT, ...)'
        'Get-VBRDellScHost'             = 'Dell SC Series'
        'Get-VBRDellPowerMaxHost'       = 'Dell PowerMax'
        'Get-VBRHuaweiDoradoHost'       = 'Huawei OceanStor Dorado'
        'Get-VBRIBMSpectrumHost'        = 'IBM Spectrum Virtualize'
        'Get-VBRFujitsuEternusHost'     = 'Fujitsu ETERNUS'
        'Get-VBRTintriHost'             = 'Tintri'
        'Get-VBRLenovoThinkSystemHost'  = 'Lenovo ThinkSystem'
        'Get-VBRHitachiHost'            = 'Hitachi VSP'
        'Get-VBRPureStorageHost'        = 'Pure Storage'
        'Get-VBRInfiniDatHost'          = 'INFINIDAT'
        'Get-VBRWesternDigitalHost'     = 'Western Digital'
    }

    # Decouverte dynamique : toute cmdlet Veeam 'Get-*Host' non deja connue,
    # hors hyperviseurs et serveurs d'inventaire.
    $excluded = @('Get-VBRLocalhost', 'Get-VBRHvHost', 'Get-VBRViHost', 'Get-VBRESXHost', 'Get-VBRvCloudHost', 'Get-VBRComputerHost', 'Get-VBRPhysicalHost')
    try {
        $discovered = Get-Command -Name 'Get-*Host' -ErrorAction SilentlyContinue |
                      Where-Object { $_.ModuleName -like 'Veeam*' -and $_.Name -notin $excluded -and $_.Name -notmatch 'Proxy' -and -not $known.Contains($_.Name) }
        foreach ($cmd in @($discovered)) {
            $known[$cmd.Name] = 'Baie détectée automatiquement'
            Write-AuditLog "Cmdlet de stockage supplémentaire détectée : $($cmd.Name)" -Level INFO
        }
    }
    catch { }

    $result = New-Object System.Collections.Generic.List[psobject]
    $seen   = New-Object System.Collections.Generic.HashSet[string]

    foreach ($cmdlet in $known.Keys) {
        foreach ($storage in @(Invoke-VBRCommand -Name $cmdlet -Quiet)) {
            $storageName = "$(Get-Prop $storage @('Name', 'Info.Name', 'HostName') -Default 'Baie inconnue')"
            if (-not $seen.Add("$cmdlet|$storageName")) { continue }

            $result.Add([pscustomobject]@{
                'Nom'            = $storageName
                'Catégorie'      = 'Baie de stockage (snapshots SAN)'
                'Constructeur'   = $known[$cmdlet]
                'Type / modèle'  = "$(Get-Prop $storage @('Type', 'Model', 'StorageType') -Default $script:NA)"
                'Version'        = "$(Get-Prop $storage @('Version', 'FirmwareVersion') -Default $script:NA)"
                'Description'    = "$(Get-Prop $storage @('Description') -Default '')"
                'Statut'         = $(if ((Get-Prop $storage @('IsUnavailable')) -eq $true) { 'Indisponible' } else { 'Disponible' })
                'Source'         = $cmdlet
            }) | Out-Null
        }
    }

    # Filet de securite : tout serveur remonte par Get-VBRServer avec Type = SanHost
    # (baie enregistree pour l'integration snapshots SAN) doit apparaitre ici, meme si
    # aucune cmdlet constructeur dediee ne l'a deja recensee ci-dessus. La storage
    # infrastructure ne doit contenir QUE des SanHost : pas de NAS ni d'autres serveurs geres.
    foreach ($srv in @(Invoke-VBRCommand -Name 'Get-VBRServer' -Quiet)) {
        $srvType = "$(Get-Prop $srv @('Type', 'Info.Type'))"
        if ($srvType -notmatch 'SanHost') { continue }

        $storageName = "$(Get-Prop $srv @('Name', 'Info.Name') -Default 'Baie inconnue')"
        if (-not $seen.Add("SanHost|$storageName")) { continue }

        $result.Add([pscustomobject]@{
            'Nom'            = $storageName
            'Catégorie'      = 'Baie de stockage (snapshots SAN)'
            'Constructeur'   = 'SanHost (non détaillé par cmdlet constructeur)'
            'Type / modèle'  = $srvType
            'Version'        = "$(Get-Prop $srv @('ApiVersion', 'Info.ApiVersion') -Default $script:NA)"
            'Description'    = "$(Get-Prop $srv @('Description', 'Info.Description') -Default '')"
            'Statut'         = $(if ((Get-Prop $srv @('IsUnavailable', 'Info.IsUnavailable')) -eq $true) { 'Indisponible' } else { 'Disponible' })
            'Source'         = 'Get-VBRServer (SanHost)'
        }) | Out-Null
    }

    if ($result.Count -eq 0) {
        Write-AuditLog "Aucune baie de stockage ni source NAS intégrée." -Level INFO
    }
    else {
        Write-AuditLog "$($result.Count) élément(s) de storage infrastructure recensé(s)." -Level OK
    }

    return $result
}

#endregion

#region ---------------------------------------------------------------- Synthese & rapport

function Get-VeeamGlobalStatus {
    <#  Calcule le statut general et les points d'attention de l'infrastructure. #>
    [CmdletBinding()]
    param($Audit)

    $alerts   = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    # --- Jobs
    $jobs        = @($Audit.Jobs)
    $failedJobs  = @($jobs | Where-Object { "$($_.'Dernier résultat')" -match 'Failed' })
    $warningJobs = @($jobs | Where-Object { "$($_.'Dernier résultat')" -match 'Warning' })
    $neverRun    = @($jobs | Where-Object { "$($_.'Dernier résultat')" -eq 'Jamais exécuté' })
    $disabled    = @($jobs | Where-Object { "$($_.Activation)" -eq 'Désactivé' })
    $noEncrypt   = @($jobs | Where-Object { "$($_.Chiffrement)" -eq 'Non' })

    if ($failedJobs.Count  -gt 0) { $alerts.Add("$($failedJobs.Count) job(s) en échec lors de la dernière exécution") }
    if ($warningJobs.Count -gt 0) { $warnings.Add("$($warningJobs.Count) job(s) en avertissement") }
    if ($disabled.Count    -gt 0) { $warnings.Add("$($disabled.Count) job(s) désactivé(s)") }
    if ($neverRun.Count    -gt 0) { $warnings.Add("$($neverRun.Count) job(s) jamais exécuté(s)") }
    if ($noEncrypt.Count   -gt 0) { $warnings.Add("$($noEncrypt.Count) job(s) sans chiffrement") }

    # --- Repositories
    $repos      = @($Audit.Repositories)
    $reposFull  = @($repos | Where-Object { $null -ne $_.TauxNumerique -and $_.TauxNumerique -ge 90 })
    $reposWarn  = @($repos | Where-Object { $null -ne $_.TauxNumerique -and $_.TauxNumerique -ge 80 -and $_.TauxNumerique -lt 90 })
    $reposDown  = @($repos | Where-Object { "$($_.Statut)" -match 'Indisponible' })
    $reposImmut = @($repos | Where-Object { "$($_.'Immutabilité')" -match '^Oui' })

    if ($reposFull.Count -gt 0) { $alerts.Add("$($reposFull.Count) repository(s) à plus de 90 % d'occupation") }
    if ($reposDown.Count -gt 0) { $alerts.Add("$($reposDown.Count) repository(s) indisponible(s)") }
    if ($reposWarn.Count -gt 0) { $warnings.Add("$($reposWarn.Count) repository(s) entre 80 et 90 % d'occupation") }
    if ($repos.Count -gt 0 -and $reposImmut.Count -eq 0) { $warnings.Add("Aucun repository avec immuabilité activée") }

    # --- Licence
    $license  = $Audit.License
    $daysLeft = "$($license.'Jours restants')"
    if ($daysLeft -match 'Expiree')      { $alerts.Add("Licence expirée") }
    elseif ($daysLeft -match '^\d+$') {
        if ([int]$daysLeft -le 30)       { $alerts.Add("Licence expirant dans $daysLeft jour(s)") }
        elseif ([int]$daysLeft -le 90)   { $warnings.Add("Licence expirant dans $daysLeft jour(s)") }
    }

    # Depassement d'utilisation : plus d'instances (ou de sockets) consommees que ce que la licence autorise.
    $instancesRemaining = "$($license.'Instances restantes')"
    if ($instancesRemaining -match '^-\d+$') {
        $over = [math]::Abs([int]$instancesRemaining)
        $warnings.Add("Licence en dépassement d'utilisation : $over instance(s) consommée(s) au-delà du volume licencié ($($license.'Instances licenciées') licenciée(s), $($license.'Instances utilisees') utilisée(s))")
    }
    $licensedSockets = "$($license.'Sockets licenciés')"
    $usedSockets     = "$($license.'Sockets utilises')"
    if ($licensedSockets -match '^\d+$' -and $usedSockets -match '^\d+$' -and [int]$usedSockets -gt [int]$licensedSockets) {
        $overSockets = [int]$usedSockets - [int]$licensedSockets
        $warnings.Add("Licence en dépassement d'utilisation (sockets) : $overSockets socket(s) consommé(s) au-delà du volume licencié ($licensedSockets licencié(s), $usedSockets utilisé(s))")
    }

    # --- Services
    $servicesStopped = @($Audit.Services | Where-Object { "$($_.'État')" -ne 'Running' -and "$($_.'Démarrage')" -eq 'Auto' })
    if ($servicesStopped.Count -gt 0) {
        $alerts.Add("$($servicesStopped.Count) service(s) Veeam en démarrage automatique mais arrêté(s)")
    }

    # --- Sauvegardes sur bande
    $tapeJobs       = @($Audit.TapeJobs)
    $tapeJobsFailed = @($tapeJobs | Where-Object { "$($_.'Dernier résultat')" -match 'Failed' })
    $tapeJobsOff    = @($tapeJobs | Where-Object { "$($_.Activation)" -eq 'Désactivé' })
    if ($tapeJobsFailed.Count -gt 0) { $alerts.Add("$($tapeJobsFailed.Count) job(s) de bande en échec") }
    if ($tapeJobsOff.Count    -gt 0) { $warnings.Add("$($tapeJobsOff.Count) job(s) de bande désactivé(s)") }

    $tapeMedia = $Audit.TapeMedia
    $nbTapes   = 0
    if ($null -ne $tapeMedia) {
        $nbTapes = [int]$tapeMedia.Total
        if ([int]$tapeMedia.Expirees -gt 0) {
            $warnings.Add("$($tapeMedia.Expirees) bande(s) expirée(s) - à recycler ou à sortir du pool")
        }
    }

    $tapeDrivesKo = @($Audit.TapeInfrastructure.Lecteurs | Where-Object { "$($_.'État')" -match 'Désactivé|Offline|Error|Failed' })
    if ($tapeDrivesKo.Count -gt 0) { $alerts.Add("$($tapeDrivesKo.Count) lecteur(s) de bande indisponible(s) ou désactivé(s)") }

    # --- SureBackup : l'absence de vérification de restaurabilité est un constat d'audit
    $sureBackup   = $Audit.SureBackup
    $nbSureJobs   = 0
    if ($null -ne $sureBackup) {
        $nbSureJobs = @($sureBackup.Jobs).Count
        if (-not $sureBackup.Configure) {
            $warnings.Add("SureBackup non configuré : aucune vérification automatique de la restaurabilité")
        }
        elseif ($nbSureJobs -eq 0) {
            $warnings.Add("SureBackup partiellement configuré : virtual lab présent mais aucun job de vérification")
        }
        else {
            $sureFailed = @($sureBackup.Jobs | Where-Object { "$($_.'Dernier résultat')" -match 'Failed' })
            if ($sureFailed.Count -gt 0) { $alerts.Add("$($sureFailed.Count) job(s) SureBackup en échec") }
        }
    }

    $status = if ($alerts.Count -gt 0) { 'CRITIQUE' } elseif ($warnings.Count -gt 0) { 'ATTENTION' } else { 'CONFORME' }

    return [pscustomobject]@{
        Statut            = $status
        Alertes           = $alerts
        Avertissements    = $warnings
        NbJobs            = $jobs.Count
        NbJobsActifs      = ($jobs.Count - $disabled.Count)
        NbJobsEchec       = $failedJobs.Count
        NbJobsWarning     = $warningJobs.Count
        NbRepositories    = $repos.Count
        NbSobr            = @($Audit.ScaleOutRepositories).Count
        NbProxies         = @($Audit.Proxies).Count
        NbServeursManages = @($Audit.ManagedServers).Count
        NbJobsBande       = $tapeJobs.Count
        NbBandes          = $nbTapes
        NbLecteursBande   = @($Audit.TapeInfrastructure.Lecteurs).Count
        NbJobsSureBackup  = $nbSureJobs
        SureBackupConfig  = $(if ($null -ne $sureBackup -and $sureBackup.Configure) { 'Oui' } else { 'Non' })
        NbBaiesStockage   = @($Audit.StorageInfrastructure).Count
    }
}

function ConvertTo-HtmlSafe {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    return ("$Value").Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Get-CellCssClass {
    <#  Colorise les cellules selon des mots-cles metier. #>
    param([string]$Value)
    switch -Regex ($Value) {
        '(espace critique|Expirée depuis|^Retirée)'                  { return 'bad' }
        '(espace faible|^Expirée)'                                   { return 'warn' }
        '^(Success|Disponible|Activé|Oui|Running|CONFORME)'          { return 'ok' }
        '^(Warning|ATTENTION|Espace faible|Jamais exécuté)'          { return 'warn' }
        '^(Failed|Indisponible|Désactivé|CRITIQUE)'                  { return 'bad' }
        default                                                      { return '' }
    }
}

function ConvertTo-AuditHtmlTable {
    <#  Genere un tableau HTML a partir d'une collection d'objets. #>
    [CmdletBinding()]
    param(
        [AllowNull()]$Data,
        [string[]]$ExcludeColumns = @()
    )

    $rows = @($Data)
    if ($rows.Count -eq 0) {
        return '<p class="empty">Aucune donnée collectée pour cette section.</p>'
    }

    $columns = @($rows[0].PSObject.Properties.Name | Where-Object { $_ -notin $ExcludeColumns })

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="table-wrap"><table><thead><tr>')
    foreach ($column in $columns) {
        [void]$sb.Append("<th>$(ConvertTo-HtmlSafe $column)</th>")
    }
    [void]$sb.Append('</tr></thead><tbody>')

    foreach ($row in $rows) {
        [void]$sb.Append('<tr>')
        foreach ($column in $columns) {
            $value = "$($row.$column)"
            $class = Get-CellCssClass -Value $value
            $classAttr = if ($class) { " class=`"$class`"" } else { '' }
            [void]$sb.Append("<td$classAttr>$(ConvertTo-HtmlSafe $value)</td>")
        }
        [void]$sb.Append('</tr>')
    }

    [void]$sb.Append('</tbody></table></div>')
    return $sb.ToString()
}

function ConvertTo-AuditHtmlKeyValue {
    <#  Genere un tableau cle/valeur a partir d'un objet unique. #>
    param([AllowNull()]$Object)

    if ($null -eq $Object) { return '<p class="empty">Aucune donnée.</p>' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="table-wrap"><table class="kv"><tbody>')
    foreach ($property in $Object.PSObject.Properties) {
        $value = "$($property.Value)"
        $class = Get-CellCssClass -Value $value
        $classAttr = if ($class) { " class=`"$class`"" } else { '' }
        [void]$sb.Append("<tr><th>$(ConvertTo-HtmlSafe $property.Name)</th><td$classAttr>$(ConvertTo-HtmlSafe $value)</td></tr>")
    }
    [void]$sb.Append('</tbody></table></div>')
    return $sb.ToString()
}

function New-VeeamHtmlReport {
    <#  Assemble le rapport HTML autoportant. #>
    [CmdletBinding()]
    param($Audit, [string]$Path)

    $summary = $Audit.Summary
    $statusClass = switch ($summary.Statut) {
        'CONFORME'  { 'ok' }
        'ATTENTION' { 'warn' }
        default     { 'bad' }
    }

    $alertsHtml = ''
    if ($summary.Alertes.Count -gt 0 -or $summary.Avertissements.Count -gt 0) {
        $items = New-Object System.Text.StringBuilder
        foreach ($alert in $summary.Alertes)        { [void]$items.Append("<li class=`"bad`">$(ConvertTo-HtmlSafe $alert)</li>") }
        foreach ($warning in $summary.Avertissements) { [void]$items.Append("<li class=`"warn`">$(ConvertTo-HtmlSafe $warning)</li>") }
        $alertsHtml = "<div class=`"panel`"><h3>Points d'attention</h3><ul class=`"alerts`">$($items.ToString())</ul></div>"
    }
    else {
        $alertsHtml = '<div class="panel"><h3>Points d''attention</h3><p class="empty">Aucun point d''attention détecté.</p></div>'
    }

    $logHtml = ConvertTo-AuditHtmlTable -Data (@($script:AuditLog | Where-Object { $_.Niveau -in @('WARN', 'ERROR') } |
                                                 Select-Object @{n='Horodatage';e={$_.Horodatage.ToString('dd/MM/yyyy HH:mm:ss')}}, Niveau, Message))

    $css = @'
:root { color-scheme: light dark; --bg:#f5f6f8; --card:#ffffff; --fg:#1c1e21; --muted:#6b7280;
        --border:#e2e5ea; --accent:#00a651; --ok:#0f8a3c; --warn:#b26a00; --bad:#c02626; --head:#1f2937; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#14161a; --card:#1c1f24; --fg:#e6e8eb; --muted:#9aa1ab; --border:#2c313a;
          --ok:#4ade80; --warn:#fbbf24; --bad:#f87171; --head:#0f1115; }
}
* { box-sizing:border-box; }
body { margin:0; padding:24px; background:var(--bg); color:var(--fg);
       font-family:"Segoe UI",system-ui,-apple-system,sans-serif; font-size:14px; line-height:1.5; }
header { background:var(--card); border:1px solid var(--border); border-left:5px solid var(--accent);
         border-radius:8px; padding:20px 24px; margin-bottom:20px; }
header h1 { margin:0 0 6px; font-size:22px; }
header .meta { color:var(--muted); font-size:13px; }
.tiles { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px; margin-bottom:20px; }
.tile { background:var(--card); border:1px solid var(--border); border-radius:8px; padding:14px 16px; }
.tile .value { font-size:26px; font-weight:600; }
.tile .label { color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.04em; }
.tile.status .value.ok { color:var(--ok); } .tile.status .value.warn { color:var(--warn); }
.tile.status .value.bad { color:var(--bad); }
.panel { background:var(--card); border:1px solid var(--border); border-radius:8px; padding:18px 20px; margin-bottom:20px; }
.panel h2 { margin:0 0 14px; font-size:17px; border-bottom:1px solid var(--border); padding-bottom:8px; }
.panel h3 { margin:0 0 10px; font-size:15px; }
.table-wrap { overflow-x:auto; }
table { border-collapse:collapse; width:100%; font-size:12.5px; }
th,td { padding:7px 10px; text-align:left; border-bottom:1px solid var(--border); vertical-align:top;
        white-space:nowrap; }
thead th { background:var(--head); color:#fff; position:sticky; top:0; font-weight:600; }
tbody tr:hover { background:rgba(127,127,127,.08); }
table.kv th { width:280px; background:transparent; color:var(--fg); position:static; }
td.ok { color:var(--ok); font-weight:600; } td.warn { color:var(--warn); font-weight:600; }
td.bad { color:var(--bad); font-weight:600; }
ul.alerts { margin:0; padding-left:20px; } ul.alerts li { margin-bottom:4px; }
ul.alerts li.bad { color:var(--bad); } ul.alerts li.warn { color:var(--warn); }
.empty { color:var(--muted); font-style:italic; }
footer { color:var(--muted); font-size:12px; text-align:center; margin-top:24px; }
@media print { body { background:#fff; padding:0; } .panel,header,.tile { break-inside:avoid; } }
'@

    $generated = $script:StartTime.ToString('dd/MM/yyyy HH:mm:ss')
    $duration  = [math]::Round(((Get-Date) - $script:StartTime).TotalSeconds, 1)

    $html = New-Object System.Text.StringBuilder
    [void]$html.AppendLine('<!DOCTYPE html><html lang="fr"><head><meta charset="UTF-8">')
    [void]$html.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$html.AppendLine("<title>Audit Veeam B&amp;R - $(ConvertTo-HtmlSafe $Audit.ServerName)</title>")
    [void]$html.AppendLine("<style>$css</style></head><body>")

    [void]$html.AppendLine('<header>')
    [void]$html.AppendLine('<h1>Audit Veeam Backup &amp; Replication</h1>')
    [void]$html.AppendLine("<div class=`"meta`">Serveur : <strong>$(ConvertTo-HtmlSafe $Audit.ServerName)</strong> &middot; Version : <strong>$(ConvertTo-HtmlSafe $Audit.VersionInfo.Version)</strong> (build $(ConvertTo-HtmlSafe $Audit.VersionInfo.Build)) &middot; Généré le $generated &middot; Durée : $duration s</div>")
    [void]$html.AppendLine('</header>')

    [void]$html.AppendLine('<div class="tiles">')
    [void]$html.AppendLine("<div class=`"tile status`"><div class=`"value $statusClass`">$(ConvertTo-HtmlSafe $summary.Statut)</div><div class=`"label`">Statut général</div></div>")
    [void]$html.AppendLine("<div class=`"tile`"><div class=`"value`">$($summary.NbJobs)</div><div class=`"label`">Jobs ($($summary.NbJobsActifs) actifs)</div></div>")
    [void]$html.AppendLine("<div class=`"tile`"><div class=`"value`">$($summary.NbJobsEchec)</div><div class=`"label`">Jobs en échec</div></div>")
    [void]$html.AppendLine("<div class=`"tile`"><div class=`"value`">$($summary.NbRepositories)</div><div class=`"label`">Repositories</div></div>")
    [void]$html.AppendLine("<div class=`"tile`"><div class=`"value`">$($summary.NbSobr)</div><div class=`"label`">SOBR</div></div>")
    [void]$html.AppendLine("<div class=`"tile`"><div class=`"value`">$($summary.NbProxies)</div><div class=`"label`">Proxies</div></div>")
    [void]$html.AppendLine("<div class=`"tile`"><div class=`"value`">$($summary.NbServeursManages)</div><div class=`"label`">Serveurs gérés</div></div>")
    [void]$html.AppendLine("<div class=`"tile`"><div class=`"value`">$($summary.NbJobsBande)</div><div class=`"label`">Jobs bande</div></div>")
    [void]$html.AppendLine("<div class=`"tile`"><div class=`"value`">$($summary.NbBandes)</div><div class=`"label`">Bandes</div></div>")
    $sureClass = if ($summary.SureBackupConfig -eq 'Oui') { 'ok' } else { 'warn' }
    [void]$html.AppendLine("<div class=`"tile status`"><div class=`"value $sureClass`">$($summary.SureBackupConfig)</div><div class=`"label`">SureBackup configuré</div></div>")
    [void]$html.AppendLine("<div class=`"tile`"><div class=`"value`">$($summary.NbBaiesStockage)</div><div class=`"label`">Baies / NAS</div></div>")
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine($alertsHtml)

    [void]$html.AppendLine('<div class="panel"><h2>1. Infrastructure - Serveur(s) Veeam Backup &amp; Replication</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.BackupServers))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>2. Infrastructure - Licence</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlKeyValue -Object $Audit.License))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>3. Infrastructure - Base de données de configuration</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlKeyValue -Object $Audit.Database))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>4. Infrastructure - Proxies</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.Proxies))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>5. Infrastructure - Serveurs de management</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.ManagedServers))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>6. Infrastructure - Services Veeam</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.Services))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>7. Repositories</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.Repositories -ExcludeColumns @('TauxNumerique')))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>8. Scale-Out Backup Repositories</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.ScaleOutRepositories))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>9. Storage infrastructure (baies intégrées et sources NAS)</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.StorageInfrastructure))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>10. Jobs de sauvegarde (disque)</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.Jobs -ExcludeColumns @('Id', 'RepositoryId')))
    [void]$html.AppendLine('</div>')

    # --- Bandes
    [void]$html.AppendLine('<div class="panel"><h2>11. Jobs de sauvegarde sur bande</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.TapeJobs))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>12. Media pools</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.TapeMediaPools))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>13. État des bandes</h2>')
    [void]$html.AppendLine('<h3>Synthèse par media pool</h3>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.TapeMedia.Synthese))
    [void]$html.AppendLine('<h3>Détail des bandes</h3>')
    if ($Audit.TapeMedia.Tronque) {
        [void]$html.AppendLine("<p class=`"empty`">$($Audit.TapeMedia.Total) bandes recensées : seules les $(@($Audit.TapeMedia.Detail).Count) premières sont détaillées (paramètre -TapeMediaLimit).</p>")
    }
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.TapeMedia.Detail))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>14. Infrastructure bande (serveurs, bibliothèques, lecteurs)</h2>')
    [void]$html.AppendLine('<h3>Serveurs de bande</h3>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.TapeInfrastructure.Serveurs))
    [void]$html.AppendLine('<h3>Bibliothèques</h3>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.TapeInfrastructure.Bibliotheques))
    [void]$html.AppendLine('<h3>Lecteurs de bande</h3>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.TapeInfrastructure.Lecteurs))
    [void]$html.AppendLine('</div>')

    # --- SureBackup
    [void]$html.AppendLine('<div class="panel"><h2>15. SureBackup (vérification de restaurabilité)</h2>')
    if (-not $Audit.SureBackup.Configure) {
        [void]$html.AppendLine('<p class="empty">SureBackup n''est pas configuré : aucun virtual lab, application group ni job de vérification n''a été trouvé.</p>')
    }
    else {
        [void]$html.AppendLine('<h3>Jobs SureBackup</h3>')
        [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.SureBackup.Jobs))
        [void]$html.AppendLine('<h3>Virtual labs</h3>')
        [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.SureBackup.VirtualLabs))
        [void]$html.AppendLine('<h3>Application groups</h3>')
        [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.SureBackup.ApplicationGroups))
    }
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>16. Journal de collecte (avertissements et erreurs)</h2>')
    [void]$html.AppendLine($logHtml)
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine("<footer>Rapport généré par Invoke-VeeamAudit.ps1 &middot; $generated</footer>")
    [void]$html.AppendLine('</body></html>')

    $html.ToString() | Out-File -FilePath $Path -Encoding UTF8 -Force
    return $Path
}

#endregion


#region ---------------------------------------------------------------- Exports

function Export-AuditCsv {
    <#  Un fichier CSV par section, separateur ';' pour Excel FR. #>
    [CmdletBinding()]
    param($Audit, [string]$Folder, [string]$Stamp)

    $files = New-Object System.Collections.Generic.List[string]

    $sections = [ordered]@{
        'Jobs'                  = @($Audit.Jobs | Select-Object -Property * -ExcludeProperty Id, RepositoryId)
        'Repositories'          = @($Audit.Repositories | Select-Object -Property * -ExcludeProperty TauxNumerique)
        'SOBR'                  = @($Audit.ScaleOutRepositories)
        'Proxies'               = @($Audit.Proxies)
        'ServeursVBR'           = @($Audit.BackupServers)
        'ServeursManages'       = @($Audit.ManagedServers)
        'Services'              = @($Audit.Services)
        'Licence'               = @($Audit.License)
        'BaseDeDonnees'         = @($Audit.Database)
        'StorageInfrastructure' = @($Audit.StorageInfrastructure)
        'JobsBande'             = @($Audit.TapeJobs)
        'MediaPools'            = @($Audit.TapeMediaPools)
        'BandesSynthese'        = @($Audit.TapeMedia.Synthese)
        'BandesDetail'          = @($Audit.TapeMedia.Detail)
        'ServeursBande'         = @($Audit.TapeInfrastructure.Serveurs)
        'Bibliotheques'         = @($Audit.TapeInfrastructure.Bibliotheques)
        'LecteursBande'         = @($Audit.TapeInfrastructure.Lecteurs)
        'SureBackupJobs'        = @($Audit.SureBackup.Jobs)
        'SureBackupVirtualLabs' = @($Audit.SureBackup.VirtualLabs)
        'SureBackupAppGroups'   = @($Audit.SureBackup.ApplicationGroups)
        'JournalCollecte'       = @($script:AuditLog)
    }

    foreach ($name in $sections.Keys) {
        $data = $sections[$name]
        if ($data.Count -eq 0) { continue }
        $path = Join-Path -Path $Folder -ChildPath ("VeeamAudit_{0}_{1}.csv" -f $name, $Stamp)
        try {
            $data | Export-Csv -Path $path -NoTypeInformation -Delimiter ';' -Encoding UTF8 -Force
            $files.Add($path) | Out-Null
        }
        catch {
            Write-AuditLog "Export CSV '$name' impossible : $($_.Exception.Message)" -Level WARN
        }
    }

    return $files
}

function Export-AuditJson {
    [CmdletBinding()]
    param($Audit, [string]$Folder, [string]$Stamp)

    $path = Join-Path -Path $Folder -ChildPath ("VeeamAudit_{0}.json" -f $Stamp)
    try {
        $Audit | ConvertTo-Json -Depth 6 -Compress:$false |
            Out-File -FilePath $path -Encoding UTF8 -Force
        return $path
    }
    catch {
        Write-AuditLog "Export JSON impossible : $($_.Exception.Message)" -Level WARN
        return $null
    }
}

#endregion

#region ---------------------------------------------------------------- Programme principal

$exitCode = 0

try {
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host '   AUDIT VEEAM BACKUP & REPLICATION (compatible v12 / v13)' -ForegroundColor Cyan
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host ''

    # 1. Dossier de sortie
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        Write-AuditLog "Dossier de sortie créé : $OutputPath" -Level INFO
    }
    $stamp = $script:StartTime.ToString('yyyyMMdd_HHmmss')

    # 2. Connexion
    $script:Connected = Connect-VeeamServer -ServerName $Server -ServerPort $Port -ServerCredential $Credential

    # 3. Version (conditionne l'interpretation de certaines proprietes)
    $versionInfo = Get-VeeamVersionInfo -ServerName $Server
    Write-AuditLog "Veeam B&R version $($versionInfo.Version) - build $($versionInfo.Build)" -Level OK
    if ($versionInfo.VersionMajeur -ne $script:NA -and $versionInfo.VersionMajeur -lt 12) {
        Write-AuditLog "Version antérieure à la v12 détectée : certaines sections peuvent être incomplètes." -Level WARN
    }

    # 4. Index des repositories (resolution des cibles de jobs par Id)
    $repositoryIndex = @{}
    foreach ($repo in @(Invoke-VBRCommand -Name 'Get-VBRBackupRepository' -Quiet)) {
        $id = "$(Get-Prop $repo @('Id', 'Info.Id'))"
        if ($id) { $repositoryIndex[$id] = $repo }
    }
    foreach ($repo in @(Invoke-VBRCommand -Name 'Get-VBRBackupRepository' -Parameters @{ ScaleOut = $true } -Quiet)) {
        $id = "$(Get-Prop $repo @('Id'))"
        if ($id) { $repositoryIndex[$id] = $repo }
    }
    foreach ($repo in @(Invoke-VBRCommand -Name 'Get-VBRObjectStorageRepository' -Quiet)) {
        $id = "$(Get-Prop $repo @('Id'))"
        if ($id) { $repositoryIndex[$id] = $repo }
    }

    # 5. Collectes
    $jobsAudit    = Get-VeeamJobAudit -RepositoryIndex $repositoryIndex
    $reposAudit   = Get-VeeamRepositoryAudit -Jobs $jobsAudit
    $sobrAudit    = Get-VeeamSobrAudit
    $licenseAudit = Get-VeeamLicenseAudit
    $proxyAudit   = Get-VeeamProxyAudit
    $serverAudit  = Get-VeeamManagedServerAudit
    $dbAudit      = Get-VeeamDatabaseAudit -ServerName $Server
    $svcAudit     = Get-VeeamServiceAudit -ServerName $Server
    $vbrAudit     = Get-VeeamBackupServerAudit -ServerName $Server -VersionInfo $versionInfo -License $licenseAudit
    $storageAudit = Get-VeeamStorageInfrastructureAudit

    # Bandes : index partage entre les quatre collectes
    $tapeIndex      = Get-TapeIndex
    $tapeJobsAudit  = Get-VeeamTapeJobAudit -TapeIndex $tapeIndex
    $tapePoolsAudit = Get-VeeamTapeMediaPoolAudit -TapeIndex $tapeIndex
    $tapeMediaAudit = Get-VeeamTapeMediumAudit -TapeIndex $tapeIndex -Limit $TapeMediaLimit
    $tapeInfraAudit = Get-VeeamTapeInfrastructureAudit -TapeIndex $tapeIndex

    $sureBackupAudit = Get-VeeamSureBackupAudit

    # 6. Assemblage
    $audit = [pscustomobject][ordered]@{
        ServerName           = $Server
        GeneratedAt          = $script:StartTime
        VersionInfo          = $versionInfo
        BackupServers        = $vbrAudit
        License              = $licenseAudit
        Database             = $dbAudit
        Proxies              = $proxyAudit
        ManagedServers       = $serverAudit
        Services             = $svcAudit
        StorageInfrastructure= $storageAudit
        Repositories         = $reposAudit
        ScaleOutRepositories = $sobrAudit
        Jobs                 = $jobsAudit
        TapeJobs             = $tapeJobsAudit
        TapeMediaPools       = $tapePoolsAudit
        TapeMedia            = $tapeMediaAudit
        TapeInfrastructure   = $tapeInfraAudit
        SureBackup           = $sureBackupAudit
        Summary              = $null
        Log                  = $script:AuditLog
    }
    $audit.Summary = Get-VeeamGlobalStatus -Audit $audit

    # 7. Exports
    Write-AuditLog "Génération des rapports..." -Level STEP
    $generatedFiles = New-Object System.Collections.Generic.List[string]

    if ($Format -contains 'HTML') {
        $htmlPath = Join-Path -Path $OutputPath -ChildPath ("VeeamAudit_{0}.html" -f $stamp)
        New-VeeamHtmlReport -Audit $audit -Path $htmlPath | Out-Null
        $generatedFiles.Add($htmlPath) | Out-Null
    }
    if ($Format -contains 'CSV') {
        foreach ($file in (Export-AuditCsv -Audit $audit -Folder $OutputPath -Stamp $stamp)) {
            $generatedFiles.Add($file) | Out-Null
        }
    }
    if ($Format -contains 'JSON') {
        $jsonPath = Export-AuditJson -Audit $audit -Folder $OutputPath -Stamp $stamp
        if ($jsonPath) { $generatedFiles.Add($jsonPath) | Out-Null }
    }

    # 8. Synthese console
    Write-Host ''
    Write-Host '  ------------------------- SYNTHÈSE -------------------------' -ForegroundColor Cyan
    $statusColor = switch ($audit.Summary.Statut) {
        'CONFORME'  { 'Green' }
        'ATTENTION' { 'Yellow' }
        default     { 'Red' }
    }
    Write-Host ('   Statut général      : {0}' -f $audit.Summary.Statut) -ForegroundColor $statusColor
    Write-Host ('   Version Veeam       : {0} (build {1})' -f $versionInfo.Version, $versionInfo.Build)
    Write-Host ('   Jobs                : {0} dont {1} actif(s), {2} en échec, {3} en avertissement' -f `
                $audit.Summary.NbJobs, $audit.Summary.NbJobsActifs, $audit.Summary.NbJobsEchec, $audit.Summary.NbJobsWarning)
    Write-Host ('   Repositories        : {0} (+ {1} SOBR)' -f $audit.Summary.NbRepositories, $audit.Summary.NbSobr)
    Write-Host ('   Proxies             : {0}' -f $audit.Summary.NbProxies)
    Write-Host ('   Serveurs gérés      : {0}' -f $audit.Summary.NbServeursManages)
    Write-Host ('   Bande               : {0} job(s), {1} bande(s), {2} lecteur(s)' -f `
                $audit.Summary.NbJobsBande, $audit.Summary.NbBandes, $audit.Summary.NbLecteursBande)
    Write-Host ('   SureBackup          : configuré = {0} ({1} job(s) de vérification)' -f `
                $audit.Summary.SureBackupConfig, $audit.Summary.NbJobsSureBackup)
    Write-Host ('   Storage infra.      : {0} baie(s) / source(s) NAS' -f $audit.Summary.NbBaiesStockage)
    Write-Host ('   Licence             : {0} - expiration {1}' -f $licenseAudit.Statut, $licenseAudit.'Expiration licence')

    if ($audit.Summary.Alertes.Count -gt 0) {
        Write-Host ''
        Write-Host '   Alertes :' -ForegroundColor Red
        foreach ($alert in $audit.Summary.Alertes) { Write-Host "     - $alert" -ForegroundColor Red }
    }
    if ($audit.Summary.Avertissements.Count -gt 0) {
        Write-Host ''
        Write-Host '   Avertissements :' -ForegroundColor Yellow
        foreach ($warning in $audit.Summary.Avertissements) { Write-Host "     - $warning" -ForegroundColor Yellow }
    }

    Write-Host ''
    Write-Host '   Fichiers générés :' -ForegroundColor Cyan
    foreach ($file in $generatedFiles) { Write-Host "     - $file" }
    Write-Host '  ------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host ''

    if ($audit.Summary.Statut -eq 'CRITIQUE') { $exitCode = 2 }
    elseif ($audit.Summary.Statut -eq 'ATTENTION') { $exitCode = 1 }

    if ($PassThru) { $audit }
}
catch {
    Write-AuditLog "Échec de l'audit : $($_.Exception.Message)" -Level ERROR
    Write-Host ''
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    $exitCode = 3
}
finally {
    if ($script:Connected -and -not $KeepConnection) {
        Invoke-VBRCommand -Name 'Disconnect-VBRServer' -Quiet | Out-Null
        Write-AuditLog "Session VBR fermée." -Level INFO
    }
}

exit $exitCode

#endregion
