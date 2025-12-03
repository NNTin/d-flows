AI revision work:
- [ ] Implement cog syncing and commit logic in sync-cogs action
- [ ] Implement PR creation with single/multiple PR support in sync-cogs action
- [ ] Implement workflow using the new GitHub Action in d-cogs (💀gonna be a nightmare testing without nektos/act)

Bugs:
- [ ] commit user configured as [nntin-bot](https://github.com/nntin-bot), would be better if this is customizable
- [ ] c.csw.im is hardcoded, should not be
- [ ] fork is always created, not possible for git repositories not living on GitHub
  - [ ] relevant for destination repository, don't maintain a forgejo or gitea instance to test myself
- [ ] TOKEN assumes a third party unrelated account (e.g. a github bot account)
  - [ ] we should (??) support the owner account of the destination repository, but this opens a security risk, that's why the PoC was started with a third party github bot account

To provide proper forgejo/gitea compatibility is not high on my todo list since I don't use it and it will require quite a bit of changes


Create a final sequence diagram to verify behavior!




```mermaid
sequenceDiagram
    autonumber

    participant Scheduler as GitHub Scheduler (cron: 2x/day)
    participant Workflow as GitHub Action (runs in d-cogs)
    participant Source as bz-cogs (source repo)
    participant Dest as d-cogs (destination repo)

    Scheduler ->> Workflow: Trigger workflow (twice daily)

    Workflow ->> Source: Check for updates in aiuser/ and aimage/
    Source -->> Workflow: New updates? (compare commit SHAs)

    alt No updates
        Workflow -->> Scheduler: Workflow ends
    else Updates exist
        Workflow ->> Dest: Checkout destination repository
        Workflow ->> Workflow: git config user.name = "nntin-bot"
        Workflow ->> Workflow: git config user.email = "nntin-bot@users.noreply.github.com"

        Workflow ->> Source: Fetch updated aiuser/ and aimage/
        Workflow ->> Dest: Copy updated folders into destination repo
        Workflow ->> Dest: Commit changes (authored as nntin-bot)
        Workflow ->> Dest: Create or update Pull Request
    end

    Workflow -->> Scheduler: Workflow complete

```