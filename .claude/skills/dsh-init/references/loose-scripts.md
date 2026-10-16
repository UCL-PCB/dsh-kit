# Scaffolding a package for loose scripts

Read this when, at step 2, the user's code is a folder of `.py` scripts or notebooks that is
**not a git repo**, has **no `pyproject.toml`**, or both. dsh-kit cannot carry it as it is:
`export_bundles.sh` makes a `git bundle` of each repo and refuses anything without `.git`,
and `install_packages.sh` installs each repo with `uv pip install -e`, which needs a
`pyproject.toml`. That file is also the only place the third-party packages the scripts
import get named, so without it nothing inside would install them.

The fix is small and leaves the scripts where they are: a `pyproject.toml` listing the
dependencies, a one-line marker module for the import check, a `.gitignore`, then
`git init`, a commit and a remote. The scripts are still run as files inside; nothing about
how they are written has to change.

This writes into **the user's folder**, not this repo. Say so, and show each file before
writing it. Same rules as the rest of the interview: one question at a time, each with a
proposed answer.

## 1. Where, and what it is called

The folder must sit under `KIT_REPOS_DIR` like any other repo. Its **directory name** goes
in `KIT_REPOS` and, with `-` → `_`, is the default import name the smoke test checks, so it
must be letters, digits, `-` and `_`, starting with a letter: no spaces. Propose a name if
the current one does not fit (`My Scripts (v2)` → `my-scripts`).

If the folder has to move or be renamed, ask first and say what may break: absolute paths
inside the scripts, shortcuts, an IDE project pointing at the old path. Never move or rename
it without a yes.

## 2. What gets tracked

List what is in the folder, grouped: code (`.py`, `.ipynb`, small config files such as
`.toml`, `.yaml`, `.json`), data (`.csv`, `.xlsx`, `.parquet`, `.h5`, `.pkl`, `.npy`, …),
outputs (figures, logs, results), and anything over about 1 MB. Propose tracking **code
only**, for two reasons worth saying:

- Whatever is committed goes into git history and, once pushed, onto the remote. Data must
  not travel that way.
- Data does not enter the DSH through the code payload. It has its own route, which is not
  dsh-kit's job.

Flag notebooks with saved outputs: an output cell can embed data (a printed dataframe, a
plotted image). Suggest clearing outputs before the first commit if any notebook touches
real data.

Write a `.gitignore` from the answers. Start from:

```gitignore
__pycache__/
*.pyc
.venv/
.ipynb_checkpoints/
*.egg-info/
build/
```

and add the data and output patterns the user agreed to exclude.

## 3. Dependencies

If the folder already has a `requirements.txt` or `environment.yml`, start from it. Either
way, collect what the code actually imports, with the standard library and the folder's own
modules removed:

```bash
python - <folder> <<'PY'
import ast, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
skip = {"venv", "__pycache__", "site-packages", "node_modules"}
def wanted(p):
    return not any(x.startswith(".") or x in skip for x in p.relative_to(root).parts[:-1])
local = {p.stem for p in root.rglob("*.py") if wanted(p)}
found = set()
def scan(src):
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return
    for n in ast.walk(tree):
        if isinstance(n, ast.Import):
            found.update(a.name.split(".")[0] for a in n.names)
        elif isinstance(n, ast.ImportFrom) and n.module and n.level == 0:
            found.add(n.module.split(".")[0])
for p in root.rglob("*.py"):
    if wanted(p):
        scan(p.read_text(errors="ignore"))
for p in root.rglob("*.ipynb"):
    if wanted(p):
        try:
            cells = json.loads(p.read_text(errors="ignore")).get("cells", [])
        except ValueError:
            print(f"unreadable notebook: {p}", file=sys.stderr)
            continue
        for c in cells:
            if c.get("cell_type") == "code":
                lines = "".join(c.get("source", "")).splitlines()
                scan("\n".join(l for l in lines if not l.lstrip().startswith(("%", "!"))))
print(" ".join(sorted(found - set(sys.stdlib_module_names) - local)))
PY
```

It needs Python 3.10 or later (`sys.stdlib_module_names`). It prints **import** names, which
are not always the names to install. Translate the common ones (`sklearn` → `scikit-learn`,
`cv2` → `opencv-python`, `PIL` → `pillow`, `yaml` → `pyyaml`, `bs4` → `beautifulsoup4`,
`skimage` → `scikit-image`) and ask about any you are unsure of. An import inside a
`try:` may be optional, and one the scanner missed (`importlib.import_module`, `__import__`)
will show up as an `ImportError` inside, so ask the user whether the list looks complete.

For lower bounds, ask which Python the user runs the scripts with now and read the versions
from it:

```bash
<their-python> -c "import importlib.metadata as m, sys; [print(d, m.version(d)) for d in sys.argv[1:]]" numpy pandas
```

Propose `name>=<that version>` for each, or unpinned where it is not installed there. Do
not pin exactly: Artifactory may not mirror that exact release. Every dependency is
something Artifactory must have, so the list should be what the scripts need inside, not
everything in the user's environment.

## 4. Write the files

Show each one, then write it into the folder.

`pyproject.toml`:

```toml
[project]
name = "<name>"
version = "0.1.0"
description = "<one line from the user>"
requires-python = ">=<their Python's major.minor>"
dependencies = [
    "<dist>>=<version>",
]

[build-system]
requires = ["setuptools>=64"]
build-backend = "setuptools.build_meta"

[tool.setuptools]
py-modules = ["<import_name>"]
```

Why each choice:
- **setuptools** builds a flat folder with the scripts left where they are, and
  is the backend Artifactory is most likely to mirror. It is still the backend to give
  `install_uv.sh --probe-package` at hand-over.
- **`py-modules` naming only the marker** stops setuptools' auto-discovery, which refuses a
  flat folder with several top-level modules, and keeps the scripts from being imported at
  install or check time. A script without an `if __name__ == "__main__":` guard would
  run its whole analysis when imported.

`<import_name>.py` (the directory name with `-` → `_`), the marker the default import check
imports:

```python
"""Marker module for <name>.

dsh-kit's import check imports this to confirm the install worked. The scripts beside it
are run as files, not imported; their third-party dependencies are in pyproject.toml.
"""
```

If a file with that name already exists, it is one of the user's scripts: do not overwrite
it. Pick another marker name and list it in `KIT_IMPORT_CHECK` at step 2.

And the `.gitignore` from section 2.

## 5. Prove it installs, here

Into a scratch directory, never the user's folder:

```bash
uv venv <scratch-dir>/.venv
uv pip install --python <scratch-dir>/.venv -e <folder>
<scratch-dir>/.venv/<Scripts-or-bin>/python -c "import <import_name>; print('IMPORT OK')"
```

Run the import from outside the folder, or the current directory hides a broken install. A
resolve failure here (a misspelt distribution, an impossible lower bound) would otherwise
cost a trip through the airlock. If the user agrees, also run one script with the scratch
venv's Python, so a dependency the scanner missed shows up now rather than inside.

## 6. Commit

Not yet a repo: `git -C <folder> init -b main`. Then stage the code the user agreed to track
and the three new files, show `git -C <folder> status --short`, and confirm nothing on it is
data before committing:

```bash
git -C <folder> commit -m "Package scripts for dsh-kit"
```

Already a repo: commit only the three new files, on the current branch.

## 7. A remote

`export_bundles.sh` refuses a branch that is not on `origin` (step 8 says why), so a repo
with no remote cannot be carried. Ask whether the user has somewhere to push it and propose
a **private** GitHub repo. Pushing publishes the committed files to that service, so it waits
for an explicit yes:

```bash
gh repo create <name> --private --source <folder> --remote origin --push
```

Or, if they would rather make it themselves, `git -C <folder> remote add origin <url>` and
`git -C <folder> push -u origin main`. Do not fall back to `--allow-unpushed`.

## Back to step 2

The folder is now a candidate like any other. For it: `KIT_REPOS` takes the directory name;
no extras; `KIT_IMPORT_CHECK` stays empty unless section 4 picked a different marker name;
`KIT_CONSOLE_SCRIPTS` stays empty.

At hand-over, add that inside the DSH the scripts are run with the venv's Python:
`<workspace-dir>/.venv/<Scripts-or-bin>/python <workspace-dir>/src/<name>/<script>.py`. A
script that reads data by a relative or absolute path written for this machine will need
that path changed inside; the DSH's paths are not this machine's.
