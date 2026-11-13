param(
    [Parameter(Mandatory = $true)]
    [string] $BaselineCommit
)

$ErrorActionPreference = 'Stop'

# Compare trees directly: a migration already on the target branch must remain
# present and byte-for-byte unchanged. Disable rename detection so moves fail too.
$changes = @(git diff --name-status --no-renames --diff-filter=MDT $BaselineCommit HEAD -- db/migrations/)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not compare migration history. Fetch the baseline commit first.'
}

if ($changes.Count -gt 0) {
    Write-Output 'Existing migrations must not be modified, deleted, renamed, or replaced.'
    $changes | ForEach-Object { Write-Output $_ }
    throw 'Restore the target branch migrations and add a new versioned migration instead. If the target branch advanced, update your branch first.'
}

Write-Output 'Migration history is preserved; new migrations are allowed.'
