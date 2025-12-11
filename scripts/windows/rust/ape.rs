use colored::*;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::env;
use std::fs::{self};
use std::io::{self};
use std::path::{Path, PathBuf};
use std::process::Command;
use walkdir::WalkDir;

const CACHE_FILENAME: &str = "python_venv_cache.json";
const CONFIG_FILENAME: &str = "python_venv_config.toml";

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Environment {
    name: String,
    env_type: String,
    path: PathBuf,
}

#[derive(Debug, Deserialize)]
struct UserConfig {
    directories: Option<Vec<String>>,
}

struct Config {
    help: bool,
    verbose: bool,
    scan: bool,
    clean: bool,
    no_color: bool,
    env_name: Option<String>,
    unknown_flag: Option<String>,
}

fn main() {
    let config = parse_args();

    // Check for unknown flags
    if let Some(flag) = &config.unknown_flag {
        eprintln!();
        print_warning(&format!("Unknown flag \"{}\"", flag), config.no_color);
        eprintln!("Run 'ape --help' for usage information.");
        eprintln!();
        return;
    }

    // Show help
    if config.help {
        show_help();
        return;
    }

    // Handle clean mode
    if config.clean {
        let cache_file = get_cache_path();
        print_info("Removing cache file...", config.no_color);
        if cache_file.exists() {
            match fs::remove_file(&cache_file) {
                Ok(_) => {
                    print_success(
                        &format!("Cache file removed successfully: {}", cache_file.display()),
                        config.no_color,
                    );
                }
                Err(e) => {
                    print_error(
                        &format!(
                            "Failed to remove cache file at {}: {}",
                            cache_file.display(),
                            e
                        ),
                        config.no_color,
                    );
                }
            }
        } else {
            print_info(
                &format!("Cache file does not exist: {}", cache_file.display()),
                config.no_color,
            );
        }
        println!();
        return;
    }

    let cache_file = get_cache_path();
    let predefined_dirs = get_search_dirs();

    if config.verbose {
        print_debug("Verbose mode enabled.", config.no_color);
        print_debug("Directories to be scanned:", config.no_color);
        for dir in &predefined_dirs {
            println!("  {}", dir.display());
        }
        println!();
    }

    // Handle scan mode
    if config.scan {
        print_info("Performing comprehensive scan...", config.no_color);
        print_info("This may take a moment...", config.no_color);
        println!();

        let environments = scan_all_venvs(&config);
        print_success(
            &format!("Found {} environments.", environments.len()),
            config.no_color,
        );

        if let Err(e) = save_cache(&cache_file, &environments, &config) {
            print_warning(&format!("Failed to save cache: {}", e), config.no_color);
        } else {
            print_success("Cache updated.", config.no_color);
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
            print_error("No environment name specified.", config.no_color);
            eprintln!();
            eprintln!("Usage: ape [OPTIONS] <env_name>");
            eprintln!("       ape --help for more information");
            return;
        }
    };

    if config.verbose {
        print_debug(
            &format!("Searching for environment: {}", env_name),
            config.no_color,
        );
        println!();
    }

    // Try to find the environment
    let found_env = find_environment(env_name, &cache_file, &predefined_dirs, &config);

    match found_env {
        Some(env) => activate_environment(&env, &config),
        None => {
            print_error(
                &format!("Environment \"{}\" not found.", env_name),
                config.no_color,
            );
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
        clean: false,
        no_color: false,
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
            "-c" | "--clean" => config.clean = true,
            "--no-color" => config.no_color = true,
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

fn get_config_path() -> PathBuf {
    let user_profile = env::var("USERPROFILE").unwrap_or_else(|_| String::from("."));
    PathBuf::from(user_profile)
        .join(".config")
        .join(CONFIG_FILENAME)
}

fn load_user_config() -> Option<UserConfig> {
    let config_path = get_config_path();
    if !config_path.exists() {
        return None;
    }

    match fs::read_to_string(&config_path) {
        Ok(contents) => match toml::from_str(&contents) {
            Ok(config) => Some(config),
            Err(_) => None,
        },
        Err(_) => None,
    }
}

fn get_search_dirs() -> Vec<PathBuf> {
    // First, try to load custom directories from config file
    if let Some(user_config) = load_user_config() {
        if let Some(dirs) = user_config.directories {
            let custom_dirs: Vec<PathBuf> = dirs
                .iter()
                .map(|d| {
                    let expanded = d.replace(
                        "%USERPROFILE%",
                        &env::var("USERPROFILE").unwrap_or_default(),
                    );
                    PathBuf::from(expanded)
                })
                .collect();

            if !custom_dirs.is_empty() {
                return custom_dirs;
            }
        }
    }

    // Fall back to predefined directories
    get_predefined_dirs()
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
        print_debug(
            "Scanning for pyvenv.cfg files in user directory...",
            config.no_color,
        );
        print_debug(
            "Using parallel scanning for maximum speed...",
            config.no_color,
        );
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
        print_debug(
            &format!("Found {} pyvenv.cfg files, processing...", scan_count),
            config.no_color,
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
                        print_debug(
                            &format!(
                                "Found: {} ({}) at {}",
                                env.name,
                                env.env_type,
                                env.path.display()
                            ),
                            config.no_color,
                        );
                    }
                    return Some(env);
                }
            }
            None
        })
        .collect();

    if config.verbose {
        print_debug(
            &format!("Scan complete. Found {} environments.", environments.len()),
            config.no_color,
        );
    } else {
        print_info(
            &format!("Scan complete. Checked {} files.", scan_count),
            config.no_color,
        );
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

fn load_cache(cache_file: &Path, config: &Config) -> io::Result<Vec<Environment>> {
    if config.verbose {
        print_debug("Loading cache...", config.no_color);
    }

    let contents = fs::read_to_string(cache_file)?;
    let environments: Vec<Environment> = serde_json::from_str(&contents)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

    if config.verbose {
        print_debug(
            &format!("Loaded {} environments from cache", environments.len()),
            config.no_color,
        );
    }

    Ok(environments)
}

fn save_cache(cache_file: &Path, environments: &[Environment], config: &Config) -> io::Result<()> {
    if config.verbose {
        print_debug(
            &format!("Saving cache to {}", cache_file.display()),
            config.no_color,
        );
        print_debug(
            &format!("Number of environments to save: {}", environments.len()),
            config.no_color,
        );
    }

    let json = serde_json::to_string_pretty(environments)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

    fs::write(cache_file, json)?;

    if config.verbose {
        print_debug("Cache saved successfully", config.no_color);
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
            print_debug("Checking cache...", config.no_color);
        }
        if let Ok(environments) = load_cache(cache_file, config) {
            for env in environments {
                if env.name.eq_ignore_ascii_case(env_name) {
                    let activate_script = env.path.join("Scripts").join("activate.bat");
                    if activate_script.exists() {
                        if config.verbose {
                            print_debug(
                                &format!(
                                    "Found in cache: {} ({}) at {}",
                                    env.name,
                                    env.env_type,
                                    env.path.display()
                                ),
                                config.no_color,
                            );
                        }
                        return Some(env);
                    } else if config.verbose {
                        print_debug(
                            "Cached path no longer valid, searching directories...",
                            config.no_color,
                        );
                    }
                }
            }
        }
    }

    // Search predefined directories
    if config.verbose {
        print_debug("Searching predefined directories...", config.no_color);
    }

    for dir in predefined_dirs {
        if !dir.exists() {
            if config.verbose {
                print_debug(
                    &format!("Directory not found: \"{}\"", dir.display()),
                    config.no_color,
                );
            }
            continue;
        }

        if config.verbose {
            print_debug(&format!("Checking \"{}\"", dir.display()), config.no_color);
        }

        let env_dir = dir.join(env_name);
        if env_dir.exists() {
            if let Some(env) = detect_environment_at_path(&env_dir) {
                if config.verbose {
                    print_debug(
                        &format!(
                            "Found {} environment at: {}",
                            env.env_type,
                            env_dir.display()
                        ),
                        config.no_color,
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
        print_error(
            &format!(
                "Activation script not found at \"{}\"",
                activate_script.display()
            ),
            config.no_color,
        );
        return;
    }

    if config.verbose {
        print_debug(
            &format!("Activating: {}", env.path.display()),
            config.no_color,
        );
        print_debug(&format!("Type: {}", env.env_type), config.no_color);
        print_debug(
            &format!("Activation script: {}", activate_script.display()),
            config.no_color,
        );
        println!();
    }

    print_success(
        &format!("Activating \"{}\" ({})...", env.name, env.env_type),
        config.no_color,
    );
    println!();
    print_info(
        &format!(
            "[{} activated - Type 'deactivate' or 'exit' to exit or close the window]",
            env.name
        ),
        config.no_color,
    );
    println!();

    // Launch new cmd window with environment activated
    let status = Command::new("cmd")
        .arg("/k")
        .arg(activate_script.to_string_lossy().to_string())
        .status();

    if let Err(e) = status {
        print_error(
            &format!("Failed to activate environment: {}", e),
            config.no_color,
        );
    }
}

fn print_scan_results(environments: &[Environment]) {
    for (i, env) in environments.iter().enumerate() {
        println!("  {}. {} ({})", i + 1, env.name, env.env_type);
        println!("     {}", env.path.display());
        println!();
    }
}

fn print_error(msg: &str, no_color: bool) {
    if no_color {
        eprintln!("Error: {}", msg);
    } else {
        eprintln!("{} {}", "Error:".red().bold(), msg);
    }
}

fn print_warning(msg: &str, no_color: bool) {
    if no_color {
        eprintln!("Warning: {}", msg);
    } else {
        eprintln!("{} {}", "Warning:".yellow().bold(), msg);
    }
}

fn print_success(msg: &str, no_color: bool) {
    if no_color {
        println!("{}", msg);
    } else {
        println!("{}", msg.green());
    }
}

fn print_info(msg: &str, no_color: bool) {
    if no_color {
        println!("{}", msg);
    } else {
        println!("{}", msg.cyan());
    }
}

fn print_debug(msg: &str, no_color: bool) {
    if no_color {
        println!("[DEBUG] {}", msg);
    } else {
        println!("{}", format!("[DEBUG] {}", msg).dimmed());
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
    println!("  -c, --clean      Remove the cache file and exit");
    println!("  --no-color       Disable colored output");
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
    println!(
        "  - %USERPROFILE%\\AppData\\Local\\Programs\\Python (and its .venv, venv, .venvs, venvs subdirs)"
    );
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
    println!("  ape -c                 Remove the cache file");
    println!("  ape --clean            Remove the cache file (same as -c)");
    println!("  ape --help             Show this help message");
    println!();
    println!("CACHE:");
    println!("  - Cache location: %TEMP%\\python_venv_cache.json");
    println!("  - Run 'ape --scan' after creating new venvs to update cache");
    println!("  - Delete cache file to force directory search");
    println!("  - Cache persists until manually deleted");
    println!();
    println!("CUSTOM DIRECTORIES:");
    println!("  Create a config file at: %USERPROFILE%\\.config\\python_venv_config.toml");
    println!();
    println!("  Example config:");
    println!("  directories = [");
    println!("      \"%USERPROFILE%\\\\projects\",");
    println!("      \"C:\\\\dev\\\\python\",");
    println!("      \"%USERPROFILE%\\\\code\\\\.venvs\"");
    println!("  ]");
    println!();
    println!("NOTES:");
    println!("  - Type 'deactivate' then 'exit' to close the activated shell");
    println!("  - Use 'spe' to interactively browse all available environments");
    println!("  - First time use: Run 'ape --scan' to build the cache for faster searches");
    println!("  - Both 'ape' and 'spe' open new shells with the environment activated");
    println!();
}
