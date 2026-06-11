# hq/ — the office deployment kit

**HQ** is the team's headquarters: a small private git repo holding the company's *state* —
task queue, standup board, journal, knowledge, and the registry of repos the board watches.
It deliberately contains **no code**: all behavior (queue/board scripts, contracts, hooks) lives
in this harness repo, tested and CI'd. HQ holds only data + prose, so it never needs its own
test suite.

```
your-hq/
├── AGENTS.md        chief-of-staff contract (start from templates/AGENTS.md)
├── CLAUDE.md        pointer: @AGENTS.md
├── registry.json    repos the board scans — supports ~ paths
├── board/queue/     queued tasks, one JSON file each (queue-add.sh writes them)
├── BOARD.md         human render (team-board.sh --write)
├── journal/         one short entry per working day
└── knowledge/       durable notes that outgrew a single task
```

## Create an office

```bash
mkdir -p ~/hq && cd ~/hq && git init
cp <harness>/hq/templates/AGENTS.md AGENTS.md     # then personalize it
printf '# CLAUDE.md\n\n@AGENTS.md\n' > CLAUDE.md
mkdir -p board/queue journal knowledge
echo '{"repos": []}' > registry.json
printf '%s' "$PWD" > ~/.claude/maestro-hq          # the pointer — scripts find HQ through it
```

Or, on a machine that already has the harness installed: clone your existing HQ and run
`./bootstrap.sh` inside it (writes the pointer, validates the registry).

## Portability

HQ moves with git: give it a **private** remote, and never put secrets in journal/knowledge.
`registry.json` paths support `~`, so the same registry works across machines that keep the
same layout under `$HOME`. New-machine runbook: install harness → clone HQ → `./bootstrap.sh`.
