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
    env_name: Option<String>,
    unknown_flag: Option<String>,
}

fn main() {
    let config = parse_args();

    // Check for unknown flags
    if let Some(flag) = &config.unknown_flag {
        eprintln!();
        eprintln!("Warning: Unknown flag \"{}\"", flag);
        eprintln!("Run 'ape --help' for usage information.");
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

    // Handle scan mode
    if config.scan {
        println!("Performing comprehensive scan...");
        println!("This may take a moment...");
        println!();

        let environments = scan_all_venvs(&config);
        println!("Found {} environments.", environments.len());

        if let Err(e) = save_cache(&cache_file, &environments, config.verbose) {
            eprintln!("Warning: Failed to save cache: {}", e);
        } else {
            println!("Cache updated.");
        }
        println!();

        // If no environment name provided, just show results
        if config.env_name.is_none() {
            if !environments.is_empty() {
                println!();
                println!("Found environments:");
                println!();
                print_scan_results(&environments);
                println!();
            }
            println!("Run 'ape <env_name>' to activate an environment.");
            return;
        }
    }

    // Check if environment name provided
    let env_name = match &config.env_name {
        Some(name) => name,
        None => {
            eprintln!("Error: No environment name specified.");
            eprintln!();
            eprintln!("Usage: ape [OPTIONS] <env_name>");
            eprintln!("       ape --help for more information");
            return;
        }
    };

    if config.verbose {
        println!("[DEBUG] Searching for environment: {}", env_name);
        println!();
    }

    // Try to find the environment
    let found_env = find_environment(env_name, &cache_file, &predefined_dirs, &config);

    match found_env {
        Some(env) => activate_environment(&env, &config),
        None => {
            eprintln!("Error: Environment \"{}\" not found.", env_name);
            eprintln!();
            if cache_file.exists() {
                eprintln!(
                    "Tip: Try running 'ape --scan' to update the cache and find new environments."
                );
            } else {
                eprintln!("Tip: Try running 'ape --scan' to perform a comprehensive search.");
            }
            eprintln!("     Or use 'spe' to see all available environments.");
        }
    }
}

fn parse_args() -> Config {
    let args: Vec<String> = env::args().collect();
    let mut config = Config {
        help: false,
        verbose: false,
        scan: false,
        env_name: None,
        unknown_flag: None,
    };

    let mut i = 1; // Skip program name
    let mut env_arg_candidates: Vec<String> = Vec::new();

    while i < args.len() {
        let arg = &args[i];
        match arg.as_str() {
            "-h" | "--help" | "/?" => config.help = true,
            "-v" | "--verbose" => config.verbose = true,
            "-s" | "--scan" => config.scan = true,
            _ => {
                if arg.starts_with('-') {
                    // Unknown flag
                    if config.unknown_flag.is_none() {
                        config.unknown_flag = Some(arg.clone());
                    }
                } else {
                    // Potential environment name
                    env_arg_candidates.push(arg.clone());
                }
            }
        }
        i += 1;
    }

    // The environment name is the first non-flag argument
    if !env_arg_candidates.is_empty() {
        config.env_name = Some(env_arg_candidates[0].clone());
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
    if verbose {
        println!("[DEBUG] Checking cache...");
    }

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

fn find_environment(
    env_name: &str,
    cache_file: &Path,
    predefined_dirs: &[PathBuf],
    config: &Config,
) -> Option<Environment> {
    // Try cache first
    if cache_file.exists() {
        if config.verbose {
            println!("[DEBUG] Checking cache...");
        }
        if let Ok(environments) = load_cache(cache_file, config.verbose) {
            for env in environments {
                if env.name.eq_ignore_ascii_case(env_name) {
                    let activate_script = env.path.join("Scripts").join("activate.bat");
                    if activate_script.exists() {
                        if config.verbose {
                            println!(
                                "[DEBUG] Found in cache: {} ({}) at {}",
                                env.name,
                                env.env_type,
                                env.path.display()
                            );
                        }
                        return Some(env);
                    } else if config.verbose {
                        println!("[DEBUG] Cached path no longer valid, searching directories...");
                    }
                }
            }
        }
    }

    // Search predefined directories
    if config.verbose {
        println!("[DEBUG] Searching predefined directories...");
    }

    for dir in predefined_dirs {
        if !dir.exists() {
            if config.verbose {
                println!("[DEBUG] Directory not found: \"{}\"", dir.display());
            }
            continue;
        }

        if config.verbose {
            println!("[DEBUG] Checking \"{}\"", dir.display());
        }

        let env_dir = dir.join(env_name);
        if env_dir.exists() {
            if let Some(env) = detect_environment_at_path(&env_dir) {
                if config.verbose {
                    println!(
                        "[DEBUG] Found {} environment at: {}",
                        env.env_type,
                        env_dir.display()
                    );
                }
                return Some(env);
            }
        }
    }

    None
}

fn activate_environment(env: &Environment, config: &Config) {
    let activate_script = env.path.join("Scripts").join("activate.bat");

    if !activate_script.exists() {
        eprintln!(
            "Error: Activation script not found at \"{}\"",
            activate_script.display()
        );
        return;
    }

    if config.verbose {
        println!("[DEBUG] Activating: {}", env.path.display());
        println!("[DEBUG] Type: {}", env.env_type);
        println!("[DEBUG] Activation script: {}", activate_script.display());
        println!();
    }

    println!("Activating \"{}\" ({})...", env.name, env.env_type);
    println!();
    println!(
        "[{} activated - Type 'deactivate' or 'exit' to exit or close the window]",
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

fn print_scan_results(environments: &[Environment]) {
    for (i, env) in environments.iter().enumerate() {
        println!("  {}. {} ({})", i + 1, env.name, env.env_type);
        println!("     {}", env.path.display());
        println!();
    }
}

fn show_help() {
    println!();
    println!("APE - Activate Python Environment");
    println!("==================================");
    println!();
    println!("DESCRIPTION:");
    println!("  Quickly activate a Python virtual environment by name.");
    println!("  Searches predefined directories for the specified environment.");
    println!();
    println!("USAGE:");
    println!("  ape [OPTIONS] <env_name>");
    println!("  ape --scan [OPTIONS]");
    println!();
    println!("ARGUMENTS:");
    println!("  env_name         Name of the environment to activate");
    println!();
    println!("OPTIONS:");
    println!("  -h, --help       Show this help message and exit");
    println!("  -v, --verbose    Enable verbose output (shows debug information)");
    println!("  -s, --scan       Perform comprehensive scan and update cache");
    println!();
    println!("BEHAVIOR:");
    println!("  Searches for the specified environment using cached results (if available),");
    println!("  or searches predefined directories. With --scan, performs a comprehensive");
    println!("  search of your entire user folder and updates the persistent cache.");
    println!();
    println!("  Opens a new command prompt with the environment activated. The environment");
    println!("  stays active until you close the window or type 'deactivate' or 'exit'.");
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
    println!("  ape myenv              Activate environment named 'myenv'");
    println!("  ape -s                 Scan entire user folder and update cache");
    println!("  ape --scan             Scan entire user folder and update cache (same as -s)");
    println!("  ape -s myenv           Scan and then activate 'myenv'");
    println!("  ape -v finance         Activate 'finance' with debug output");
    println!("  ape --help             Show this help message");
    println!();
    println!("CACHE:");
    println!("  - Cache location: %TEMP%\\python_venv_cache.txt");
    println!("  - Run 'ape --scan' after creating new venvs to update cache");
    println!("  - Delete cache file to force directory search");
    println!("  - Cache persists until manually deleted");
    println!();
    println!("NOTES:");
    println!("  - Type 'deactivate' then 'exit' to close the activated shell");
    println!("  - Use 'spe' to interactively browse all available environments");
    println!("  - First time use: Run 'ape --scan' to build the cache for faster searches");
    println!("  - Both 'ape' and 'spe' open new shells with the environment activated");
    println!();
}
