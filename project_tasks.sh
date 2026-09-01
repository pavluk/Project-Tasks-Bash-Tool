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

# Exclusions shared by file processing and package creation
COMMON_EXCLUDES=(
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

# Additional exclusions used only for package creation
PACKAGE_EXTRA_EXCLUDES=(
    "build"
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

trim_whitespace() {
    local value="$1"

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# Load environment variables from explicitly provided --env file
load_env() {
    local env_path=""
    local key
    local value

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

        # Trim surrounding whitespace without interpreting quotes or backslashes.
        key=$(trim_whitespace "$key")
        value=$(trim_whitespace "$value")

        # Remove one pair of matching wrapping quotes.
        if [[ "$value" == \"*\" && "$value" == *\" ]]; then
            value="${value#\"}"
            value="${value%\"}"
        elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
            value="${value#\'}"
            value="${value%\'}"
        fi

        case "$key" in
            PROJECT_NAME|NAME)
                NAME="$value"
                ;;
            PROJECT_VERSION|VERSION)
                VERSION="$value"
                [[ -n "$VERSION" ]] && set_version "$VERSION"
                ;;
            PROJECT_NPM|NPM_SCRIPT)
                PROJECT_NPM="$value"
                ;;
            PROJECT_NPM_DIR|NPM_DIR)
                PROJECT_NPM_DIR="$value"
                ;;
        esac
    done < "$env_path"

}

# Print usage
usage() {
    local exit_code="${1:-1}"

    cat << EOF
Usage: $0 [OPTIONS]

Options:
    --action=ACTION         Action to perform (info|prepareRelease|packageRelease|resetSince|prepareDev|normalizeLangFileNames|packageDev)
    --env=PATH             Path to params file (required)
    --name=NAME            Project name (overrides .env)
    --version=VERSION      Version number (overrides .env)
    --root=PATH            Project root (defaults to the current working directory)
    -h, --help             Show this help message

Env file format:
    PROJECT_NAME=MyProject
    PROJECT_VERSION=1.2.3

Examples:
    # Specify env file location (required)
    $0 --action=prepareRelease --env=/path/to/project/build.env

    # Override values read from the required env file
    $0 --action=info --env=/path/to/project/build.env --name=MyProject --version=1.2.3
EOF
    exit "$exit_code"
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
                usage 0
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

    if [[ ! -d "$ROOT_DIR" ]]; then
        echo -e "${RED}Error: project root directory not found: $ROOT_DIR${NC}"
        exit 1
    fi

    ROOT_DIR=$(cd "$ROOT_DIR" && pwd -P)

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
    local path_match
    base_name=$(basename "$file")
    # shellcheck disable=SC2053
    for pattern in "${excludes[@]}"; do
        if [[ "$pattern" == *"*"* ]] || [[ "$pattern" == *"?"* ]] || [[ "$pattern" == *"["* ]]; then
            [[ "$file" == $pattern ]] && return 0
            [[ "$base_name" == $pattern ]] && return 0
        else
            path_match="$file"
            [[ "$path_match" != */ ]] && path_match="$path_match/"
            [[ "$path_match" == "$pattern/"* ]] && return 0
            [[ "$path_match" == */"$pattern/"* ]] && return 0
            [[ "$base_name" == "$pattern" ]] && return 0
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
    done < <(find "${find_args[@]}")

    printf '%s\n' "${files[@]}"
}

# Apply a text transformation through a same-directory temporary copy.
# This preserves file metadata and exact trailing newline bytes.
transform_file() {
    local filepath="$1"
    local mode="$2"
    local temp_file

    FILE_CHANGED=false
    temp_file=$(mktemp "${filepath}.tmp.XXXXXX")

    if ! cp -p "$filepath" "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi

    case "$mode" in
        version)
            local target_version="$3"
            local doc_version="$4"
            local deploy_version="$5"
            local is_json="$6"

            if ! TARGET_VERSION="$target_version" DOC_VERSION="$doc_version" DEPLOY_VERSION="$deploy_version" IS_JSON="$is_json" perl -0pi -e '
                if ($ENV{IS_JSON} ne "1") {
                    s/\@version([^\S\r\n]*).*/"\@version" . $1 . $ENV{DOC_VERSION}/ge;
                    s/<version>[^\r\n]*<\/version>/"<version>" . $ENV{TARGET_VERSION} . "<\/version>"/ge;
                    s/\* ?Version:([^\S\r\n]*).*/"* Version:" . $1 . $ENV{TARGET_VERSION}/ge;
                    s/__DEPLOY_VERSION__/$ENV{DEPLOY_VERSION}/ge;
                } else {
                    # Scan JSON structure and update only a root-object property.
                    my $depth = 0;
                    my $i = 0;
                    my $length = length($_);

                    while ($i < $length) {
                        my $char = substr($_, $i, 1);

                        if ($char eq q{"}) {
                            my $start = $i++;
                            while ($i < $length) {
                                my $string_char = substr($_, $i, 1);
                                if ($string_char eq q{\\}) {
                                    $i += 2;
                                    next;
                                }
                                $i++;
                                last if $string_char eq q{"};
                            }
                            my $end = $i;

                            if ($depth == 1 && substr($_, $start, $end - $start) eq q{"version"}) {
                                my $colon = $end;
                                $colon++ while $colon < $length && substr($_, $colon, 1) =~ /\s/;

                                if ($colon < $length && substr($_, $colon, 1) eq q{:}) {
                                    my $value_start = $colon + 1;
                                    $value_start++ while $value_start < $length && substr($_, $value_start, 1) =~ /\s/;

                                    if ($value_start < $length && substr($_, $value_start, 1) eq q{"}) {
                                        my $value_end = $value_start + 1;
                                        while ($value_end < $length) {
                                            my $value_char = substr($_, $value_end, 1);
                                            if ($value_char eq q{\\}) {
                                                $value_end += 2;
                                                next;
                                            }
                                            $value_end++;
                                            last if $value_char eq q{"};
                                        }

                                        substr(
                                            $_,
                                            $value_start,
                                            $value_end - $value_start,
                                            q{"} . $ENV{TARGET_VERSION} . q{"}
                                        );
                                        last;
                                    }
                                }
                            }

                            next;
                        }

                        if ($char eq "{" || $char eq "[") {
                            $depth++;
                        } elsif ($char eq "}" || $char eq "]") {
                            $depth--;
                        }
                        $i++;
                    }
                }
            ' "$temp_file"; then
                rm -f "$temp_file"
                return 1
            fi
            ;;
        date)
            local target_date="$3"

            if ! TARGET_DATE="$target_date" perl -0pi -e '
                s/\@date([^\S\r\n]*).*/"\@date" . $1 . $ENV{TARGET_DATE}/ge;
                s/<date>[^\r\n]*<\/date>/"<date>" . $ENV{TARGET_DATE} . "<\/date>"/ge;
                s/<creationDate>[^\r\n]*<\/creationDate>/"<creationDate>" . $ENV{TARGET_DATE} . "<\/creationDate>"/ge;
                s/__DEPLOY_DATE__/$ENV{TARGET_DATE}/ge;
            ' "$temp_file"; then
                rm -f "$temp_file"
                return 1
            fi
            ;;
        since)
            if ! perl -0pi -e 's/\@since([^\S\r\n]*).*/"\@since" . $1 . "__DEPLOY_VERSION__"/ge' "$temp_file"; then
                rm -f "$temp_file"
                return 1
            fi
            ;;
        copyright)
            local target_date="$3"

            if ! TARGET_DATE="$target_date" perl -0pi -e '
                s/\@version([^\S\r\n]*)[^\r\n]*?&#10;?/"\@version" . $1 . "__DEPLOY_VERSION__&#10;"/ge;
                s/\@date([^\S\r\n]*)[^\r\n]*?&#10;?/"\@date" . $1 . $ENV{TARGET_DATE} . "&#10;"/ge;
            ' "$temp_file"; then
                rm -f "$temp_file"
                return 1
            fi
            ;;
        *)
            rm -f "$temp_file"
            echo "Error: unknown transform mode '$mode'" >&2
            return 1
            ;;
    esac

    if cmp -s "$filepath" "$temp_file"; then
        rm -f "$temp_file"
    else
        mv -f "$temp_file" "$filepath"
        FILE_CHANGED=true
    fi
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

        local is_json=0
        [[ "$file" == *.json ]] && is_json=1

        transform_file "$filepath" version "$version" "$doc_version" "$deploy_version" "$is_json"
        [[ "$FILE_CHANGED" == true ]] && ((count += 1))
    done < <(get_files "$ROOT_DIR" "${COMMON_EXCLUDES[@]}")

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

        transform_file "$filepath" date "$DATE"
        [[ "$FILE_CHANGED" == true ]] && ((count += 1))
    done < <(get_files "$ROOT_DIR" "${COMMON_EXCLUDES[@]}")

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
    local source_temp_dir
    local archive_temp_dir
    local temp_package_path

    if [[ "$package_name" == */* || "$package_name" == "." || "$package_name" == ".." ]]; then
        echo -e "${RED}Error: invalid package name: $package_name${NC}"
        return 1
    fi

    if ! command -v zip >/dev/null 2>&1; then
        echo -e "${RED}Error: zip command not found${NC}"
        return 1
    fi

    mkdir -p "$package_dir"

    print_step_prefix "Create package"

    if ! source_temp_dir=$(mktemp -d); then
        echo -e "${RED}ERROR${NC} (failed to create temporary directory)"
        return 1
    fi
    if ! archive_temp_dir=$(mktemp -d "$package_dir/.package.XXXXXX"); then
        rm -rf "$source_temp_dir"
        echo -e "${RED}ERROR${NC} (failed to create package staging directory)"
        return 1
    fi
    temp_package_path="$archive_temp_dir/$package_name"

    if ! copy_package_files "$source_temp_dir"; then
        rm -rf "$source_temp_dir" "$archive_temp_dir"
        echo -e "${RED}ERROR${NC} (failed to copy package files)"
        return 1
    fi

    if ! (cd "$source_temp_dir" && zip -r -q "$temp_package_path" .); then
        rm -rf "$source_temp_dir" "$archive_temp_dir"
        echo -e "${RED}ERROR${NC} (zip failed)"
        return 1
    fi

    if ! mv -f "$temp_package_path" "$package_path"; then
        rm -rf "$source_temp_dir" "$archive_temp_dir"
        echo -e "${RED}ERROR${NC} (failed to install package)"
        return 1
    fi

    rm -rf "$source_temp_dir" "$archive_temp_dir"
    echo -e "${GREEN}OK${NC}"
}

copy_package_files() {
    local temp_dir="$1"
    local file
    local filepath
    local target_dir

    while IFS= read -r file; do
        filepath="$ROOT_DIR/$file"
        [[ ! -f "$filepath" ]] && continue

        target_dir="$temp_dir/$(dirname "$file")"
        mkdir -p "$target_dir" || return 1
        cp -p "$filepath" "$temp_dir/$file" || return 1
    done < <(get_files "$ROOT_DIR" "${COMMON_EXCLUDES[@]}" "${PACKAGE_EXTRA_EXCLUDES[@]}")
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

        transform_file "$filepath" since
        [[ "$FILE_CHANGED" == true ]] && ((count += 1))
    done < <(get_files "$ROOT_DIR" "${COMMON_EXCLUDES[@]}")

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

            transform_file "$file" copyright "$DATE"
            [[ "$FILE_CHANGED" == true ]] && ((count += 1))
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
        # Match files like xx-XX.name.ini or xx-XX.name.sys.ini
        if [[ "$file" =~ (^|/)([a-z]{2}-[A-Z]{2})\.([a-z0-9_]+(\.sys)?)\.ini$ ]]; then
            local new_name="${BASH_REMATCH[3]}.ini"
            local new_rel_path
            local source_path="$ROOT_DIR/$file"
            local new_path
            new_rel_path="$(dirname "$file")/$new_name"
            new_path="$ROOT_DIR/$new_rel_path"

            if [[ ! -f "$new_path" ]]; then
                # Try git mv first
                if git -C "$ROOT_DIR" mv -- "$file" "$new_rel_path" 2>/dev/null; then
                    local status
                    status=$(git -C "$ROOT_DIR" status --short -- "$new_rel_path" 2>/dev/null || echo "")
                    if [[ "$status" =~ ^R ]]; then
                        renamed+=("$new_name")
                    else
                        renamed+=("$new_name (rename fallback)")
                    fi
                else
                    # Fallback to standard rename
                    mv "$source_path" "$new_path" 2>/dev/null && renamed+=("$new_name (no git)")
                fi
            fi
        fi
    done < <(get_files "$ROOT_DIR" "${COMMON_EXCLUDES[@]}" "${PACKAGE_EXTRA_EXCLUDES[@]}")

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

    # The explicitly provided env file must define both values for every action.
    if [[ -z "$NAME" || -z "$VERSION" ]]; then
        echo "Error: Project name and version are required"
        echo "Provide --name and --version, or define them in the env file"
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
