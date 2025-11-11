use rayon::prelude::*;
use std::env;
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use walkdir::WalkDir;

const CACHE_FILENAME: &str = "python_venv_cache.txt";

#[derive(Debug, Clone)]
struct Environment {
    name: String,
    env_type: String,
    path: PathBuf,
}

struct Config {
    help: bool,
    verbose: bool,
    scan: bool,
    unknown_flag: Option<String>,
}

fn main() {
    let config = parse_args();

    // Check for unknown flags
    if let Some(flag) = &config.unknown_flag {
        eprintln!();
        eprintln!("Warning: Unknown flag \"{}\"", flag);
        eprintln!("Run 'spe --help' for usage information.");
        eprintln!();
        return;
    }

    // Show help
    if config.help {
        show_help();
        return;
    }

    let cache_file = get_cache_path();
    let predefined_dirs = get_predefined_dirs();

    if config.verbose {
        println!("[DEBUG] Verbose mode enabled.");
        println!("[DEBUG] Directories to be scanned:");
        for dir in &predefined_dirs {
            println!("  {}", dir.display());
        }
        println!();
    }

    let environments: Vec<Environment>;

    // Handle scan mode
    if config.scan {
        println!("Performing comprehensive scan...");
        println!("This may take a moment...");
        println!();

        environments = scan_all_venvs(&config);
        println!("Found {} environments.", environments.len());

        if let Err(e) = save_cache(&cache_file, &environments, config.verbose) {
            eprintln!("Warning: Failed to save cache: {}", e);
        } else {
            println!("Cache updated.");
        }
        println!();
    } else if cache_file.exists() {
        // Load from cache
        if config.verbose {
            println!("[DEBUG] Loading from cache...");
        }
        match load_cache(&cache_file, config.verbose) {
            Ok(envs) => environments = envs,
            Err(e) => {
                eprintln!("Warning: Failed to load cache: {}", e);
                println!("Searching for Python environments in predefined directories...");
                if config.verbose {
                    println!("[DEBUG] Tip: Use --scan to search your entire user folder");
                }
                println!();
                environments = scan_predefined_dirs(&predefined_dirs, &config);
            }
        }
    } else {
        // No cache, scan predefined directories
        println!("Searching for Python environments in predefined directories...");
        if config.verbose {
            println!("[DEBUG] Tip: Use --scan to search your entire user folder");
        }
        println!();
        environments = scan_predefined_dirs(&predefined_dirs, &config);
    }

    // Check if any environments found
    if environments.is_empty() {
        println!("No Python environments found.");
        println!();
        if !config.scan {
            println!("Tip: Try running 'spe --scan' for a comprehensive search.");
            println!();
        }
        pause();
        return;
    }

    // Print table
    print_header();
    for (i, env) in environments.iter().enumerate() {
        print_row(i + 1, &env.name, &env.env_type, &env.path);
    }
    println!();

    // Interactive menu
    loop {
        println!("Enter the number or name of the environment, or Q to quit");
        print!("> ");
        io::stdout().flush().unwrap();

        let mut input = String::new();
        io::stdin().read_line(&mut input).unwrap();
        let input = input.trim();

        if input.eq_ignore_ascii_case("q") {
            println!("Exiting...");
            return;
        }

        // Try to find by number or name
        let selected_env = find_by_input(&environments, input);

        match selected_env {
            Some(env) => {
                activate_environment(env);
                return;
            }
            None => {
                println!();
                println!("Environment \"{}\" not found.", input);
                println!();
            }
        }
    }
}

fn parse_args() -> Config {
    let args: Vec<String> = env::args().collect();
    let mut config = Config {
        help: false,
        verbose: false,
        scan: false,
        unknown_flag: None,
    };

    for arg in args.iter().skip(1) {
        match arg.as_str() {
            "-h" | "--help" | "/?" => config.help = true,
            "-v" | "--verbose" => config.verbose = true,
            "-s" | "--scan" => config.scan = true,
            _ => {
                if arg.starts_with('-') && config.unknown_flag.is_none() {
                    config.unknown_flag = Some(arg.clone());
                }
            }
        }
    }

    config
}

fn get_cache_path() -> PathBuf {
    let temp_dir = env::temp_dir();
    temp_dir.join(CACHE_FILENAME)
}

fn get_predefined_dirs() -> Vec<PathBuf> {
    let user_profile = match env::var("USERPROFILE") {
        Ok(path) => PathBuf::from(path),
        Err(_) => return Vec::new(),
    };

    vec![
        user_profile.clone(),
        user_profile.join(".venv"),
        user_profile.join("venv"),
        user_profile.join(".venvs"),
        user_profile.join("venvs"),
        user_profile.join("code"),
        user_profile.join("code").join(".venv"),
        user_profile.join("code").join("venv"),
        user_profile.join("code").join(".venvs"),
        user_profile.join("code").join("venvs"),
        user_profile.join("code").join("python"),
        user_profile.join("code").join("python").join(".venv"),
        user_profile.join("code").join("python").join("venv"),
        user_profile.join("code").join("python").join(".venvs"),
        user_profile.join("code").join("python").join("venvs"),
        user_profile.join("AppData").join("Local").join("Programs"),
        user_profile
            .join("AppData")
            .join("Local")
            .join("Programs")
            .join(".venv"),
        user_profile
            .join("AppData")
            .join("Local")
            .join("Programs")
            .join("venv"),
        user_profile
            .join("AppData")
            .join("Local")
            .join("Programs")
            .join(".venvs"),
        user_profile
            .join("AppData")
            .join("Local")
            .join("Programs")
            .join("venvs"),
        user_profile
            .join("AppData")
            .join("Local")
            .join("Programs")
            .join("Python"),
        user_profile
            .join("AppData")
            .join("Local")
            .join("Programs")
            .join("Python")
            .join(".venv"),
        user_profile
            .join("AppData")
            .join("Local")
            .join("Programs")
            .join("Python")
            .join("venv"),
        user_profile
            .join("AppData")
            .join("Local")
            .join("Programs")
            .join("Python")
            .join(".venvs"),
        user_profile
            .join("AppData")
            .join("Local")
            .join("Programs")
            .join("Python")
            .join("venvs"),
    ]
}

fn scan_predefined_dirs(dirs: &[PathBuf], config: &Config) -> Vec<Environment> {
    let mut environments = Vec::new();

    for dir in dirs {
        if !dir.exists() {
            if config.verbose {
                println!("[DEBUG] Directory not found: \"{}\"", dir.display());
            }
            continue;
        }

        if config.verbose {
            println!("[DEBUG] Checking \"{}\"", dir.display());
        }

        let entries = match fs::read_dir(dir) {
            Ok(entries) => entries,
            Err(_) => continue,
        };

        for entry in entries {
            let entry = match entry {
                Ok(e) => e,
                Err(_) => continue,
            };

            let path = entry.path();
            if !path.is_dir() {
                continue;
            }

            if let Some(env) = detect_environment_at_path(&path) {
                if config.verbose {
                    println!("[DEBUG] Added {} ({})", env.name, env.env_type);
                }
                environments.push(env);
            } else if config.verbose {
                if let Some(name) = path.file_name() {
                    println!(
                        "[DEBUG] Skipping non-python folder: {}",
                        name.to_string_lossy()
                    );
                }
            }
        }
    }

    environments
}

fn scan_all_venvs(config: &Config) -> Vec<Environment> {
    let user_profile = match env::var("USERPROFILE") {
        Ok(path) => PathBuf::from(path),
        Err(_) => {
            eprintln!("Error: Could not determine USERPROFILE");
            return Vec::new();
        }
    };

    if config.verbose {
        println!("[DEBUG] Scanning for pyvenv.cfg files in user directory...");
        println!("[DEBUG] Using parallel scanning for maximum speed...");
    } else {
        println!("Scanning...");
    }

    // Use walkdir with parallel processing for much faster scanning
    let pyvenv_files: Vec<PathBuf> = WalkDir::new(&user_profile)
        .follow_links(false)
        .into_iter()
        .filter_entry(|e| {
            // Skip excluded directories
            if let Some(name) = e.file_name().to_str() {
                let name_lower = name.to_lowercase();
                !name_lower.contains("temp")
                    && !name_lower.contains("cache")
                    && !name_lower.contains("tmp")
                    && name != "node_modules"
                    && name != "$RECYCLE.BIN"
                    && name != "System Volume Information"
            } else {
                true
            }
        })
        .filter_map(|e| e.ok())
        .filter(|e| e.file_name() == "pyvenv.cfg")
        .map(|e| e.path().to_path_buf())
        .collect();

    let scan_count = pyvenv_files.len();

    if config.verbose {
        println!(
            "[DEBUG] Found {} pyvenv.cfg files, processing...",
            scan_count
        );
    }

    // Process pyvenv.cfg files in parallel
    let environments: Vec<Environment> = pyvenv_files
        .par_iter()
        .filter_map(|cfg_path| {
            if let Some(parent) = cfg_path.parent() {
                // Skip if in excluded paths (double check)
                let path_str = parent.to_string_lossy().to_lowercase();
                if path_str.contains("\\temp\\")
                    || path_str.contains("\\cache\\")
                    || path_str.contains("\\tmp\\")
                    || path_str.contains("node_modules")
                {
                    return None;
                }

                if let Some(env) = detect_environment_at_path(parent) {
                    if config.verbose {
                        println!(
                            "[DEBUG] Found: {} ({}) at {}",
                            env.name,
                            env.env_type,
                            env.path.display()
                        );
                    }
                    return Some(env);
                }
            }
            None
        })
        .collect();

    if config.verbose {
        println!(
            "[DEBUG] Scan complete. Found {} environments.",
            environments.len()
        );
    } else {
        println!("Scan complete. Checked {} files.", scan_count);
    }

    environments
}

fn detect_environment_at_path(path: &Path) -> Option<Environment> {
    let activate_script = path.join("Scripts").join("activate.bat");
    if !activate_script.exists() {
        return None;
    }

    let name = path.file_name()?.to_string_lossy().to_string();
    let env_type = detect_env_type(path);

    Some(Environment {
        name,
        env_type,
        path: path.to_path_buf(),
    })
}

fn detect_env_type(path: &Path) -> String {
    // Check for conda
    if path.join("conda-meta").exists() {
        return "conda".to_string();
    }

    // Check for uv
    let pyvenv_cfg = path.join("pyvenv.cfg");
    if pyvenv_cfg.exists() {
        if let Ok(contents) = fs::read_to_string(&pyvenv_cfg) {
            if contents.contains("uv") {
                return "uv".to_string();
            }
        }
    }

    // Default to venv
    if path.join("Scripts").join("activate.bat").exists() {
        return "venv".to_string();
    }

    "unknown".to_string()
}

fn load_cache(cache_file: &Path, verbose: bool) -> io::Result<Vec<Environment>> {
    let file = File::open(cache_file)?;
    let reader = BufReader::new(file);
    let mut environments = Vec::new();

    for line in reader.lines() {
        let line = line?;
        let parts: Vec<&str> = line.split('|').collect();
        if parts.len() == 3 {
            environments.push(Environment {
                name: parts[0].to_string(),
                env_type: parts[1].to_string(),
                path: PathBuf::from(parts[2]),
            });
            if verbose {
                println!("[DEBUG] Loaded from cache: {} ({})", parts[0], parts[1]);
            }
        }
    }

    if verbose {
        println!(
            "[DEBUG] Loaded {} environments from cache",
            environments.len()
        );
    }

    Ok(environments)
}

fn save_cache(cache_file: &Path, environments: &[Environment], verbose: bool) -> io::Result<()> {
    if verbose {
        println!("[DEBUG] Saving cache to {}", cache_file.display());
        println!(
            "[DEBUG] Number of environments to save: {}",
            environments.len()
        );
    }

    let mut file = File::create(cache_file)?;
    for env in environments {
        writeln!(file, "{}|{}|{}", env.name, env.env_type, env.path.display())?;
        if verbose {
            println!(
                "[DEBUG] Saved: {} | {} | {}",
                env.name,
                env.env_type,
                env.path.display()
            );
        }
    }

    Ok(())
}

fn find_by_input<'a>(environments: &'a [Environment], input: &str) -> Option<&'a Environment> {
    // Try to parse as number
    if let Ok(num) = input.parse::<usize>() {
        if num > 0 && num <= environments.len() {
            return Some(&environments[num - 1]);
        }
    }

    // Try to find by name (case-insensitive)
    for env in environments {
        if env.name.eq_ignore_ascii_case(input) {
            return Some(env);
        }
    }

    None
}

fn activate_environment(env: &Environment) {
    let activate_script = env.path.join("Scripts").join("activate.bat");

    if !activate_script.exists() {
        eprintln!(
            "Error: Activation script not found at \"{}\"",
            activate_script.display()
        );
        return;
    }

    println!();
    println!("Activating \"{}\" ...", env.name);
    println!();
    println!(
        "[{} activated - Type 'deactivate' or 'exit' to close]",
        env.name
    );
    println!();

    // Launch new cmd window with environment activated
    let status = Command::new("cmd")
        .arg("/k")
        .arg(activate_script.to_string_lossy().to_string())
        .status();

    if let Err(e) = status {
        eprintln!("Error: Failed to activate environment: {}", e);
    }
}

fn print_header() {
    println!("  #   Name                 Type      Path");
    println!("  --  -------------------- --------  ----------------------------------------------");
}

fn print_row(num: usize, name: &str, env_type: &str, path: &Path) {
    let name_padded = format!("{:20}", name);
    let type_padded = format!("{:8}", env_type);
    println!(
        "  {}.  {}  {}  {}",
        num,
        name_padded,
        type_padded,
        path.display()
    );
}

fn pause() {
    println!("Press Enter to continue...");
    let mut input = String::new();
    io::stdin().read_line(&mut input).unwrap();
}

fn show_help() {
    println!();
    println!("SPE - Search Python Environment");
    println!("================================");
    println!();
    println!("DESCRIPTION:");
    println!("  Interactively search and activate Python virtual environments.");
    println!("  Scans predefined directories for venv, conda, and uv environments.");
    println!();
    println!("USAGE:");
    println!("  spe [OPTIONS]");
    println!();
    println!("OPTIONS:");
    println!("  -h, --help       Show this help message and exit");
    println!("  -v, --verbose    Enable verbose output (shows debug information)");
    println!("  -s, --scan       Perform comprehensive scan and update cache");
    println!();
    println!("BEHAVIOR:");
    println!("  By default, searches predefined directories quickly. Uses cached results");
    println!("  if available. With --scan, performs a comprehensive search of your entire");
    println!("  user folder for virtual environments and updates the persistent cache.");
    println!();
    println!("  You can select an environment by number or by typing its name.");
    println!();
    println!("SEARCHED DIRECTORIES:");
    println!("  - %USERPROFILE%");
    println!("  - %USERPROFILE%\\.venv, \\venv, \\.venvs, \\venvs");
    println!("  - %USERPROFILE%\\code (and its .venv, venv, .venvs, venvs subdirs)");
    println!("  - %USERPROFILE%\\code\\python (and its .venv, venv, .venvs, venvs subdirs)");
    println!(
        "  - %USERPROFILE%\\AppData\\Local\\Programs (and its .venv, venv, .venvs, venvs subdirs)"
    );
    println!("  - %USERPROFILE%\\AppData\\Local\\Programs\\Python (and its .venv, venv, .venvs, venvs subdirs)");
    println!();
    println!("SUPPORTED ENVIRONMENT TYPES:");
    println!("  - venv   : Standard Python virtual environments");
    println!("  - conda  : Anaconda/Miniconda environments");
    println!("  - uv     : UV-created virtual environments");
    println!();
    println!("EXAMPLES:");
    println!("  spe              List and activate an environment (uses cache if exists)");
    println!("  spe -s           Scan entire user folder and update cache");
    println!("  spe --scan       Scan entire user folder and update cache (same as -s)");
    println!("  spe -v           List environments with debug output");
    println!("  spe -s -v        Scan with verbose output");
    println!("  spe --help       Show this help message");
    println!();
    println!("CACHE:");
    println!("  - Cache location: %TEMP%\\python_venv_cache.txt");
    println!("  - Run with --scan after creating new venvs to update cache");
    println!("  - Delete cache file to force fresh scan on next run");
    println!("  - Cache persists until manually deleted");
    println!();
    println!("NOTES:");
    println!("  - Type 'deactivate' or 'exit' in the activated environment to return to normal");
    println!("  - Type 'Q' at the selection prompt to quit without activating");
    println!("  - First run without cache uses predefined directories (fast)");
    println!();
}
