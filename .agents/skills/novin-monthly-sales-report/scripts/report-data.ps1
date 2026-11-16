param(
    [Parameter(Mandatory)][string]$LeadsCsv,
    [Parameter(Mandatory)][string]$ActivitiesCsv,
    [Parameter(Mandatory)][string]$AsOf,
    [string]$Owner = 'Sara Nadimi',
    [string[]]$Months
)

$ErrorActionPreference = 'Stop'
$culture = [Globalization.CultureInfo]::InvariantCulture
$calendar = [Globalization.PersianCalendar]::new()
$tehran = [TimeZoneInfo]::FindSystemTimeZoneById('Iran Standard Time')
$cutoff = [datetime]::ParseExact($AsOf, 'yyyy-MM-dd', $culture)

function Read-Date([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    if ($value -match 'T.*(?:Z|[+-]\d{2}:?\d{2})$') {
        $stamp = [datetimeoffset]::Parse($value, $culture)
        return [TimeZoneInfo]::ConvertTime($stamp, $tehran).DateTime
    }
    return [datetime]::Parse($value, $culture)
}

function Get-MonthKey([datetime]$date) {
    '{0:0000}-{1:00}' -f $calendar.GetYear($date), $calendar.GetMonth($date)
}

function Get-PersianDate($date, [switch]$WithTime) {
    if ($null -eq $date) { return $null }
    $day = '{0:0000}/{1:00}/{2:00}' -f $calendar.GetYear($date), $calendar.GetMonth($date), $calendar.GetDayOfMonth($date)
    if ($WithTime) { return "$day $($date.ToString('HH:mm', $culture))" }
    return $day
}

function Require-Columns($rows, $names, $table) {
    if (!$rows.Count) { throw "$table export has no records. Verify the Airtable view and export." }
    foreach ($name in $names) {
        if ($name -cnotin $rows[0].PSObject.Properties.Name) { throw "$table is missing column '$name'." }
    }
}

$leadRows = @(Import-Csv -LiteralPath $LeadsCsv -Encoding UTF8)
$activityRows = @(Import-Csv -LiteralPath $ActivitiesCsv -Encoding UTF8)
Require-Columns $leadRows @('Lead Name','Created','Stage','Services','Owner','Last Modified-stage','Next Follow-up Date') 'Leads'
Require-Columns $activityRows @('Activity','Activity Date','Owner','Outcome','وضعیت تماس','لید مرتبط','Lead','Type','Next Follow-up') 'Activities'
$currentMonth = Get-MonthKey $cutoff
if (!$Months) {
    $daysIntoMonth = $calendar.GetDayOfMonth($cutoff)
    $Months = @((Get-MonthKey ($cutoff.AddDays(-$daysIntoMonth))), $currentMonth)
}

$leadByName = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
$leads = @(foreach ($row in $leadRows) {
    $created = Read-Date $row.Created
    if (!$created) { throw 'A lead has no Created timestamp.' }
    if ($created.Date -gt $cutoff) { continue }
    $changed = Read-Date $row.'Last Modified-stage'
    $next = Read-Date $row.'Next Follow-up Date'
    $services = @($row.Services -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim() } | Where-Object { $_ } | Sort-Object -Unique)
    $record = [pscustomobject]@{
        name = $row.'Lead Name'
        owner = $row.Owner
        stage = $row.Stage
        services = $services
        created = (Get-PersianDate $created -WithTime)
        createdMonth = (Get-MonthKey $created)
        stageChanged = (Get-PersianDate $changed -WithTime)
        stageMonth = if ($changed) { Get-MonthKey $changed }
        elapsedMinutes = if ($changed -and $changed -ge $created) { [int]($changed - $created).TotalMinutes }
        nextFollowup = (Get-PersianDate $next)
        hasImportRow = [bool]$row.'Import Row'
    }
    if ($record.name) {
        if (!$leadByName.ContainsKey($record.name)) {
            $leadByName[$record.name] = [Collections.Generic.List[object]]::new()
        }
        $leadByName[$record.name].Add($record)
    }
    $record
})

$titlePattern = '^\s*(?:پی[\s‌]*گیری|پگیری|یگیری|پییری|یگیر)(?:\s|[0-9۰-۹]|$)'
$followups = @(foreach ($row in $activityRows) {
    if ($row.Owner -cne $Owner) { continue }
    $date = Read-Date $row.'Activity Date'
    if (!$date -or $date.Date -gt $cutoff) { continue }
    $title = ($row.Activity -split '\s*·\s*', 2)[0].Trim()
    if ($title -notmatch $titlePattern) { continue }
    $name = if ($row.'لید مرتبط') { $row.'لید مرتبط' } else { $row.Lead }
    $verified = $name -and $leadByName.ContainsKey($name) -and $leadByName[$name].Count -eq 1
    $lead = if ($verified) { $leadByName[$name][0] }
    [pscustomobject]@{
        name = $name
        date = (Get-PersianDate $date)
        month = (Get-MonthKey $date)
        channel = $row.Type
        outcome = $row.Outcome
        callStatus = $row.'وضعیت تماس'
        nextFollowup = (Get-PersianDate (Read-Date $row.'Next Follow-up'))
        match = if ($verified) { 'exact' } elseif ($name) { 'unresolved' } else { 'missing' }
        stage = if ($verified) { $lead.stage }
        stageChanged = if ($verified) { $lead.stageChanged }
    }
})

$monthly = @(foreach ($month in $Months) {
    if ($month -notmatch '^(\d{4})-(0[1-9]|1[0-2])$') { throw "Invalid Persian month: $month" }
    $parts = $month.Split('-')
    $start = $calendar.ToDateTime([int]$parts[0], [int]$parts[1], 1, 0, 0, 0, 0)
    $end = $calendar.AddMonths($start, 1).AddDays(-1)
    $reportEnd = if ($end -gt $cutoff) { $cutoff } else { $end }
    $calendarDays = [math]::Max(0, ($reportEnd - $start).Days + 1)
    $activities = @($followups | Where-Object month -ceq $month)
    $activeDays = @($activities.date | Sort-Object -Unique).Count
    $matchedGroups = @($activities | Where-Object match -eq 'exact' | Group-Object -Property name -CaseSensitive)
    $business = @(foreach ($group in $matchedGroups) {
        $first = $group.Group | Sort-Object date | Select-Object -First 1
        $changeDay = if ($first.stageChanged) { $first.stageChanged.Substring(0,10) }
        [pscustomobject]@{
            name = $first.name
            firstFollowup = $first.date
            stage = $first.stage
            stageChanged = $first.stageChanged
            followups = $group.Count
            timing = if (!$changeDay) { 'unknown' } elseif ($changeDay -cgt $first.date) { 'after' } elseif ($changeDay -ceq $first.date) { 'same-day' } else { 'before' }
        }
    })
    [pscustomobject]@{
        month = $month
        calendarDays = $calendarDays
        activeDays = $activeDays
        followupCount = $activities.Count
        dailyOnActiveDays = if ($activeDays) { $activities.Count / $activeDays }
        dailyAcrossPeriod = if ($calendarDays) { $activities.Count / $calendarDays }
        unresolved = @($activities | Where-Object match -ne 'exact').Count
        business = $business
    }
})

[ordered]@{
    asOf = $AsOf
    asOfPersian = (Get-PersianDate $cutoff)
    currentMonth = $currentMonth
    owner = $Owner
    leads = $leads
    followups = $followups
    monthlyFollowups = $monthly
} | ConvertTo-Json -Depth 8