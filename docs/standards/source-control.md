# Git and Branch Management

## Branch Protection Rules

**CRITICAL**: Never commit directly to protected branches:

- **NEVER** commit to `master` or `main` directly
- **ALWAYS** create a feature branch before making commits
- Feature branch naming: `feature/<brief-description>` (e.g., `feature/overridable-value`). Never include the task or phase number in the branch name.
- Bug fix branch naming: `fix/<issue-description>`

## Workflow

1. **Before any work**: Create and checkout a feature branch

   ```bash
   git checkout -b feature/description
   ```

2. Make your commits on the feature branch
3. When ready, push the branch and create a pull request

## Commit Guidelines

When working as an automated agent:

1. **Atomic Commits**: Each commit should represent one logical change
2. **Descriptive Messages**: Use conventional commit format `<type>(<scope>): <description> (auto via agent)`
3. **Separate Concerns**: Tests and implementation in different commits when following TDD
