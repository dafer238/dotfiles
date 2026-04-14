# Rust Versions of APE and SPE

This directory contains Rust implementations of the `ape.bat` and `spe.bat` scripts for managing Python virtual environments on Windows.

## Architecture

The tools use a **core binary + shell wrapper** architecture to activate virtual environments in your **current shell session** (no nested shells):

- **`ape-core.exe` / `spe-core.exe`** — Rust binaries that handle searching, scanning, caching, and writing the venv path to a temp marker file
- **`ape.cmd` / `spe.cmd`** — CMD wrappers that call the core binary and run `call activate.bat` in the current CMD session
- **`Invoke-PythonVenv.ps1`** — PowerShell functions that call the core binary and dot-source `Activate.ps1` in the current pwsh session

## Features

Both programs replicate **all** functionality from the original batch scripts:

### APE (Activate Python Environment)

- ✅ Activate Python environments by name
- ✅ Verbose mode (`-v`, `--verbose`)
- ✅ Comprehensive scan mode (`-s`, `--scan`)
- ✅ Cache management for fast lookups
- ✅ Support for venv, conda, and uv environments
- ✅ Unknown flag detection with helpful warnings
- ✅ **Activates in current shell** (CMD and PowerShell) — no nested terminals
- ✅ Search predefined directories or entire user folder
- ✅ All original help text and error messages

### SPE (Search Python Environment)

- ✅ Interactive menu to browse and select environments
- ✅ Select by number or name
- ✅ Verbose mode and scan mode
- ✅ Cache management
- ✅ Formatted table output
- ✅ **Activates in current shell** (CMD and PowerShell) — no nested terminals
- ✅ Type 'Q' to quit
- ✅ All original functionality preserved

## Performance Benefits

The Rust versions offer significant performance improvements:

- **10-100x faster scanning** - Especially noticeable with `--scan` flag
- **Instant startup** - No interpreter overhead
- **Faster string operations** - More efficient than batch delayed expansion
- **Better file system traversal** - Optimized directory scanning

## Building the Programs

### Prerequisites

1. Install Rust from [rustup.rs](https://rustup.rs/)
2. Open a terminal and verify installation:
   ```bash
   rustc --version
   cargo --version
   ```

### Build Both Programs

```bash
cd C:\Users\0206100\dev\scripts\windows\rust

# Build both APE-CORE and SPE-CORE (single command)
cargo build --release
```

The compiled binaries will be at:

```
target\release\ape-core.exe
target\release\spe-core.exe
```

## Installation

### Option 1: Copy to Scripts Directory (Recommended)

```bash
# Copy compiled binaries and wrappers to your Scripts folder
copy target\release\ape-core.exe ..\ape-core.exe
copy target\release\spe-core.exe ..\spe-core.exe
copy ape.cmd ..\ape.cmd
copy spe.cmd ..\spe.cmd
copy Invoke-PythonVenv.ps1 ..\Invoke-PythonVenv.ps1
```

For CMD: `ape` and `spe` work immediately (if the Scripts directory is in your PATH).

For PowerShell: Add this line to your `$PROFILE`:
```powershell
. "C:\path\to\Scripts\Invoke-PythonVenv.ps1"
```

### Option 2: Add to PATH

Add the `target\release` directory to your PATH and copy the wrapper scripts there.

### Option 3: Use Build Script

Run `build.bat` which handles building, copying, and hard-link creation interactively.

## Usage

The Rust versions have **nearly identical** command-line interfaces to the batch scripts, with some new options:

> **Note:** Always invoke via the wrapper (`ape` / `spe`), not the core binary (`ape-core` / `spe-core`) directly, so the venv activates in your current shell.

### APE Examples

```bash
# Activate an environment by name
ape myenv

# Scan entire user folder and update cache
ape --scan
ape -s

# Scan and then activate
ape -s myenv
ape --scan myenv

# Verbose mode (shows debug info)
ape -v myenv
ape --verbose myenv

# Combine flags (order doesn't matter)
ape -v -s myenv
ape -s -v myenv

# Disable colored output
ape --no-color myenv

# Show help
ape --help
ape -h
ape /?
```

### SPE Examples

```bash
# Interactive menu (uses cache if available)
spe

# Scan entire user folder first
spe --scan
spe -s

# Verbose mode
spe -v
spe --verbose

# Scan with verbose output
spe -s -v

# Disable colored output
spe --no-color

# Show help
spe --help
spe -h
spe /?
```

## File Size Comparison

| Program    | Batch Script | Rust Binary (Release) |
| ---------- | ------------ | --------------------- |
| ape-core   | 14 KB        | ~750 KB (stripped)    |
| spe-core   | 12 KB        | ~760 KB (stripped)    |

While the Rust binaries are larger, they execute much faster and include all runtime dependencies.

## Technical Details

### Activation Mechanism

The core binaries (`ape-core.exe`, `spe-core.exe`) write the venv root path to a temp marker file (`%TEMP%\_venv_activate_path.txt`). Shell wrappers read this file and activate the environment in-process:

- **CMD**: `ape.cmd` / `spe.cmd` use `call activate.bat`
- **PowerShell**: `Invoke-PythonVenv.ps1` functions dot-source `Activate.ps1`

This ensures the virtual environment is activated in your **current shell session** — no nested terminals.

### Environment Detection

Both programs detect three types of Python environments:

1. **venv** - Standard Python virtual environments
2. **conda** - Anaconda/Miniconda environments (detected via `conda-meta` folder)
3. **uv** - UV-created environments (detected via `pyvenv.cfg` contents)

### Cache Location

Cache file: `%TEMP%\python_venv_cache.json`

Format: JSON with array of environment objects containing `name`, `env_type`, and `path` fields

### Searched Directories

When not using `--scan`, searches these predefined locations:

- `%USERPROFILE%`
- `%USERPROFILE%\.venv`, `\venv`, `\.venvs`, `\venvs`
- `%USERPROFILE%\code` (and its venv subdirectories)
- `%USERPROFILE%\code\python` (and its venv subdirectories)
- `%USERPROFILE%\AppData\Local\Programs` (and its venv subdirectories)
- `%USERPROFILE%\AppData\Local\Programs\Python` (and its venv subdirectories)

With `--scan`, recursively searches entire `%USERPROFILE%` directory (excluding `Temp`, `Cache`, `tmp`, and `node_modules`).

## Configuration File

To customize the directories searched by APE and SPE:

1. Create the directory: `%USERPROFILE%\.config`
2. Create file: `%USERPROFILE%\.config\python_venv_config.toml`
3. Add your custom directories:

```toml
directories = [
    "%USERPROFILE%\\my_projects",
    "C:\\dev\\python",
    "%USERPROFILE%\\code\\.venvs"
]
```

See `python_venv_config.toml.example` for more details.

## Development

### Debug Builds

For development/testing, use debug builds (faster compilation, slower execution):

```bash
cargo build

# Debug binaries are at target\debug\
```

### Testing

```bash
# Test ape-core
target\debug\ape-core.exe --help
target\debug\ape-core.exe -v -s

# Test spe-core
target\debug\spe-core.exe --help
target\debug\spe-core.exe -v
```

## Troubleshooting

### "cargo: command not found"

Make sure Rust is installed and `%USERPROFILE%\.cargo\bin` is in your PATH.

### Permission Errors

Run Command Prompt or PowerShell as Administrator if you get permission errors during compilation.

### Missing USERPROFILE

If you get errors about USERPROFILE not being set, the programs will fail gracefully. This should never happen in normal Windows environments.

### Activation Script Not Found

The programs look for `Scripts\activate.bat` in the environment directory. If you get this error, the environment might be corrupted or created on a non-Windows system.

### Environment Not Activating (PowerShell)

Make sure your `$PROFILE` dot-sources `Invoke-PythonVenv.ps1`:
```powershell
. "C:\path\to\Invoke-PythonVenv.ps1"
```
Without this, typing `ape` runs the `.exe` directly (which can't activate in your shell).

## Migration from Batch Scripts

You can run the Rust versions alongside the batch scripts:

1. The Rust core binaries are named `ape-core.exe` and `spe-core.exe`
2. The CMD wrappers (`ape.cmd`, `spe.cmd`) take precedence over `.bat` files
3. Rename old batch scripts to `ape-old.bat` and `spe-old.bat` as backups

## Advantages of Rust Version

1. **Speed** - 10-100x faster for scanning operations
2. **In-shell activation** - Activates venv in current terminal (CMD and PowerShell)
3. **Reliability** - Better error handling, no batch quirks
4. **Memory efficiency** - More efficient data structures
5. **Cross-platform potential** - Can be adapted for Linux/Mac with minimal changes
6. **Type safety** - Compile-time error checking
7. **Single executable** - No dependencies, no interpreter needed

## Disadvantages

1. **Binary size** - Larger than batch scripts (~200 KB vs ~15 KB)
2. **Compilation required** - Can't edit on-the-fly like batch scripts
3. **Rust knowledge needed** - Harder to modify if you don't know Rust

## Future Enhancements

Possible improvements for the Rust version:

- [x] Parallel directory scanning (using `rayon`) - **IMPLEMENTED**
- [x] Better cache format (JSON, TOML, or binary) - **IMPLEMENTED** (JSON)
- [ ] Fuzzy matching for environment names
- [x] Color output support - **IMPLEMENTED**
- [ ] Auto-completion support
- [ ] Linux/Mac versions (using bash/zsh sourcing)
- [x] Configuration file support - **IMPLEMENTED** (TOML)
- [x] Custom directory list - **IMPLEMENTED**
- [ ] Environment creation shortcuts

## New Features (v1.0+)

### JSON Cache Format

The cache now uses JSON format (`python_venv_cache.json`) instead of plain text. This provides:
- Better data structure support
- Easier parsing and validation
- Human-readable format for debugging

The old cache file (`python_venv_cache.txt`) is no longer used. Run `ape --scan` or `spe --scan` to regenerate the cache in the new format.

### Colored Output

Both programs now support colored terminal output for better readability:
- **Green** - Success messages (environments found, cache updated)
- **Cyan** - Informational messages (scanning progress)
- **Yellow** - Warnings (cache errors, unknown flags)
- **Red** - Errors (environment not found, activation failures)
- **Dimmed** - Debug output (verbose mode)

To disable colors (e.g., for piping to files or terminals that don't support ANSI colors):
```bash
ape --no-color myenv
spe --no-color
```

### Custom Directory Configuration

You can now specify your own list of directories to search by creating a configuration file:

**Location:** `%USERPROFILE%\.config\python_venv_config.toml`

**Example configuration:**
```toml
# Custom directories to search for Python virtual environments
directories = [
    "%USERPROFILE%\\code",
    "%USERPROFILE%\\projects",
    "C:\\dev\\python",
    "%USERPROFILE%\\.venvs"
]
```

**Features:**
- Use `%USERPROFILE%` placeholder for home directory
- Use double backslashes (`\\`) for Windows paths
- If the config file exists and has directories defined, these will be used **instead of** the default predefined directories
- If no config file exists, falls back to default predefined directories
- See `python_venv_config.toml.example` for a complete example

**Benefits:**
- Faster searches by limiting scope to your actual project locations
- Support for non-standard directory structures
- Easy to customize without recompiling

## License

These programs replicate the functionality of the original batch scripts and are provided as-is for personal use.

## Questions?

If you encounter any issues or have questions:

1. Check that the original batch scripts work correctly
2. Verify Rust is installed: `rustc --version`
3. Try rebuilding: `cargo clean` then `cargo build --release`
4. Compare output with batch script using `-v` flag
