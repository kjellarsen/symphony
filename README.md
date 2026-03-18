# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## Windows launcher

This fork tracks the Windows launcher templates under `scripts/windows`.

Install or refresh the launcher with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\install-symphony-launcher.ps1
```

That writes generated wrappers to `%APPDATA%\npm\symphony.ps1` and `%APPDATA%\npm\symphony.cmd`,
stamping in the current repo root. The generated files are local install artifacts; the tracked
templates in this repo are the source of truth.

The Windows setup flow accepts a Linear project slug, project URL, or project name. When
`LINEAR_API_KEY` is available, it resolves that input to the canonical Linear `slugId` and asks
for confirmation before writing it to `WORKFLOW.md`.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
