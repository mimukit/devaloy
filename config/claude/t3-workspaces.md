## T3 Code workspaces

gitkit, issuekit `start`, and mergekit `start` end with a `Workspace ready` block when they hand a worktree to the human. When a reply of yours carries that block, open a T3 thread bound to that worktree, without asking. This rule is the human's standing request for a new top-level thread.

1. Read `repo`, `worktree`, `branch`, and `for` from the block.
2. Look for an existing thread. Call `t3_thread_list` with `titleContains` set to the branch, active and settled. If a thread exists, link it and stop.
3. Find the project. Use the calling thread's project when its root is `repo`. Otherwise find the project with `t3_project_list` and pass its `projectId`. If no project matches, say so and stop.
4. Call `t3_thread_launch` with `workspaceStrategy: {"type":"existing_worktree","worktreePath":<worktree>,"branch":<branch>}`.
5. Set the title to `<branch>`, plus ` (PR #<n>)` when `for` names a PR.
6. Omit `message` and `attachments`. The thread starts idle, and the human types the first prompt.
7. Report the thread as `[title](t3-thread://v1/<threadId>)`. If the launch fails, report the error. Check `t3_thread_list` before you retry.

Do not open a thread when the run is unattended (afkkit), or when a skill called another skill and the block was not printed to the human.
