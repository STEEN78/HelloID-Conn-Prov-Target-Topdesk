$path = 'C:\Temp\TOPdesk\exampleChanges.json'

try {
    If (Test-Path $path) {
        $changeList = Get-Content -Raw -Path $path | ConvertFrom-Json
        $permissions = $changeList | Select-Object -Property displayName, identification
        write-output $permissions | ConvertTo-Json -Depth 10;
    }
}
catch{
        $result = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($result)
        $reader.BaseStream.Position = 0
        $reader.DiscardBufferedData()
        $errResponse = $reader.ReadToEnd();
        $auditMessage = "${errResponse}";
}