# Reference script to fetch users from Active Directory and upload them to Sign In Enterprise as hosts
# see https://guesthelpcenter.force.com/s/article/How-do-I-have-my-host-list-update-automatically

################################################################################
# SIE configuration
################################################################################
$SIE_SERVER_URL = 'https://us.tractionguest.com' # You may need to change this according to your environment.
$SIE_HOST_API_TOKEN = '<TOKEN>'                  # Host Upload tken generated on the SIE preferences page
$SIE_OVERWRITE_PERSON_GROUPS = 'true'            # Hosts will only be in groups that are defined in the upload by this script.
$SIE_REMOVE_UNMACHED_HOSTS = 'true'              # If the host is not included in the newest upload, they will be deleted (unless uploaded by a different user - see "ownership")
$SIE_REMOVE_EMPTY_GROUPS = 'true'                # Deletes any groups at the end of the upload that do not contain any hosts
$SIE_IGNORE_OWNERSHIP = 'false'                  # Will disregard which user originally uploaded the host so that the upload by this script is the one source of truth.
                                                 #   You may want to disable this if you have multiple different sources of hosts (manual uploads, different scripts pulling from different Active Directories, etc.)
$SIE_CSV_ONLY = $true                            # If true then no requests will be sent to SIE, only the CSV file will be generated
$SIE_CSV_SAVE = $true                        # Should the CSV payload be kept on disk after an upload to SIE

################################################################################
# Search Configuration
################################################################################

# You can add as many search operations below as you want.  You can use the value `%%` in override fields to augment the original value from AD.
# [PsCustomObject]@{
#     AdSearchBase = ""
#     AdSearchFilter = {}
#
#     # The following items are optional overrides to control which AD server to query or to override the group/department output in the generated CSV
#     AdServer = ""
#     DepartmentOverride = ""
#     GroupOverride  = ""
# }
$SEARCH_OPERATIONS = @(
  # Replace these examples with queries that work on your AD instance
  [PsCustomObject]@{
    AdSearchBase   = "OU=CH,DC=europe,DC=acme,DC=com"
    AdSearchFilter = { enabled -eq $true -and EmailAddress -like "*@ch.acme.com" -and StreetAddress -like "Bahnhofstrasse 123*" -and givenname -like "*" -and surname -like "*" }
    GroupOverride  = "Switzerland Cityport"
    ExcludedOU     = "OU=Temporary Hosts,OU=CH,DC=acme,DC=come" # ExcludedOU specifies the Organizational Unit (OU) to be excluded from processing.
  }
  [PsCustomObject]@{
    AdServer       = "americas.acme.com"
    AdSearchBase   = "OU=US,DC=americas,DC=acme,DC=com"
    AdSearchFilter = { enabled -eq $true -and EmailAddress -like "*@us.acme.com" -and Office -like "New York, US" -and givenname -like "*" -and surname -like "*" }
    GroupOverride  = "US NY"
  }
)

################################################################################
# ALERT EMAIL CONFIG
# - In case of failures, an email notification can be sent to the script admin
################################################################################
$ALERT_MAIL_ENABLED = $false                          # set this to $false if you don't want to receive notifications
$ALERT_MAIL_TO = 'user@example.com,user2@example.com' # list of recipients to send the notification to
$ALERT_MAIL_FROM = 'admin@example.com'                # email address to identify the sender
$ALERT_MAIL_SUBJECT = 'SIE AD Host Sync'              # email subject
$ALERT_MAIL_SERVER = 'smtp.example.com'               # your corporate SMTP server to send the email through

################################################################################
# Script Start - DO NOT MODIFY ANYTHING BELOW EXCEPT LINES 126~136
################################################################################
$DEFAULT_AD_SERVER = $(Get-ADDomain).InfrastructureMaster

# Function to filter out users from a specific OU
function Filter-ExcludedOU {
  param(
    [string]$DistinguishedName,
    [string]$ExcludedOU
  )
  return $DistinguishedName -notlike "*,$ExcludedOU"
}

# Logging config
$LOGFILE = ".\$(Get-Date -format 'yyyy-MM-dd')-SIE_Hosts_Sync.log"

function Log ($message, $is_error = $false) {
  if ($is_error) {
    $message = "[ERROR] $message"
  }
  if ($is_error) {
    "$(Get-Date -format s) $message" | Tee-Object -Append -FilePath $LOGFILE | Write-Error
  }
  else {
    "$(Get-Date -format s) $message" | Tee-Object -Append -FilePath $LOGFILE | Write-Host
  }
}

Log "$(Get-Location)\$($MyInvocation.MyCommand.Name) *** SIE Hosts Sync start ***"
Log "Have $($SEARCH_OPERATIONS.count) searches configured"

$search_op_num = 0
$final_users = @()
foreach ($search_op in $SEARCH_OPERATIONS) {
  $search_op_num += 1
  if ($search_op.AdServer) {
    $ad_server = $search_op.AdServer
  }
  else {
    $ad_server = $DEFAULT_AD_SERVER
  }
  Log("[Search $search_op_num]: ******************** START ********************")
  Log("[Search $search_op_num]: $search_op")
  # Pull Active Directory users to build the payload
  Log("[Search $search_op_num] Searching AD ($ad_server): " + $search_op.AdSearchBase)
  $ad_users = Get-ADUser -filter $search_op.AdSearchFilter `
    -searchbase $search_op.AdSearchBase -properties mail, country, department -server $ad_server |
  Where-Object { (Filter-ExcludedOU $_.DistinguishedName $search_op.ExcludedOU) } |
  ForEach-Object {
    $email = $_.mail.trim()
    $first_name = $_.givenname.trim()
    $last_name = $_.surname.trim()

    if ($search_op.GroupOverride) {
      $group = $search_op.GroupOverride.replace("%%", $_.country).trim()
    }
    else {
      $group = $_.country
    }

    if ($search_op.DepartmentOverride) {
      $department = $search_op.DepartmentOverride.replace("%%", $_.department).trim()
    }
    else {
      $department = $_.department
    }

    new-object psobject -property @{
      email      = $email
      first_name = $first_name
      last_name  = $last_name
      group      = $group
      department = $department
      # Uncomment the lines below to enable the optional properties and adjust line 137 accordingly
      #mobile = $mobile
      #alternate_email = alternate_email
      #alternate_mobile = alternate_mobile
      #sms_enabled = sms_enabled
    }
  } | Select-Object email, first_name, last_name, group, department #,mobile,alternate_email,alternate_mobile,sms_enabled

  Log "[Search $search_op_num] $($ad_users.Count) users fetched from Active Directory"


  # filter out invalid emails
  $ad_users = $ad_users | `
    Where-Object { ($_.email -match '\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b') } | `
    Where-Object { ($_.email -match "@" + $search_op.EmailDomain) } | `
    Sort-Object * -Unique

  $final_users += $ad_users
  Log "[Search $search_op_num] $($ad_users.Count) users remain after filtering ($($final_users.count) cumulative total)"
  Log("[Search $search_op_num]: ********************  END  ********************")
}

# build the CSV payload
$csv_file = ".\$(Get-Date -format 'yyyy-MM-dd')-SIE_Hosts_Sync.csv"
$final_users | Export-Csv -NoTypeInformation -encoding UTF8 -Path $csv_file

# Call SIE API's Hosts Import endpoint
if ( $SIE_CSV_ONLY ) {
  Log "Not uploading to SIE; See $csv_file"
  Exit 0
}
try {
  $SIE_HOST_IMPORT_URL = "${SIE_SERVER_URL}/people/import_v2?" +
  "remove_unmatched_hosts=${SIE_REMOVE_UNMACHED_HOSTS}&" +
  "ignore_ownership=${SIE_IGNORE_OWNERSHIP}&" +
  "overwrite_person_groups=${SIE_OVERWRITE_PERSON_GROUPS}&" +
  "remove_empty_groups=${SIE_REMOVE_EMPTY_GROUPS}"
  $headers = @{AUTHORIZATION = "Basic $SIE_HOST_API_TOKEN" }
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri $SIE_HOST_IMPORT_URL `
    -ContentType "text/plain;charset=utf-8" -Method Post -InFile $csv_file -Headers $headers `
    -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Out-Null
  Log "Hosts uploaded successfully"
  $exit_code = 0
}
catch {
  Log "Failed to upload hosts! $($_.Exception.Message)" -is_error $true
  Log "API response: $_" -is_error $true
  if ( $ALERT_MAIL_ENABLED ) {
    Send-MailMessage -To $ALERT_MAIL_TO -From $ALERT_MAIL_FROM -subject $ALERT_MAIL_SUBJECT -SmtpServer $ALERT_MAIL_SERVER -Body "SIE Host Sync failed: $_"
  }
  $exit_code = 1
}

if ($SIE_CSV_SAVE) {
  Log "CSV payload kept on $csv_file"
}
else {
  Remove-Item $csv_file
}

Log "Script Complete: ec=$exit_code"
Exit $exit_code
