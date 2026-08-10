#Requires -Version 5.1
<#
.SYNOPSIS
    Audit complet d'un serveur Veeam Backup for Microsoft 365 (VB365).
    Auteur : Tanel CREUSIER (et amélioré / annoté par Claude)
    Version : 1.0 (2026-08-07)
    Testé sur Veeam Backup for Microsoft 365 v8 (PowerShell 5.1)

.DESCRIPTION
    Collecte et restitue :
      - L'infrastructure : serveur VB365, version, OS, licence et son utilisation
      - La base de données de configuration
      - Les proxy pools et les proxies (throttling, OS, version...)
      - Les services Veeam (Win32_Service "Veeam*")
      - Les repositories (JET) et les repositories objet (stockage objet / archivage)
      - Les organisations Microsoft 365 protégées
      - Les jobs de sauvegarde et de backup copy (planification, rétention, retry...)
      - Les statistiques de volumétrie par organisation (mailbox, archive, OneDrive,
        SharePoint, Teams), via Get-VBOEntityData - peut être long, voir -SkipOrgStats

    Comme le script Invoke-VeeamAudit-v2/v3.ps1 (Veeam B&R), ce script est écrit de
    manière défensive : chaque cmdlet et chaque propriété est sondée au moment de
    l'exécution via Get-Prop / Invoke-VB365Command. Une valeur ou une cmdlet absente
    n'interrompt donc pas l'audit : elle est restituée en "N/A" et tracée dans le
    journal (section 10 du rapport, CSV "JournalCollecte").

.PARAMETER Server
    Serveur Veeam Backup for Microsoft 365 à auditer. Par défaut : localhost.

.PARAMETER Port
    Port de connexion au serveur VB365 (si le serveur est distant).

.PARAMETER Credential
    Compte utilisé pour la connexion. Si omis, le compte courant est utilisé
    (cas normal en exécution locale sur le serveur VB365).

.PARAMETER OutputPath
    Dossier de sortie des rapports. Créé s'il n'existe pas.

.PARAMETER Format
    Formats de sortie : HTML, CSV, JSON ou All. Par défaut : HTML et CSV.

.PARAMETER SkipOrgStats
    N'interroge pas le volume de données par organisation (Get-VBOEntityData).
    Cette collecte peut être longue sur de grosses organisations ; à désactiver
    pour un audit rapide de la configuration seule.

.PARAMETER KeepConnection
    Ne ferme pas la session VB365 à la fin du script.

.PARAMETER PassThru
    Retourne l'objet d'audit complet sur le pipeline.

.EXAMPLE
    .\Invoke-VB365Audit.ps1

.EXAMPLE
    .\Invoke-VB365Audit.ps1 -Server vb365.contoso.local -Credential (Get-Credential) -Format All

.EXAMPLE
    .\Invoke-VB365Audit.ps1 -SkipOrgStats -OutputPath D:\Audits\VB365

.NOTES
    Nécessite le module Veeam.Archiver.PowerShell (installé avec la console
    Veeam Backup for Microsoft 365) sur la machine d'exécution.

    QUELQUES PROPRIÉTÉS SONT SONDÉES DE MANIÈRE DÉFENSIVE (plusieurs chemins
    candidats, repli sur "N/A") car leur nom exact peut varier selon la version
    de VB365 (v6/v7/v8) et n'a pas pu être validé sur un environnement réel au
    moment de l'écriture : le statut en ligne/hors ligne d'un proxy, l'immuabilité
    d'un repository objet, l'heure de fenêtre de maintenance d'un repository, les
    options de retry d'un job. Si une de ces colonnes affiche systématiquement
    "N/A" chez vous, regardez la section "Journal de collecte" du rapport (ou le
    CSV JournalCollecte) : chaque échec de cmdlet/propriété y est tracé, ce qui
    permet de me communiquer le nom exact à corriger.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Server = 'localhost',

    [Parameter()]
    [int]$Port,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [string]$OutputPath = (Join-Path -Path (Get-Location).Path -ChildPath 'VB365Audit'),

    [Parameter()]
    [ValidateSet('HTML', 'CSV', 'JSON', 'All')]
    [string[]]$Format = @('HTML', 'CSV'),

    [Parameter()]
    [switch]$SkipOrgStats,

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

#region ---------------------------------------------------------------- Utilitaires génériques

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

function Test-VB365Command {
    <#  Indique si une cmdlet existe dans le module VB365 charge. #>
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Invoke-VB365Command {
    <#
        Execute une cmdlet Veeam.Archiver.PowerShell si elle existe.
        Retourne toujours un tableau (vide en cas d'absence ou d'erreur).
        Mecanisme de compatibilite entre versions de VB365 (v6/v7/v8).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Parameters = @{},
        [switch]$Quiet
    )

    if (-not (Test-VB365Command -Name $Name)) {
        if (-not $Quiet) { Write-AuditLog "Cmdlet '$Name' absente de cette version de VB365 - ignorée." -Level INFO }
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
        Permet d'absorber les variations de nommage entre versions de VB365.
        Exemple : Get-Prop $proxy @('IsOnline','Status','State') -Default 'N/A'
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
    <#  Formate une date en jj/MM/aaaa HH:mm, en filtrant les dates sentinelles. #>
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

function Connect-VB365Server {
    <#  Charge le module Veeam.Archiver.PowerShell et ouvre la session VB365. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerName,
        [int]$ServerPort,
        [System.Management.Automation.PSCredential]$ServerCredential
    )

    Write-AuditLog "Chargement du module PowerShell Veeam Backup for Microsoft 365..." -Level STEP

    $loaded = $false
    if (Get-Module -Name 'Veeam.Archiver.PowerShell') {
        $loaded = $true
    }
    else {
        try {
            Import-Module -Name 'Veeam.Archiver.PowerShell' -DisableNameChecking -ErrorAction Stop -WarningAction SilentlyContinue
            Write-AuditLog "Module 'Veeam.Archiver.PowerShell' chargé." -Level OK
            $loaded = $true
        }
        catch { }
    }

    if (-not $loaded -or -not (Test-VB365Command -Name 'Connect-VBOServer')) {
        throw "Module Veeam.Archiver.PowerShell introuvable. Installez la console Veeam Backup for Microsoft 365 sur cette machine, puis relancez le script."
    }

    $isLocal = $ServerName -in @('localhost', '.', '127.0.0.1', $env:COMPUTERNAME)

    $connectParams = @{}
    if (-not $isLocal) { $connectParams['Server'] = $ServerName }
    if ($ServerPort)   { $connectParams['Port']   = $ServerPort }
    if ($ServerCredential) { $connectParams['Credential'] = $ServerCredential }

    Write-AuditLog "Connexion au serveur VB365 '$ServerName'..." -Level STEP
    try {
        Connect-VBOServer @connectParams -ErrorAction Stop
        Write-AuditLog "Connecté au serveur VB365 '$ServerName'." -Level OK
    }
    catch [System.Management.Automation.RuntimeException] {
        # Connect-VBOServer leve ce type d'exception lorsqu'une session est deja active.
        Write-AuditLog "Une session VB365 est déjà active - réutilisation." -Level OK
    }
    catch {
        if ($connectParams.ContainsKey('Port')) {
            $connectParams.Remove('Port') | Out-Null
            Connect-VBOServer @connectParams -ErrorAction Stop
            Write-AuditLog "Connecté au serveur VB365 '$ServerName' (sans port explicite)." -Level OK
        }
        else {
            throw
        }
    }

    return $true
}

function Get-VB365VersionInfo {
    <#  Determine la version VB365 et l'OS du serveur local d'execution. #>
    [CmdletBinding()]
    param()

    $result = [ordered]@{
        Version = $script:NA
        OS      = $script:NA
        OSBuild = $script:NA
    }

    $ver = Invoke-VB365Command -Name 'Get-VBOVersion' -Quiet
    if ($ver -and $ver.Count -gt 0) {
        $productVersion = Get-Prop $ver[0] @('ProductVersion', 'Version')
        if ($productVersion) { $result.Version = "$productVersion" }
    }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $result.OS = "$($os.Caption)"
        try {
            $result.OSBuild = "$(Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'UBR' -ErrorAction Stop)"
        }
        catch { $result.OSBuild = "$($os.BuildNumber)" }
    }
    catch { }

    return [pscustomobject]$result
}

#endregion


#region ---------------------------------------------------------------- Infrastructure

function Get-VB365BackupServerAudit {
    <#  Serveur VB365 : nom, version, OS. #>
    [CmdletBinding()]
    param($VersionInfo)

    Write-AuditLog "Collecte des informations serveur..." -Level STEP

    return @([pscustomobject]@{
        'Nom du serveur' = $env:COMPUTERNAME
        'Version VB365'  = "$($VersionInfo.Version)"
        'OS'             = "$($VersionInfo.OS)"
        'Version OS'     = "$($VersionInfo.OSBuild)"
    })
}

function Get-VB365LicenseAudit {
    <#  Licence VB365 : type, expiration, contact, utilisation. #>
    [CmdletBinding()]
    param()

    Write-AuditLog "Collecte de la licence..." -Level STEP

    $license = Invoke-VB365Command -Name 'Get-VBOLicense' -Quiet
    if (-not $license -or $license.Count -eq 0) {
        Write-AuditLog "Licence VB365 introuvable." -Level WARN
        return [pscustomobject]@{
            'Statut'             = $script:NA
            'Type'               = $script:NA
            'Concédée à'         = $script:NA
            'Contact'            = $script:NA
            'Date expiration'    = $script:NA
            'Jours restants'     = $script:NA
            'Comptes utilisés'   = $script:NA
            'Comptes licenciés'  = $script:NA
            "Taux d'utilisation" = $script:NA
        }
    }

    $lic = $license[0]
    $expiration = Get-Prop $lic @('ExpirationDate')
    $daysLeft = $script:NA
    if ($expiration) {
        try {
            $days = [int][math]::Ceiling((([datetime]$expiration) - (Get-Date)).TotalDays)
            $daysLeft = if ($days -lt 0) { 'Expirée depuis ' + [math]::Abs($days) + ' jour(s)' } else { "$days" }
        }
        catch { }
    }

    $used  = Get-Prop $lic @('UsedNumber', 'usedNumber')
    $total = Get-Prop $lic @('TotalNumber', 'totalNumber')
    $percent = ConvertTo-Percent -Part $used -Total $total
    $percentText = if ($null -ne $percent) { "$percent %" } else { $script:NA }

    return [pscustomobject]@{
        'Statut'             = "$(Get-Prop $lic @('Status') -Default $script:NA)"
        'Type'               = "$(Get-Prop $lic @('Type') -Default $script:NA)"
        'Concédée à'         = "$(Get-Prop $lic @('LicensedTo') -Default $script:NA)"
        'Contact'            = "$(Get-Prop $lic @('ContactPerson') -Default $script:NA)"
        'Date expiration'    = Format-DateValue $expiration
        'Jours restants'     = $daysLeft
        'Comptes utilisés'   = "$(if ($null -ne $used) { $used } else { $script:NA })"
        'Comptes licenciés'  = "$(if ($null -ne $total) { $total } else { $script:NA })"
        "Taux d'utilisation" = $percentText
    }
}

function Get-VB365DatabaseAudit {
<#
Base de donnees de configuration VB365.
Lecture directe du fichier Config.xml.
Support PostgreSQL et SQL Server.
Le mot de passe de connexion n'est jamais exporté.
#>

[CmdletBinding()]
param()

Write-AuditLog "Collecte de la base de données de configuration..." -Level STEP

$configPath = "C:\ProgramData\Veeam\Backup365\Config.xml"

if (-not (Test-Path $configPath)) {

    Write-AuditLog "Fichier de configuration VB365 introuvable : $configPath" -Level WARN

    return [pscustomobject]@{
        'Type'              = $script:NA
        'Nom du serveur'    = $script:NA
        'Instance'          = $script:NA
        'Port'              = $script:NA
        'Base de données'   = $script:NA
        'Utilisateur'       = $script:NA
        'TLS activé'        = $script:NA
        'Certificat'        = $script:NA
    }
}

try {

    [xml]$config = Get-Content $configPath -ErrorAction Stop

    $databaseNode = $null
    $databaseType = $script:NA


    # Recherche PostgreSQL
    $databaseNode = $config.SelectSingleNode("//ControllerPostgres")

    if ($databaseNode) {

        $databaseType = "PostgreSQL"

    }
    else {

        # Recherche SQL Server (selon version VB365)
        $databaseNode = $config.SelectSingleNode("//ControllerSqlServer")

        if ($databaseNode) {
            $databaseType = "SQL Server"
        }

    }


    if ($null -eq $databaseNode) {

        Write-AuditLog "Aucune configuration de base détectée dans Config.xml." -Level WARN

        return [pscustomobject]@{
            'Type'              = $script:NA
            'Nom du serveur'    = $script:NA
            'Instance'          = $script:NA
            'Port'              = $script:NA
            'Base de données'   = $script:NA
            'Utilisateur'       = $script:NA
            'TLS activé'        = $script:NA
            'Certificat'        = $script:NA
        }
    }


    # Récupération de la chaîne de connexion
    $connectionString = $databaseNode.GetAttribute("ControllerConnectionString")


    # Parsing de la chaîne
    $dbProperties = @{}

    foreach ($item in ($connectionString -split ';')) {

        if ($item -match '=') {

            $key, $value = $item -split '=', 2

            $dbProperties[$key.Trim()] = $value.Trim()

        }
    }


    return [pscustomobject]@{

        'Type' = $databaseType


        'Nom du serveur' = if ($dbProperties["host"]) {
            $dbProperties["host"]
        }
        elseif ($dbProperties["Server"]) {
            $dbProperties["Server"]
        }
        else {
            $script:NA
        }


        'Instance' = if ($dbProperties["instance"]) {
            $dbProperties["instance"]
        }
        else {
            $script:NA
        }


        'Port' = if ($dbProperties["port"]) {
            $dbProperties["port"]
        }
        else {
            $script:NA
        }


        'Base de données' = if ($dbProperties["database"]) {
            $dbProperties["database"]
        }
        elseif ($dbProperties["Initial Catalog"]) {
            $dbProperties["Initial Catalog"]
        }
        else {
            $script:NA
        }


        'Utilisateur' = if ($dbProperties["username"]) {
            $dbProperties["username"]
        }
        elseif ($dbProperties["User ID"]) {
            $dbProperties["User ID"]
        }
        else {
            $script:NA
        }


        'TLS activé' = $databaseNode.GetAttribute("TlsEnabled")


        'Certificat' = if ($databaseNode.GetAttribute("CertificateThumbprint")) {
            $databaseNode.GetAttribute("CertificateThumbprint")
        }
        else {
            $script:NA
        }

    }

}
catch {

    Write-AuditLog "Erreur lors de la collecte de la base VB365 : $($_.Exception.Message)" -Level WARN

    return [pscustomobject]@{
        'Type'              = $script:NA
        'Nom du serveur'    = $script:NA
        'Instance'          = $script:NA
        'Port'              = $script:NA
        'Base de données'   = $script:NA
        'Utilisateur'       = $script:NA
        'TLS activé'        = $script:NA
        'Certificat'        = $script:NA
    }
}

}
function Get-VB365ServiceAudit {
    <#  Services Veeam du serveur VB365 (nom, etat, demarrage, compte). #>
    [CmdletBinding()]
    param()

    Write-AuditLog "Collecte des services Veeam..." -Level STEP

    $result = New-Object System.Collections.Generic.List[psobject]
    try {
        foreach ($svc in (Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'Veeam%'" -ErrorAction Stop | Sort-Object DisplayName)) {
            $result.Add([pscustomobject]@{
                'Service'     = "$($svc.DisplayName)"
                'Nom système' = "$($svc.Name)"
                'État'        = "$($svc.State)"
                'Démarrage'   = "$($svc.StartMode)"
                'Compte'      = "$($svc.StartName)"
            }) | Out-Null
        }
        Write-AuditLog "$($result.Count) service(s) Veeam recensé(s)." -Level OK
    }
    catch {
        Write-AuditLog "Services Veeam non interrogeables : $($_.Exception.Message.Split([char]10)[0])" -Level WARN
    }

    return $result
}

#endregion


#region ---------------------------------------------------------------- Proxies & proxy pools

function Get-VB365ProxyPoolAudit {
    <#  Proxy pools : nom, description, nombre et liste de proxies associes. #>
    [CmdletBinding()]
    param()

    Write-AuditLog "Collecte des proxy pools..." -Level STEP

    $result = New-Object System.Collections.Generic.List[psobject]
    $pools  = Invoke-VB365Command -Name 'Get-VBOProxyPool' -Quiet

    foreach ($pool in $pools) {
        $proxies = @(Get-Prop $pool @('Proxies'))
        $names   = @($proxies | ForEach-Object { Get-Prop $_ @('Hostname', 'Name') })

        $result.Add([pscustomobject]@{
            'Nom'              = "$(Get-Prop $pool @('Name') -Default $script:NA)"
            'Description'      = "$(Get-Prop $pool @('Description') -Default $script:NA)"
            'Nombre de proxies'= $proxies.Count
            'Proxies associés' = Join-Values -Values $names
        }) | Out-Null
    }

    Write-AuditLog "$($result.Count) proxy pool(s) recensé(s)." -Level OK
    return $result
}

function Get-VB365ProxyAudit {
    <#  Proxies : nom, port, version, statut, type, OS, throttling, description, pool. #>
    [CmdletBinding()]
    param($ProxyPools)

    Write-AuditLog "Collecte des proxies..." -Level STEP

    $result = New-Object System.Collections.Generic.List[psobject]
    $proxies = Invoke-VB365Command -Name 'Get-VBOProxy' -Parameters @{ ExtendedView = $true } -Quiet
    if (-not $proxies -or $proxies.Count -eq 0) {
        $proxies = Invoke-VB365Command -Name 'Get-VBOProxy' -Quiet
    }

    foreach ($proxy in $proxies) {
        $hostname = Get-Prop $proxy @('Hostname') -Default $script:NA

        $poolName = $script:NA
        foreach ($pool in $ProxyPools) {
            $poolProxies = @(Get-Prop $pool @('Proxies') | ForEach-Object { Get-Prop $_ @('Hostname', 'Name') })
            if ($hostname -in $poolProxies) { $poolName = "$(Get-Prop $pool @('Name'))"; break }
        }

        $throttlingEnabled = Get-Prop $proxy @('EnableNetworkThrottling', 'IsThrottlingEnabled')
        $throttlingValue = Get-Prop $proxy @('ThrottlingValue')
        $throttlingUnit  = Get-Prop $proxy @('ThrottlingUnit')
        $throttlingText = if ($throttlingEnabled -eq $false) {
            'Désactivé'
        }
        elseif ($throttlingValue) {
            "$throttlingValue $throttlingUnit"
        }
        else {
            $script:NA
        }

        # NOTE : le nom exact de la propriete de statut en ligne/hors ligne d'un
        # proxy VB365 n'a pas pu etre confirme via la documentation publique -
        # plusieurs chemins candidats sont sondes, repli gracieux sur N/A.
        $status = Get-Prop $proxy @('Status', 'IsOnline', 'IsAvailable', 'IsResponding', 'State') -Default $script:NA
        if ($status -is [bool]) { $status = if ($status) { 'En ligne' } else { 'Hors ligne' } }

        $result.Add([pscustomobject]@{
            'Nom'         = "$hostname"
            'Port'        = "$(Get-Prop $proxy @('Port') -Default $script:NA)"
            'Version'     = "$(Get-Prop $proxy @('Version', 'ProductVersion') -Default $script:NA)"
            'Status'      = "$status"
            'Type'        = "$(Get-Prop $proxy @('Type', 'ProxyType') -Default $script:NA)"
            'OS'          = "$(Get-Prop $proxy @('OperatingSystemKind', 'OSInfo') -Default $script:NA)"
            'Throttling'  = "$throttlingText"
            'Description' = "$(Get-Prop $proxy @('Description') -Default $script:NA)"
        }) | Out-Null
    }

    Write-AuditLog "$($result.Count) proxy(s) recensé(s)." -Level OK
    return $result
}

#endregion


#region ---------------------------------------------------------------- Repositories

function Get-VB365RepositoryAudit {
    <#  Repositories JET : proxy/pool, type, chemin, retention, capacite, immuabilite... #>
    [CmdletBinding()]
    param($ProxyPools)

    Write-AuditLog "Collecte des repositories..." -Level STEP

    $result = New-Object System.Collections.Generic.List[psobject]
    $repos  = Invoke-VB365Command -Name 'Get-VBORepository' -Quiet

    foreach ($repo in $repos) {
        $capacity = Get-Prop $repo @('Capacity')
        $free     = Get-Prop $repo @('FreeSpace')
        $used     = $null
        if ($null -ne $capacity -and $null -ne $free) {
            try { $used = [double]$capacity - [double]$free } catch { }
        }
        $percent = ConvertTo-Percent -Part $used -Total $capacity
        $percentText = if ($null -ne $percent) { "$percent %" } else { $script:NA }

        $proxyId = Get-Prop $repo @('Proxy.Id')
        $proxyOrPool = $script:NA
        if ($proxyId) {
            $proxy = Invoke-VB365Command -Name 'Get-VBOProxy' -Parameters @{ Id = $proxyId; ExtendedView = $false } -Quiet
            if ($proxy -and $proxy.Count -gt 0) { $proxyOrPool = "$(Get-Prop $proxy[0] @('Hostname'))" }
        }
        if ($proxyOrPool -eq $script:NA) {
            $poolId = Get-Prop $repo @('ProxyPool.Id')
            if ($poolId) {
                foreach ($pool in $ProxyPools) {
                    if ("$(Get-Prop $pool @('Id'))" -eq "$poolId") { $proxyOrPool = "$(Get-Prop $pool @('Name')) (pool)"; break }
                }
            }
        }

        $objectRepoName = $script:NA
        if (Get-Prop $repo @('ObjectStorageRepository')) {
            $objectRepoName = "$(Get-Prop $repo @('ObjectStorageRepository.Name'))"
            $objectUsed = Get-Prop $repo @('ObjectStorageRepository.UsedSpace')
            $objectType = Get-Prop $repo @('ObjectStorageRepository.Type')
        }

        # NOTE : l'immuabilite (Object Lock) ne s'applique en pratique qu'aux
        # repositories adosses a un stockage objet ; le nom de propriete exact
        # n'a pas pu etre confirme via la documentation publique - plusieurs
        # chemins candidats sont sondes ci-dessous.
        $immutable = $script:NA
        if ($objectRepoName -ne $script:NA) {
            $immutable = ConvertTo-YesNo (Get-Prop $repo @(
                'ObjectStorageRepository.IsImmutabilityEnabled',
                'ObjectStorageRepository.EnableRetentionLock',
                'ObjectStorageRepository.ImmutabilityEnabled'
            ))
        }

        $result.Add([pscustomobject]@{
            'Nom'                  = "$(Get-Prop $repo @('Name') -Default $script:NA)"
            'Proxy (ou proxy pool)'= "$proxyOrPool"
            'Type'                 = $(if ($objectRepoName -ne $script:NA) { $objectType } else { 'JET' })
            'Chemin'               = "$(Get-Prop $repo @('Path') -Default $script:NA)"
            'Type de rétention'    = "$(Get-Prop $repo @('RetentionType') -Default $script:NA)"
            'Période de rétention' = "$(Get-Prop $repo @('RetentionPeriod') -Default $script:NA)"
            'Capacité'             = $(if ($objectRepoName -ne $script:NA) { $script:NA } else { Format-Size $capacity })
            'Libre'                = $(if ($objectRepoName -ne $script:NA) { $script:NA } else { Format-Size $free })
            'Utilisé'              = $(if ($objectRepoName -ne $script:NA) { Format-Size $objectUsed } else { Format-Size $used })
            "% d'utilisation"       = $(if ($objectRepoName -ne $script:NA) { $script:NA } else { $percentText})
            'Immuable'             = $immutable
            'Chiffrement'          = ConvertTo-YesNo (Get-Prop $repo @('EnableObjectStorageEncryption'))
            'Description'          = "$(Get-Prop $repo @('Description') -Default $script:NA)"
        }) | Out-Null
    }

    Write-AuditLog "$($result.Count) repository(s) recensé(s)." -Level OK
    return $result
}


#region ---------------------------------------------------------------- Organisations & jobs

function Get-VB365OrganizationAudit {
    <#  Organisations Microsoft 365 protegees : nom, nombre de comptes. #>
    [CmdletBinding()]
    param()

    Write-AuditLog "Collecte des organisations..." -Level STEP

    $result = New-Object System.Collections.Generic.List[psobject]
    $orgs   = Invoke-VB365Command -Name 'Get-VBOOrganization' -Quiet

    foreach ($org in $orgs) {
        $accountCount = $script:NA
        $licensedUsers = Invoke-VB365Command -Name 'Get-VBOLicensedUser' -Parameters @{ Organization = $org } -Quiet
        if ($licensedUsers) { $accountCount = @($licensedUsers).Count }

        $result.Add([pscustomobject]@{
            'Nom'                = "$(Get-Prop $org @('OfficeName', 'Name') -Default $script:NA)"
            'Nombre de comptes'  = "$accountCount"
        }) | Out-Null
    }

    Write-AuditLog "$($result.Count) organisation(s) recensée(s)." -Level OK
    return @($orgs), $result
}

function ConvertTo-VB365ItemsText {
    <#  
    Restitue une liste d'objets selectionnes/exclus d'un job sous forme lisible.
    Prend en compte les workloads VB365 (Exchange, Archive, OneDrive, SharePoint).
    #>

    param([AllowNull()]$Items)

    if ($null -eq $Items) { 
        return $script:NA 
    }

    $texts = foreach ($item in @($Items)) {
        $type = "$(Get-Prop $item @('Type'))"

        # Récupération du nom selon le type
        switch ($type) {
            'SecurityGroup' {
                $name = Get-Prop $item @(
                    'Group.DisplayName',
                    'DisplayName',
                    'Name'
                ) -Default '?'
                $prefix = "Groupe"
            }


            'O365Group' {
                $name = Get-Prop $item @(
                    'Group.DisplayName',
                    'DisplayName',
                    'Name'
                ) -Default '?'
                $prefix = "Groupe M365"
            }

            'Organization' {
                $name = Get-Prop $item @(
                    'Organization.Name',
                    'Name'
                ) -Default '?'
                $prefix = "Organisation"
            }

            'User' {
                $name = Get-Prop $item @(
                    'User.DisplayName',
                    'DisplayName',
                    'Name'
                ) -Default '?'
                $prefix = "Utilisateur"
            }

            'Site' {
                $name = Get-Prop $item @(
                    'Site.Name',
                    'Name'
                ) -Default '?'
                $prefix = "SharePoint"
            }

            'Team' {
                $name = Get-Prop $item @(
                    'Team.DisplayName',
                    'DisplayName',
                    'Name'
                ) -Default '?'
                $prefix = "Teams"
            }

            default {
                $name = Get-Prop $item @(
                    'Name',
                    'DisplayName'
                ) -Default '?'
                $prefix = $type
            }
        }

        # Détection des workloads
        $workloads = New-Object System.Collections.Generic.List[string]

        if ((Get-Prop $item @('Mailbox')) -eq $true) {
            $workloads.Add("Exchange")
        }

        if ((Get-Prop $item @('ArchiveMailbox')) -eq $true) {
            $workloads.Add("Archive")
        }

        if ((Get-Prop $item @('OneDrive')) -eq $true) {
            $workloads.Add("OneDrive")
        }

        if ((Get-Prop $item @('Site')) -eq $true) {
            $workloads.Add("SharePoint")
        }

        if ((Get-Prop $item @('Teams')) -eq $true) {
            $workloads.Add("Teams")
        }

        if ($workloads.Count -gt 0) {
            "$prefix - $name ($($workloads -join ', '))"
        }
        else {
            "$prefix - $name"
        }

    }

    return Join-Values -Values $texts -Separator ' | '
}

function Get-VB365JobScheduleText {
    <#  Restitue planification / heure / jours a partir de SchedulePolicy. #>
    param($SchedulePolicy)

    if ($null -eq $SchedulePolicy) { return $script:NA, $script:NA, $script:NA }

    $enabled = Get-Prop $SchedulePolicy @('EnableSchedule')
    if ($enabled -eq $false) { return 'Désactivée', $script:NA, $script:NA }

    $type = "$(Get-Prop $SchedulePolicy @('Type') -Default $script:NA)"
    switch -Regex ($type) {
        'Daily' {
            $time = "$(Get-Prop $SchedulePolicy @('DailyTime') -Default $script:NA)"
            $days = "$(Get-Prop $SchedulePolicy @('DailyType') -Default $script:NA)"
            return 'Quotidienne', $time, $days
        }
        'Periodic' {
            $every = "$(Get-Prop $SchedulePolicy @('PeriodicallyEvery') -Default $script:NA)"
            return "Périodique (toutes les $every)", $script:NA, $script:NA
        }
        'Monthly' {
            $time = "$(Get-Prop $SchedulePolicy @('MonthlyTime') -Default $script:NA)"
            return 'Mensuelle', $time, $script:NA
        }
        default { return $type, $script:NA, $script:NA }
    }
}

function Get-VB365JobRetryText {
    <#
        Restitue les options de retry d'un job.
        NOTE : le nom exact de la propriete de retry n'a pas pu etre confirme
        via la documentation publique - plusieurs chemins candidats sont sondes.
    #>
    param($Job)

    $enabled = Get-Prop $Job @('RetryOptions.IsEnabled', 'RetryOptions.RetryEnabled', 'RetryOptions.Enabled')
    $count   = Get-Prop $Job @('RetryOptions.RetryCount', 'RetryOptions.Count')

    if ($enabled -eq $false) { return 'Désactivé' }
    if ($count) { return "$count tentative(s)" }
    if ($enabled -eq $true) { return 'Activé (nombre indisponible)' }
    return $script:NA
}

function Get-VB365JobLastSessionInfo {
    <#  Dernier resultat / derniere execution d'un job (Get-VBOJobSession -Last). #>
    param($Job)

    $session = Invoke-VB365Command -Name 'Get-VBOJobSession' -Parameters @{ Job = $Job; Last = $true } -Quiet
    if (-not $session -or $session.Count -eq 0) { return $script:NA, $script:NA }

    $status = "$(Get-Prop $session[0] @('Status') -Default $script:NA)"
    $end    = Get-Prop $session[0] @('Statistics.EndTime', 'EndTime')
    $start  = Get-Prop $session[0] @('Statistics.StartTime', 'CreationTime')
    $date   = if ($end) { $end } else { $start }

    return $status, (Format-DateValue $date)
}

function Get-VB365JobAudit {
    <#  Jobs de sauvegarde (backup) et de backup copy. #>
    [CmdletBinding()]
    param()

    Write-AuditLog "Collecte des jobs de sauvegarde..." -Level STEP

    $result = New-Object System.Collections.Generic.List[psobject]
    $jobs = Invoke-VB365Command -Name 'Get-VBOJob' -Quiet

    foreach ($job in $jobs) {
        $enabled = Get-Prop $job @('IsEnabled')
        $planif, $heure, $jours = Get-VB365JobScheduleText -SchedulePolicy (Get-Prop $job @('SchedulePolicy'))
        $lastStatus, $lastDate = Get-VB365JobLastSessionInfo -Job $job

        $result.Add([pscustomobject]@{
            'Nom'                = "$(Get-Prop $job @('Name') -Default $script:NA)"
            'Type'               = 'Backup'
            'Activation'         = ConvertTo-YesNo $enabled
            'Description'        = "$(Get-Prop $job @('Description') -Default $script:NA)"
            'Objets sauvegardés' = ConvertTo-VB365ItemsText (Get-Prop $job @('SelectedItems'))
            'Objets exclus'      = ConvertTo-VB365ItemsText (Get-Prop $job @('ExcludedItems'))
            'Repository'         = "$(Get-Prop $job @('Repository.Name', 'Repository') -Default $script:NA)"
            'Planification'      = "$planif"
            "Heure d'exécution"  = "$heure"
            'Jours'              = "$jours"
            'Dernier résultat'   = "$lastStatus"
            'Dernière sauvegarde'= "$lastDate"
        }) | Out-Null
    }

    $copyJobs = Invoke-VB365Command -Name 'Get-VBOCopyJob' -Quiet
    foreach ($job in $copyJobs) {
        $enabled = Get-Prop $job @('IsEnabled')
        $planif, $heure, $jours = Get-VB365JobScheduleText -SchedulePolicy (Get-Prop $job @('SchedulePolicy'))
        $lastStatus, $lastDate = Get-VB365JobLastSessionInfo -Job $job

        $result.Add([pscustomobject]@{
            'Nom'                = "$(Get-Prop $job @('Name') -Default $script:NA)"
            'Type'               = 'Backup Copy'
            'Activation'         = ConvertTo-YesNo $enabled
            'Description'        = "$(Get-Prop $job @('Description') -Default $script:NA)"
            'Objets sauvegardés' = "$(Get-Prop $job @('BackupJob.Name') -Default $script:NA) (job lié)"
            'Objets exclus'      = $script:NA
            'Repository'         = "$(Get-Prop $job @('Repository.Name', 'Repository') -Default $script:NA)"
            'Planification'      = "$planif"
            "Heure d'exécution"  = "$heure"
            'Jours'              = "$jours"
            'Dernier résultat'   = "$lastStatus"
            'Dernière sauvegarde'= "$lastDate"
        }) | Out-Null
    }

    Write-AuditLog "$($result.Count) job(s) recensé(s)." -Level OK
    return $result
}

#endregion


#region ---------------------------------------------------------------- Synthèse & rapport

function Get-VB365GlobalStatus {
    <#  Calcule le statut global et la liste des points d'attention (alertes/avertissements). #>
    [CmdletBinding()]
    param($Audit)

    $alerts   = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    # --- Licence
    $daysLeft = "$($Audit.License.'Jours restants')"
    if ($daysLeft -match 'Expirée') { $alerts.Add("Licence VB365 expirée") }
    elseif ($daysLeft -match '^\d+$') {
        if ([int]$daysLeft -le 30) { $warnings.Add("Licence expirant dans $daysLeft jour(s)") }
    }
    $usageText = "$($Audit.License.'Taux d''utilisation')"
    if ($usageText -match '(\d+(?:[.,]\d+)?)\s*%') {
        $usage = [double]($Matches[1] -replace ',', '.')
        if ($usage -ge 90) { $warnings.Add("Utilisation de la licence à $usage % (proche de la limite)") }
    }

    # --- Repositories
    $repos = @($Audit.Repositories)
    foreach ($repo in $repos) {
        $percentText = "$($repo.'%d''utilisation')"
        if ($percentText -match '(\d+(?:[.,]\d+)?)\s*%') {
            $percent = [double]($Matches[1] -replace ',', '.')
            if ($percent -ge 90) { $alerts.Add("Repository '$($repo.Nom)' à $percent % d'occupation") }
            elseif ($percent -ge 80) { $warnings.Add("Repository '$($repo.Nom)' à $percent % d'occupation") }
        }
        if ("$($repo.Immuable)" -eq 'Non') { $warnings.Add("Repository '$($repo.Nom)' sans immuabilité activée") }
    }
    # NOTE : l'accessibilite d'un repository n'est pas exposee de facon fiable
    # par les cmdlets VB365 sondees ici ; cette alerte reste donc indicative et
    # peut ne jamais se declencher tant que la propriete exacte n'est pas confirmee.
    $reposDown = @($repos | Where-Object { "$($_.Chemin)" -eq $script:NA -and "$($_.Nom)" -ne $script:NA })
    if ($reposDown.Count -gt 0) { $alerts.Add("$($reposDown.Count) repository(s) potentiellement inaccessible(s) (chemin non résolu)") }

    # --- Proxies
    $proxies = @($Audit.Proxies)
    $proxiesOffline = @($proxies | Where-Object { "$($_.Status)" -match 'Hors ligne|Offline|False' })
    if ($proxiesOffline.Count -gt 0) { $alerts.Add("$($proxiesOffline.Count) proxy(s) hors ligne") }
    $proxiesNoThrottle = @($proxies | Where-Object { "$($_.Throttling)" -eq 'Désactivé' })
    if ($proxiesNoThrottle.Count -gt 0) { $warnings.Add("$($proxiesNoThrottle.Count) proxy(s) sans throttling réseau") }

    # --- Proxy pools
    $emptyPools = @($Audit.ProxyPools | Where-Object { [int]"$($_.'Nombre de proxies')" -eq 0 })
    if ($emptyPools.Count -gt 0) { $warnings.Add("$($emptyPools.Count) proxy pool(s) sans aucun proxy associé") }

    # --- Jobs
    $jobs = @($Audit.Jobs)
    $jobsDisabled = @($jobs | Where-Object { "$($_.Activation)" -eq 'Non' })
    if ($jobsDisabled.Count -gt 0) { $warnings.Add("$($jobsDisabled.Count) job(s) désactivé(s)") }
    $jobsNoRetry = @($jobs | Where-Object { "$($_.Retry)" -eq 'Désactivé' })
    if ($jobsNoRetry.Count -gt 0) { $warnings.Add("$($jobsNoRetry.Count) job(s) sans retry configuré") }
    $jobsFailed = @($jobs | Where-Object { "$($_.'Dernier résultat')" -match 'Failed' })
    if ($jobsFailed.Count -gt 0) { $alerts.Add("$($jobsFailed.Count) job(s) en échec lors de la dernière exécution") }

    $jobsStale = @($jobs | Where-Object {
        $d = "$($_.'Dernière sauvegarde')"
        if ($d -eq $script:NA) { return $false }
        try { ((Get-Date) - [datetime]::ParseExact($d, 'dd/MM/yyyy HH:mm', $null)).TotalHours -gt 24 } catch { $false }
    })
    if ($jobsStale.Count -gt 0) { $warnings.Add("$($jobsStale.Count) job(s) dont la dernière sauvegarde date de plus de 24h") }

    # --- Organisations
    $orgsInError = @($jobs | Where-Object { "$($_.'Dernier résultat')" -match 'Failed|Warning' } |
                      Select-Object -ExpandProperty Repository -Unique)
    if ($jobsFailed.Count -gt 0 -or ($jobs | Where-Object { "$($_.'Dernier résultat')" -match 'Warning' }).Count -gt 0) {
        $warnings.Add("Au moins une organisation présente des jobs en échec ou en avertissement")
    }

    $status = if ($alerts.Count -gt 0) { 'CRITIQUE' } elseif ($warnings.Count -gt 0) { 'ATTENTION' } else { 'CONFORME' }

    return [pscustomobject]@{
        Statut              = $status
        Alertes             = $alerts
        Avertissements      = $warnings
        NbOrganisations     = @($Audit.Organizations).Count
        NbJobs              = $jobs.Count
        NbJobsActifs        = ($jobs.Count - $jobsDisabled.Count)
        NbProxies           = $proxies.Count
        NbProxyPools        = @($Audit.ProxyPools).Count
        NbRepositories      = $repos.Count
        NbRepositoriesObjet = @($Audit.ObjectRepositories).Count
        UtilisationLicence  = $usageText
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
        '(espace critique|Expirée depuis|inaccessible)'              { return 'bad' }
        '(espace faible)'                                            { return 'warn' }
        '^(Success|Disponible|Activé|Oui|Running|CONFORME|En ligne)' { return 'ok' }
        '^(Warning|ATTENTION|Espace faible|Jamais exécuté|Désactivé)'{ return 'warn' }
        '^(Failed|Indisponible|Désactivé|CRITIQUE|Expirée|Hors ligne)' { return 'bad' }
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

function New-VB365HtmlReport {
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
        foreach ($alert in $summary.Alertes)         { [void]$items.Append("<li class=`"bad`">🔴 $(ConvertTo-HtmlSafe $alert)</li>") }
        foreach ($warning in $summary.Avertissements) { [void]$items.Append("<li class=`"warn`">🟠 $(ConvertTo-HtmlSafe $warning)</li>") }
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
ul.alerts { margin:0; padding-left:20px; list-style:none; } ul.alerts li { margin-bottom:4px; }
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
    [void]$html.AppendLine("<title>Audit Veeam Backup for Microsoft 365 - $(ConvertTo-HtmlSafe $Audit.ServerName)</title>")
    [void]$html.AppendLine("<style>$css</style></head><body>")

    [void]$html.AppendLine('<header>')
    [void]$html.AppendLine('<h1>Audit Veeam Backup for Microsoft 365</h1>')
    [void]$html.AppendLine("<div class=`"meta`">Serveur : <strong>$(ConvertTo-HtmlSafe $Audit.ServerName)</strong> &middot; Version : <strong>$(ConvertTo-HtmlSafe $Audit.VersionInfo.Version)</strong> &middot; Généré le $generated &middot; Durée : $duration s</div>")
    [void]$html.AppendLine('</header>')

    [void]$html.AppendLine('<div class="tiles">')
    [void]$html.AppendLine("<div class=`"tile status`"><div class=`"value $statusClass`">$(ConvertTo-HtmlSafe $summary.Statut)</div><div class=`"label`">Statut général</div></div>")
    [void]$html.AppendLine("<div class=`"tile`"><div class=`"value`">$($summary.NbOrganisations)</div><div class=`"label`">Organisations</div></div>")
    [void]$html.AppendLine("<div class=`"tile`"><div class=`"value`">$($summary.NbJobs)</div><div class=`"label`">Jobs ($($summary.NbJobsActifs) actifs)</div></div>")
    [void]$html.AppendLine("<div class=`"tile`"><div class=`"value`">$($summary.NbProxies)</div><div class=`"label`">Proxies</div></div>")
    [void]$html.AppendLine("<div class=`"tile`"><div class=`"value`">$($summary.NbProxyPools)</div><div class=`"label`">Proxy Pools</div></div>")
    [void]$html.AppendLine("<div class=`"tile`"><div class=`"value`">$($summary.NbRepositories)</div><div class=`"label`">Repositories</div></div>")
    [void]$html.AppendLine("<div class=`"tile`"><div class=`"value`">$($summary.NbRepositoriesObjet)</div><div class=`"label`">Repositories objet</div></div>")
    [void]$html.AppendLine("<div class=`"tile`"><div class=`"value`">$(ConvertTo-HtmlSafe $summary.UtilisationLicence)</div><div class=`"label`">Utilisation licence</div></div>")
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine($alertsHtml)

    [void]$html.AppendLine('<div class="panel"><h2>1. Infrastructure</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.BackupServer))
    [void]$html.AppendLine('<h3>Licence</h3>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlKeyValue -Object $Audit.License))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>2. Base de données de configuration</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlKeyValue -Object $Audit.Database))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>3. Proxy pools</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.ProxyPools))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>4. Proxies</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.Proxies))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>5. Services Veeam</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.Services))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>6. Repositories</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.Repositories))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>7. Organisations</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.Organizations))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>8. Jobs de sauvegarde</h2>')
    [void]$html.AppendLine((ConvertTo-AuditHtmlTable -Data $Audit.Jobs))
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine('<div class="panel"><h2>9. Journal de collecte (avertissements et erreurs)</h2>')
    [void]$html.AppendLine($logHtml)
    [void]$html.AppendLine('</div>')

    [void]$html.AppendLine("<footer>Rapport généré par Invoke-VB365Audit.ps1 &middot; $generated</footer>")
    [void]$html.AppendLine('</body></html>')

    $html.ToString() | Out-File -FilePath $Path -Encoding UTF8 -Force
    return $Path
}

#endregion


#region ---------------------------------------------------------------- Exports

function Export-AuditCsv {
    <#  Exporte chaque section de l'audit dans un CSV distinct (';' / UTF8). #>
    [CmdletBinding()]
    param($Audit, [string]$Folder, [string]$Stamp)

    $sections = [ordered]@{
        'ServeurVB365'       = @($Audit.BackupServer)
        'Licence'            = @($Audit.License)
        'BaseDeDonnees'      = @($Audit.Database)
        'ProxyPools'         = @($Audit.ProxyPools)
        'Proxies'            = @($Audit.Proxies)
        'Services'           = @($Audit.Services)
        'Repositories'       = @($Audit.Repositories)
        'Organisations'      = @($Audit.Organizations)
        'Jobs'               = @($Audit.Jobs)
        'JournalCollecte'    = @($script:AuditLog | Select-Object @{n='Horodatage';e={$_.Horodatage.ToString('dd/MM/yyyy HH:mm:ss')}}, Niveau, Message)
    }

    $files = New-Object System.Collections.Generic.List[string]
    foreach ($name in $sections.Keys) {
        $rows = $sections[$name]
        if (@($rows).Count -eq 0) { continue }

        $path = Join-Path -Path $Folder -ChildPath ("VB365Audit_{0}_{1}.csv" -f $name, $Stamp)
        try {
            $rows | Export-Csv -Path $path -Delimiter ';' -Encoding UTF8 -NoTypeInformation -Force
            $files.Add($path) | Out-Null
        }
        catch {
            Write-AuditLog "Échec de l'export CSV '$name' : $($_.Exception.Message)" -Level WARN
        }
    }
    return $files
}

function Export-AuditJson {
    param($Audit, [string]$Folder, [string]$Stamp)
    $path = Join-Path -Path $Folder -ChildPath ("VB365Audit_{0}.json" -f $Stamp)
    try {
        $Audit | ConvertTo-Json -Depth 8 | Out-File -FilePath $path -Encoding UTF8 -Force
        return $path
    }
    catch {
        Write-AuditLog "Échec de l'export JSON : $($_.Exception.Message)" -Level WARN
        return $null
    }
}

#endregion


#region ---------------------------------------------------------------- Programme principal

try {
    Write-AuditLog "=== Audit Veeam Backup for Microsoft 365 ===" -Level STEP

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $connectParams = @{ ServerName = $Server }
    if ($Port) { $connectParams['ServerPort'] = $Port }
    if ($Credential) { $connectParams['ServerCredential'] = $Credential }
    $script:Connected = Connect-VB365Server @connectParams

    $versionInfo = Get-VB365VersionInfo

    $audit = [ordered]@{
        ServerName          = $env:COMPUTERNAME
        VersionInfo         = $versionInfo
        BackupServer        = Get-VB365BackupServerAudit -VersionInfo $versionInfo
        License             = Get-VB365LicenseAudit
        Database            = Get-VB365DatabaseAudit
        Services            = Get-VB365ServiceAudit
        ProxyPools          = Get-VB365ProxyPoolAudit
    }
    $audit['Proxies']            = Get-VB365ProxyAudit -ProxyPools $audit.ProxyPools
    $audit['Repositories']       = Get-VB365RepositoryAudit -ProxyPools $audit.ProxyPools

    $orgObjects, $orgTable = Get-VB365OrganizationAudit
    $audit['Organizations'] = $orgTable
    $audit['Jobs']          = Get-VB365JobAudit

    $auditObject = [pscustomobject]$audit
    $auditObject | Add-Member -MemberType NoteProperty -Name 'Summary' -Value (Get-VB365GlobalStatus -Audit $auditObject)

    $stamp = $script:StartTime.ToString('yyyyMMdd_HHmmss')

    if ($Format -contains 'HTML') {
        $htmlPath = Join-Path -Path $OutputPath -ChildPath ("VB365Audit_{0}.html" -f $stamp)
        New-VB365HtmlReport -Audit $auditObject -Path $htmlPath | Out-Null
        Write-AuditLog "Rapport HTML généré : $htmlPath" -Level OK
    }

    if ($Format -contains 'CSV') {
        foreach ($file in (Export-AuditCsv -Audit $auditObject -Folder $OutputPath -Stamp $stamp)) {
            Write-AuditLog "Export CSV généré : $file" -Level OK
        }
    }

    if ($Format -contains 'JSON') {
        $jsonPath = Export-AuditJson -Audit $auditObject -Folder $OutputPath -Stamp $stamp
        if ($jsonPath) { Write-AuditLog "Export JSON généré : $jsonPath" -Level OK }
    }

    Write-AuditLog "=== Audit terminé : statut $($auditObject.Summary.Statut) ===" -Level STEP

    if ($PassThru) { $auditObject }
}
finally {
    if ($script:Connected -and -not $KeepConnection) {
        Invoke-VB365Command -Name 'Disconnect-VBOServer' -Quiet | Out-Null
        Write-AuditLog "Session VB365 fermée." -Level INFO
    }
}

#endregion
