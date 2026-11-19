# Kiro workflow

This document explains how GitHub issues, Kiro specs, commits, and pull requests map to each other.

## 1. Issue to spec mapping

Each GitHub issue maps to exactly one spec folder at `.kiro/specs/<NN>-<slug>/`. Each spec folder maps to exactly one GitHub issue.

## 2. The `<NN>` placeholder

`<NN>` is the issue sequence number written as exactly two digits, zero-padded, in the range `01` to `99`.

## 3. The `<slug>` placeholder

`<slug>` is a lowercase kebab-case short name of 1 to 40 characters.

- It contains only the characters `a`-`z`, `0`-`9`, and `-`.
- It does not start or end with `-`.
- It does not contain two `-` in a row.

Example of a complete folder name: `01-repo-bootstrap`, which gives `.kiro/specs/01-repo-bootstrap/`.

## 4. Issue reference inside the spec

Each spec folder records the number of the GitHub issue it maps to, written as `#<issue-number>`. The first line of the Overview section in `design.md` reads:

```text
GitHub issue: #<issue-number>
```

For the spec `01-repo-bootstrap` the line is `GitHub issue: #1`. A reader can get from the spec to the issue without relying on `<NN>`.

## 5. Commits

Every commit message contains the GitHub issue number in the form `#<issue-number>`.

Example:

```text
Add steering files and conventions docs (#1)
```

## 6. Pull requests

Every pull request title or description contains the GitHub issue number in the form `#<issue-number>`.

Example:

- Title: `Repo bootstrap (#1)`
- Description: `Closes #1`

## 7. Task lists

Spec task lists contain no automated test tasks. Each test task is replaced by a manual verification step. A manual verification step names the action to perform and the observable result that counts as a pass.

Example:

```text
Manual verification: layout
- Run `wc -l infra/README.md`. Pass: the count is 50 or less.
- Record what was checked and the result in the task notes.
```

## 8. Testing policy

The testing policy is in `.kiro/steering/tech.md`. It applies to every spec.

## Related files

- Demo questions: `.kiro/steering/product.md`
- Layout and naming rules: `.kiro/steering/structure.md`
