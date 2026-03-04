#!/bin/bash

# Project Task Script
# Replaces Phing ProjectTask.php functionality

set -e
export LC_ALL=C

# Default variables
ROOT_DIR=""
ACTION=""
NAME=""
VERSION=""
DEV_VERSION=""
DATE=""
ENV_FILE=""
PROJECT_NPM=""
PROJECT_NPM_DIR="build"

# Exclusion patterns for files
FILES_EXCLUDES=(
    ".idea"
    ".git"
    ".packages"
    ".build"
    "node_modules"
    "vendor"
    ".gitignore"
    "LICENSE"
    "*.md"
    ".DS_Store"
)

# Exclusion patterns for packages
PACKAGE_EXCLUDES=(
    ".idea"
    ".git"
    ".packages"
    ".build"
    "node_modules"
    "vendor"
    "build"
    ".gitignore"
    "LICENSE"
    "*.md"
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Step formatting
STEP_DOTS_WIDTH=28

# Print aligned step prefix like: "Replace version .............. "
print_step_prefix() {
    local label="$1"
    local dots_count=$((STEP_DOTS_WIDTH - ${#label}))
    local dots

    if (( dots_count < 3 )); then
        dots_count=3
    fi

    dots=$(printf '%*s' "$dots_count" '')
    dots=${dots// /.}

    printf "%s %s " "$label" "$dots"
}

# Normalize path passed via --env from IDE macros/quotes.
# Examples:
#   --env=/path/build.env
#   --env='/path/build.env'
#   --env="/path/build.env"
normalize_env_path() {
    local value="$1"

    # Trim one pair of matching wrapping quotes.
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value="${value#\"}"
        value="${value%\"}"
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value="${value#\'}"
        value="${value%\'}"
    fi

    # Be tolerant to accidental single trailing quote from IDE args.
    value="${value%\"}"
    value="${value%\'}"

    echo "$value"
}

# Load environment variables from explicitly provided --env file
load_env() {
    local env_path=""

    if [[ -z "$ENV_FILE" ]]; then
        echo -e "${RED}Error: --env is required and must point to the file you launched${NC}"
        exit 1
    fi

    if [[ "$ENV_FILE" == /* ]]; then
        env_path="$ENV_FILE"
    else
        env_path="$PWD/$ENV_FILE"
    fi

    if [[ ! -f "$env_path" ]]; then
        echo -e "${RED}Error: env file not found at: $env_path${NC}"
        exit 1
    fi

    echo -e "${GREEN}Found env file:${NC} $env_path"
    echo -e "${GREEN}Env directory:${NC} $(dirname "$env_path")"
    echo

    # Read .env file
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines
        [[ -z "$line" ]] && continue

        # Skip comments
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Skip lines without =
        [[ ! "$line" =~ = ]] && continue

        # Split key and value
        key="${line%%=*}"
        value="${line#*=}"

        # Remove quotes from value
        value="${value%\"}"
        value="${value#\"}"
        value="${value%\'}"
        value="${value#\'}"

        # Trim whitespace
        key=$(echo "$key" | xargs 2>/dev/null || echo "$key")
        value=$(echo "$value" | xargs 2>/dev/null || echo "$value")

        case "$key" in
            PROJECT_NAME|NAME)
                NAME="$value"
                ;;
            PROJECT_VERSION|VERSION)
                VERSION="$value"
                set_version "$VERSION"
                ;;
            PROJECT_NPM|NPM_SCRIPT)
                PROJECT_NPM="$value"
                ;;
            PROJECT_NPM_DIR|NPM_DIR)
                PROJECT_NPM_DIR="$value"
                ;;
        esac
    done < "$env_path"

    if [[ -z "$NAME" ]]; then
        echo -e "${RED}Error: PROJECT_NAME or NAME not found in .env${NC}"
        exit 1
    fi

    if [[ -z "$VERSION" ]]; then
        echo -e "${RED}Error: PROJECT_VERSION or VERSION not found in .env${NC}"
        exit 1
    fi
}

# Print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    --action=ACTION         Action to perform (info|prepareRelease|packageRelease|resetSince|prepareDev|normalizeLangFileNames|packageDev)
    --env=PATH             Path to params file (required)
    --name=NAME            Project name (overrides .env)
    --version=VERSION      Version number (overrides .env)
    --root=PATH            Root directory (overrides .env location)
    -h, --help             Show this help message

Env file format:
    PROJECT_NAME=MyProject
    PROJECT_VERSION=1.2.3

Examples:
    # Specify env file location (required)
    $0 --action=prepareRelease --env=/path/to/project/build.env

    # Override .env values
    $0 --action=info --name=MyProject --version=1.2.3
EOF
    exit 1
}

# Parse command line arguments
parse_args() {
    local override_name=""
    local override_version=""
    local override_root=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --action=*)
                ACTION="${1#*=}"
                shift
                ;;
            --env=*)
                ENV_FILE=$(normalize_env_path "${1#*=}")
                shift
                ;;
            --name=*)
                override_name="${1#*=}"
                shift
                ;;
            --version=*)
                override_version="${1#*=}"
                shift
                ;;
            --root=*)
                override_root="${1#*=}"
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo "Unknown option: $1"
                usage
                ;;
        esac
    done

    if [[ -z "$ACTION" ]]; then
        echo "Error: --action is required"
        usage
    fi

    # Read only explicitly passed env file
    load_env

    # Default project root is current working directory (PhpStorm Working directory).
    ROOT_DIR="$PWD"

    # Override with command line parameters if provided
    if [[ -n "$override_name" ]]; then
        NAME="$override_name"
    fi
    if [[ -n "$override_version" ]]; then
        VERSION="$override_version"
        set_version "$VERSION"
    fi
    if [[ -n "$override_root" ]]; then
        ROOT_DIR="$override_root"
    fi

    return 0
}

# Set version and calculate dev version
set_version() {
    local ver="$1"
    VERSION="$ver"

    # Calculate dev version (increment last number and add -dev)
    IFS='.' read -ra VER_PARTS <<< "$ver"
    local last_idx=$((${#VER_PARTS[@]} - 1))
    VER_PARTS[$last_idx]=$((${VER_PARTS[$last_idx]} + 1))
    DEV_VERSION="${VER_PARTS[*]}-dev"
    DEV_VERSION="${DEV_VERSION// /.}"

    # Set date
    DATE=$(LC_TIME=C date '+%B %Y')
}

# Get package name
get_package_name() {
    local dev=$1
    local version="$VERSION"
    [[ "$dev" == "true" ]] && version="$DEV_VERSION"
    echo "${NAME}_${version}.zip"
}

# Print project info
action_info() {
    cat << EOF
==== Project Info ===
Name               $NAME
Date               $DATE
[RELEASE] Version  $VERSION
[RELEASE] Package  $(get_package_name false)
[DEV] Version      $DEV_VERSION
[DEV] Package      $(get_package_name true)
Base Directory     $(realpath "$ROOT_DIR")
EOF
}

# Check if file should be excluded
should_exclude() {
    local file="$1"
    local excludes=("${@:2}")
    local base_name
    base_name=$(basename "$file")
    # shellcheck disable=SC2053
    for pattern in "${excludes[@]}"; do
        if [[ "$pattern" == *"*"* ]] || [[ "$pattern" == *"?"* ]] || [[ "$pattern" == *"["* ]]; then
            [[ "$file" == $pattern ]] && return 0
            [[ "$base_name" == $pattern ]] && return 0
        else
            [[ "$file" == *"$pattern"* ]] && return 0
        fi
    done
    return 1
}

# Get all files respecting exclusions
build_prune_dirs() {
    local excludes=("$@")
    local pattern

    for pattern in "${excludes[@]}"; do
        # Only plain names are safe to use with find -name for directory pruning.
        if [[ "$pattern" == *"*"* ]] || [[ "$pattern" == *"?"* ]] || [[ "$pattern" == *"["* ]]; then
            continue
        fi
        if [[ "$pattern" == *"/"* ]]; then
            continue
        fi
        printf '%s\n' "$pattern"
    done
}

get_files() {
    local dir="$1"
    shift
    local excludes=("$@")
    local files=()
    local prune_dirs=()
    local find_args=("$dir")
    local i

    while IFS= read -r prune_dir; do
        [[ -n "$prune_dir" ]] && prune_dirs+=("$prune_dir")
    done < <(build_prune_dirs "${excludes[@]}")

    if (( ${#prune_dirs[@]} > 0 )); then
        find_args+=("(" "-type" "d" "(")
        for i in "${!prune_dirs[@]}"; do
            if (( i > 0 )); then
                find_args+=("-o")
            fi
            find_args+=("-name" "${prune_dirs[$i]}")
        done
        find_args+=(")" "-prune" ")" "-o")
    fi
    find_args+=("-type" "f" "-print0")

    while IFS= read -r -d '' file; do
        local rel_path="${file#$dir/}"
        if ! should_exclude "$rel_path" "${excludes[@]}"; then
            files+=("$rel_path")
        fi
    done < <(find "${find_args[@]}" 2>/dev/null)

    printf '%s\n' "${files[@]}"
}

# Replace version in files
replace_version() {
    local version="$1"
    local dev=false
    [[ "$version" == "$DEV_VERSION" ]] && dev=true

    local doc_version="$version"
    local deploy_version="$version"
    [[ "$dev" == true ]] && doc_version="__DEPLOY_VERSION__" && deploy_version="__DEPLOY_VERSION__"

    print_step_prefix "Replace version"

    local count=0
    while IFS= read -r file; do
        local filepath="$ROOT_DIR/$file"
        [[ ! -f "$filepath" ]] && continue
        LC_ALL=C grep -Iq . "$filepath" || continue

        local original
        original=$(cat "$filepath")
        local replace="$original"

        # Replace @version
        replace=$(echo "$replace" | sed -E "s/@version([[:space:]]*).*/@version\1$doc_version/g")
        # Replace <version>
        replace=$(echo "$replace" | sed -E "s/<version>.*<\/version>/<version>$version<\/version>/g")
        # Replace * Version:
        replace=$(echo "$replace" | sed -E "s/\* ?Version:([[:space:]]*).*/\* Version:\1$version/g")
        # Replace __DEPLOY_VERSION__
        replace="${replace//__DEPLOY_VERSION__/$deploy_version}"

        # Handle JSON files
        if [[ "$file" == *.json ]]; then
            replace=$(echo "$replace" | sed -E "s/\"version\": \"[^\"]*\"/\"version\": \"$version\"/g")
        fi

        if [[ "$original" != "$replace" ]]; then
            echo "$replace" > "$filepath"
            ((count++))
        fi
    done < <(get_files "$ROOT_DIR" "${FILES_EXCLUDES[@]}")

    [[ $count -gt 0 ]] && echo -e "${GREEN}OK${NC} ($count files)" || echo -e "${GREEN}OK${NC}"
}

# Replace date in files
replace_date() {
    print_step_prefix "Replace date"

    local count=0
    while IFS= read -r file; do
        local filepath="$ROOT_DIR/$file"
        [[ ! -f "$filepath" ]] && continue
        LC_ALL=C grep -Iq . "$filepath" || continue

        local original
        original=$(cat "$filepath")
        local replace="$original"

        # Replace @date
        replace=$(echo "$replace" | sed -E "s/@date([[:space:]]*).*/@date\1$DATE/g")
        # Replace <date>
        replace=$(echo "$replace" | sed -E "s/<date>.*<\/date>/<date>$DATE<\/date>/g")
        # Replace <creationDate>
        replace=$(echo "$replace" | sed -E "s/<creationDate>.*<\/creationDate>/<creationDate>$DATE<\/creationDate>/g")
        # Replace __DEPLOY_DATE__
        replace="${replace//__DEPLOY_DATE__/$DATE}"

        if [[ "$original" != "$replace" ]]; then
            echo "$replace" > "$filepath"
            ((count++))
        fi
    done < <(get_files "$ROOT_DIR" "${FILES_EXCLUDES[@]}")

    [[ $count -gt 0 ]] && echo -e "${GREEN}OK${NC} ($count files)" || echo -e "${GREEN}OK${NC}"
}

# Prepare release
action_prepare_release() {
    echo "==== Prepare $NAME $VERSION Release ==="
    run_npm_prepare_release
    replace_version "$VERSION"
    replace_date
}

run_npm_prepare_release() {
    [[ -z "$PROJECT_NPM" ]] && return 0

    local npm_dir
    local npm_dir_input="${PROJECT_NPM_DIR:-build}"
    local scripts_raw
    local scripts=()
    local script
    local npm_log

    if [[ "$npm_dir_input" == /* ]]; then
        npm_dir="$npm_dir_input"
    else
        npm_dir="$ROOT_DIR/$npm_dir_input"
    fi

    scripts_raw="${PROJECT_NPM//,/ }"
    scripts_raw="${scripts_raw//;/ }"
    for script in $scripts_raw; do
        [[ -n "$script" ]] && scripts+=("$script")
    done

    if (( ${#scripts[@]} == 0 )); then
        print_step_prefix "Run npm scripts"
        echo -e "${RED}ERROR${NC} (PROJECT_NPM is empty)"
        exit 1
    fi

    if [[ ! -f "$npm_dir/package.json" ]]; then
        print_step_prefix "Run npm scripts"
        echo -e "${RED}ERROR${NC} (package.json not found in $npm_dir)"
        exit 1
    fi

    if ! command -v npm >/dev/null 2>&1; then
        print_step_prefix "Run npm scripts"
        echo -e "${RED}ERROR${NC} (npm command not found)"
        exit 1
    fi

    print_step_prefix "Run npm scripts"
    for script in "${scripts[@]}"; do
        npm_log=$(mktemp)
        if (cd "$npm_dir" && npm run "$script" >"$npm_log" 2>&1); then
            rm -f "$npm_log"
            continue
        fi

        echo -e "${RED}ERROR${NC}"
        echo "NPM script failed: $script"
        echo "NPM directory: $npm_dir"
        echo "Log file: $npm_log"
        sed -n '1,120p' "$npm_log"
        exit 1
    done

    echo -e "${GREEN}OK${NC} (${#scripts[@]} scripts)"
}

# Create package
create_package() {
    local package_name="$1"
    local package_dir="$ROOT_DIR/.packages"
    local package_path="$package_dir/$package_name"

    mkdir -p "$package_dir"

    # Remove existing package
    [[ -f "$package_path" ]] && rm -f "$package_path"

    print_step_prefix "Create package"

    # Create temporary directory for package
    local temp_dir
    temp_dir=$(mktemp -d)


    # Copy files to temp directory
    while IFS= read -r file; do
        local filepath="$ROOT_DIR/$file"
        [[ ! -f "$filepath" ]] && continue

        local target_dir
         target_dir="$temp_dir/$(dirname "$file")"

        mkdir -p "$target_dir"
        cp "$filepath" "$temp_dir/$file"
    done < <(get_files "$ROOT_DIR" "${PACKAGE_EXCLUDES[@]}")

    # Create zip
    (cd "$temp_dir" && zip -r -q "$package_path" . 2>/dev/null)
    local result=$?

    # Cleanup
    rm -rf "$temp_dir"

    [[ $result -eq 0 ]] && echo -e "${GREEN}OK${NC}" || echo -e "${RED}ERROR${NC}"
    return $result
}

# Package release
action_package_release() {
    echo "==== Package $NAME $VERSION Release ==="
    create_package "$(get_package_name false)"
}

# Reset @since tags
action_reset_since() {
    echo "==== Reset @since to  __DEPLOY_VERSION__ ==="
    print_step_prefix "Replace since"

    local count=0
    while IFS= read -r file; do
        local filepath="$ROOT_DIR/$file"
        [[ ! -f "$filepath" ]] && continue
        LC_ALL=C grep -Iq . "$filepath" || continue

        local original
        original=$(cat "$filepath")
        local replace
        replace=$(echo "$original" | sed -E "s/@since([[:space:]]*).*/@since\1__DEPLOY_VERSION__/g")

        if [[ "$original" != "$replace" ]]; then
            echo "$replace" > "$filepath"
            ((count++))
        fi
    done < <(get_files "$ROOT_DIR" "${FILES_EXCLUDES[@]}")

    [[ $count -gt 0 ]] && echo -e "${GREEN}OK${NC} ($count files)" || echo -e "${GREEN}OK${NC}"
}

# Prepare dev
action_prepare_dev() {
    echo "==== Prepare $NAME $DEV_VERSION Dev ==="
    replace_version "$DEV_VERSION"
    replace_date

    # Check PhpStorm copyrights
    print_step_prefix "Check PhpStorm copyrights"
    local copyright_dir="$ROOT_DIR/.idea/copyright"
    if [[ -d "$copyright_dir" ]]; then
        local count=0
        for file in "$copyright_dir"/*.xml; do
            [[ ! -f "$file" ]] && continue
            [[ "$(basename "$file")" == "profiles_settings.xml" ]] && continue

            local original
            original=$(cat "$file")
            local replace="$original"
            replace=$(echo "$replace" | sed -E "s/@version([[:space:]]*).*&#10/@version\1__DEPLOY_VERSION__\&#10/g")
            replace=$(echo "$replace" | sed -E "s/@date([[:space:]]*).*&#10/@date\1$DATE\&#10;/g")

            if [[ "$original" != "$replace" ]]; then
                echo "$replace" > "$file"
                ((count++))
            fi
        done
        [[ $count -gt 0 ]] && echo -e "${GREEN}OK${NC} ($count files)" || echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}SKIP${NC} (no .idea/copyright)"
    fi
}

# Normalize language file names
action_normalize_lang_file_names() {
    echo "==== Normalize language file names ==="
    print_step_prefix "Scanning files"

    local renamed=()

    while IFS= read -r file; do
        [[ "$file" == *.ini ]] || continue
        local rel_path="${file#$ROOT_DIR/}"

        # Skip excluded paths
        should_exclude "$rel_path" "${PACKAGE_EXCLUDES[@]}" && continue

        # Match files like xx-XX.name.ini or xx-XX.name.sys.ini
        if [[ "$file" =~ /([a-z]{2}-[A-Z]{2})\.([a-z0-9_]+(\.sys)?)\.ini$ ]]; then
            local new_name="${BASH_REMATCH[2]}.ini"
            local new_path
            new_path="$(dirname "$file")/$new_name"

            if [[ ! -f "$new_path" ]]; then
                # Try git mv first
                if git mv "$file" "$new_path" 2>/dev/null; then
                    local status
                    status=$(git status --short "$new_path" 2>/dev/null || echo "")
                    if [[ "$status" =~ ^R ]]; then
                        renamed+=("$new_name")
                    else
                        renamed+=("$new_name (rename fallback)")
                    fi
                else
                    # Fallback to standard rename
                    mv "$file" "$new_path" 2>/dev/null && renamed+=("$new_name (no git)")
                fi
            fi
        fi
    done < <(get_files "$ROOT_DIR" "${PACKAGE_EXCLUDES[@]}")

    [[ ${#renamed[@]} -gt 0 ]] && echo -e "${GREEN}OK${NC}" || echo -e "${GREEN}OK${NC}"
    echo

    if [[ ${#renamed[@]} -gt 0 ]]; then
        echo "Renamed file names:"
        for f in "${renamed[@]}"; do
            echo "  - $f"
        done
    else
        echo "No files renamed"
    fi
    echo
}

# Package dev
action_package_dev() {
    echo "==== Package $NAME $DEV_VERSION Dev ==="
    create_package "$(get_package_name true)"
}

# Main execution
main() {
    parse_args "$@"

    # Validate required parameters for most actions
    if [[ "$ACTION" != "normalizeLangFileNames" ]] && [[ -z "$NAME" || -z "$VERSION" ]]; then
        echo "Error: Project name and version are required"
        echo "Either provide --name and --version, or ensure they are set in .env file"
        exit 1
    fi

    # Execute action
    case "$ACTION" in
        info)
            action_info
            ;;
        prepareRelease)
            action_prepare_release
            ;;
        packageRelease)
            action_package_release
            ;;
        resetSince)
            action_reset_since
            ;;
        prepareDev)
            action_prepare_dev
            ;;
        normalizeLangFileNames)
            action_normalize_lang_file_names
            ;;
        packageDev)
            action_package_dev
            ;;
        *)
            echo "Error: Unknown action '$ACTION'"
            usage
            ;;
    esac
}

main "$@"
