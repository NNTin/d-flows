```mermaid
sequenceDiagram
    autonumber

    participant Scheduler as GitHub Scheduler (cron: 2x/day)
    participant Workflow as GitHub Action (runs in d-cogs)
    participant Source as bz-cogs (source repo)
    participant Dest as d-cogs (destination repo)

    Scheduler ->> Workflow: Trigger workflow (twice daily)

    Workflow ->> Dest: Checkout destination repository
    Workflow ->> Workflow: git config user.name = "nntin-bot"
    Workflow ->> Workflow: git config user.email = "48604375+nntin-bot@users.noreply.github.com"

    Workflow ->> Dest: Delete aiuser/ and aimage/
    Workflow ->> Source: Copy aiuser/ and aimage/ from source repo
    Workflow ->> Dest: Check git diff

    alt No changes
        Workflow -->> Scheduler: Workflow ends
    else Changes exist
        Workflow ->> Dest: Commit changes (authored as nntin-bot)
        Workflow ->> Dest: Create or update Pull Request
    end

    Workflow -->> Scheduler: Workflow complete
```

In d-flows/actions/sync-cogs/action.yml the source repo can be configured with source_repo. Here it is @bz-cogs.  
In d-flows/actions/sync-cogs/action.yml cog_names can be configured. Here it is aiuser and aiimage, see qbz-cogs/aiuser and @bz-cogs/aimage