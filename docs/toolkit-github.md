# Toolkit GitHub repositories

Toolkit can list issues, pull requests and GitHub Actions runs for repositories
explicitly enabled by the server operator. Aides uses GitHub's official read APIs
and links each result to the corresponding GitHub page.

Put `github-repositories.json` in the protected `Toolkit` subdirectory of the
Aides data directory. Use mode `0700` for the directory and `0600` for files,
owned by the account that runs the server.

```json
[
  {"id":"aides","owner":"Typogalaxy","name":"aides","label":"Aides","publicRead":true},
  {"id":"internal","owner":"my-org","name":"private-repo"}
]
```

Without `publicRead`, put a read-only GitHub fine-grained personal access token
or GitHub App access token in `github-<id>.token`. Constrain it to the configured
repository and enable the relevant read permissions for Issues, Pull requests
and Actions. A token can also be supplied for a public repository. Results are
bounded to one page per request and can be viewed on paired devices.

[Repositories and fine-grained permissions](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens) ·
[Issues API](https://docs.github.com/en/rest/issues/issues#list-repository-issues) ·
[Pull requests API](https://docs.github.com/en/rest/pulls/pulls#list-pull-requests) ·
[Workflow runs API](https://docs.github.com/en/rest/actions/workflow-runs#list-workflow-runs-for-a-repository)

## Create an issue or pull request

Set the repository's `allowedWrites` to `["issue"]`, `["pullRequest"]` or
`["issue", "pullRequest"]` to enable the corresponding actions. A protected
token for that repository is required even for public repositories. Give a
fine-grained token **Issues** write permission to create issues or **Pull
requests** write permission to open pull requests. A PR uses two existing
branches in its configured repository. [Create an issue](https://docs.github.com/en/rest/issues/issues#create-an-issue) · [Create a pull request](https://docs.github.com/en/rest/pulls/pulls#create-a-pull-request)

Prepare the exact title, body and branches in Toolkit. The server binds them
to the selected repository and records a pending receipt. Review and confirm
before publishing. Aides rechecks the host configuration and repository before
dispatch. If confirmation of the result is interrupted, check the repository
before starting another request. Repeating the same approval returns the
recorded state.
