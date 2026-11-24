CI modifications require explicit human approval.
The canonical CI workflow is in docs/workflow.md. All changes to it must be explicitly approved by a human.

## Tests on Jai's Macs

Before you run UI tests, or anything else that controls the screen, on one of Jai's Macs (directly or over SSH), read
`AGENTS.ci.md` in jai/ci (private):
`gh api repos/jai/ci/contents/AGENTS.ci.md -H 'Accept: application/vnd.github.raw'`.
It says which Macs are off limits and how to run Mac UI tests through CI. If you cannot read it, do not run them there.
