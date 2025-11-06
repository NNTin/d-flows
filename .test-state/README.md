# Test State Directory

This directory contains files and state related to integration testing with act.

## Purpose

The `.test-state` directory is used to store:
- Git repository state backups (tags and branches)
- Test-related temporary files
- Workflow test data

## Structure

```
.test-state/
├── backup/          # Git state backup files (generated during testing)
│   ├── tags-*.txt           # Tagged commits in "tag_name commit_sha" format
│   ├── branches-*.json      # Branch information in JSON format
│   └── manifest-*.json      # Backup metadata files
├── test-tags.txt    # Test tags file (used by bump-version.yml workflow)
└── .gitignore       # Excludes backup files from version control
```

## Backup File Formats

### Tags File (`tags-*.txt`)

Plain text file with one tag per line:

```
tag_name commit_sha
v1.0.0 abc123def456...
v1.0.1 def456ghi789...
v2.0.0 ghi789jkl012...
```

Supports comments starting with `#`:

```
# Backup created on 2025-11-06
# Tags from production release cycle
v1.0.0 abc123def456...
```

### Branches File (`branches-*.json`)

JSON file containing branches and current branch indicator:

```json
{
  "currentBranch": "main",
  "branches": [
    {
      "name": "main",
      "sha": "abc123def456...",
      "isRemote": false
    },
    {
      "name": "release/v1",
      "sha": "def456ghi789...",
      "isRemote": false
    },
    {
      "name": "remotes/origin/main",
      "sha": "abc123def456...",
      "isRemote": true
    }
  ]
}
```

### Manifest File (`manifest-*.json`)

JSON file tracking backup metadata:

```json
{
  "timestamp": "2025-11-06T10:30:00Z",
  "backupName": "20251106-103000",
  "tagsFile": "tags-20251106-103000.txt",
  "branchesFile": "branches-20251106-103000.json",
  "repositoryPath": "C:\\privat\\gitssh\\d-flows",
  "includeRemote": true
}
```

## Usage with Backup-GitState Script

See `scripts/integration/Backup-GitState.ps1` for comprehensive backup and restore functionality:

```powershell
# Load the script
. .\scripts\integration\Backup-GitState.ps1

# Backup current git state
$backup = Backup-GitState

# ... run tests that modify git state ...

# Restore previous state
Restore-GitState -BackupName $backup.BackupName

# List available backups
Get-AvailableBackups
```

## Integration with Workflows

The `bump-version.yml` workflow reads from `.test-state/test-tags.txt` to restore test tags (lines 41-79).
Backup files can be used to populate this file or used directly with the restore functions.

## Cleanup

Backup files in the `backup/` directory are automatically excluded from version control and can be safely deleted:

```powershell
Remove-Item .test-state/backup -Recurse -Force
```

## Notes

- All backup and restore operations include comprehensive DEBUG messages
- Edge cases are handled: empty repositories, detached HEAD, uncommitted changes, missing commits
- Backup format is compatible with existing workflow tag restoration logic
- Remote branches are backed up but not restored (they should be fetched, not created locally)
