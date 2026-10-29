#!/usr/bin/env bash

# Enable debugging
# set -x

# Print the user we're currently running as
echo "Running as user: $(whoami)"

# Define the exit handler
exit_handler()
{
	echo "Shutdown signal received"

	# Execute the RCON shutdown command
	node /app/shutdown_app/app.js
	killer=$!
	wait "$killer"

	# Stop the web server
	pkill -f nginx

	echo "Exiting.."
	exit
}

# Trap specific signals and forward to the exit handler
trap 'exit_handler' SIGINT SIGTERM

# Rust includes a 64-bit version of steamclient.so, so we need to tell the OS where it exists
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/steamcmd/rust/RustDedicated_Data/Plugins/x86_64

# Load the install/update helpers (install_or_update, install_oxide, send_alert, ..)
source /app/update_lib.sh

# Remove old lock files (used by restart_app/ and update_check.sh)
rm -fr /tmp/*.lock

# Create the necessary folder structure
if [ ! -d "/steamcmd/rust" ]; then
	echo "Missing /steamcmd/rust, creating.."
	mkdir -p /steamcmd/rust
fi
if [ ! -d "/steamcmd/rust/server/${RUST_SERVER_IDENTITY}" ]; then
	echo "Missing /steamcmd/rust/server/${RUST_SERVER_IDENTITY}, creating.."
	mkdir -p "/steamcmd/rust/server/${RUST_SERVER_IDENTITY}"
fi

# Install/update steamcmd
echo "Installing/updating steamcmd.."
curl -s http://media.steampowered.com/installer/steamcmd_linux.tar.gz | bsdtar -xvf- -C /steamcmd

# Check which branch to use
if [ ! -z ${RUST_BRANCH+x} ]; then
	echo "Using branch arguments: $RUST_BRANCH"

	# Add "-beta" if necessary
	INSTALL_BRANCH="${RUST_BRANCH}"
	if [ ! "$RUST_BRANCH" == "public" ]; then
	    INSTALL_BRANCH="-beta ${RUST_BRANCH}"
	fi
	sed -i "s/app_update 258550.*validate/app_update 258550 $INSTALL_BRANCH validate/g" /app/install.txt
else
	sed -i "s/app_update 258550.*validate/app_update 258550 validate/g" /app/install.txt
fi

# Disable auto-update if start mode is 2
if [ "$RUST_START_MODE" = "2" ]; then
	# Check that Rust exists in the first place
	if [ ! -f "/steamcmd/rust/RustDedicated" ]; then
		if ! install_or_update; then
			echo "Exiting, steamcmd install failed!"
			exit 1
		fi
	else
		echo "Rust seems to be installed, skipping automatic update.."
	fi
else
	if ! install_or_update; then
		if [ -f "/steamcmd/rust/RustDedicated" ]; then
			send_alert "Rust update FAILED after every recovery step. Starting on the existing install (build $(installed_buildid)). Check the container logs."
		else
			echo "Exiting, steamcmd install failed and nothing is installed!"
			exit 1
		fi
	elif [ "${RUST_UPDATE_VERIFY:-1}" = "1" ]; then
		# Compare what is on disk with what Steam publishes, so a silently stale server is visible
		INSTALLED_BUILD="$(installed_buildid)"
		LATEST_BUILD="$(latest_buildid)"
		if [ -z "$LATEST_BUILD" ]; then
			updater_log "Could not look up the latest build on Steam; installed build is ${INSTALLED_BUILD:-unknown}"
		elif [ "$INSTALLED_BUILD" = "$LATEST_BUILD" ]; then
			updater_log "Rust is up to date (build $INSTALLED_BUILD)"
		else
			send_alert "Rust update did not apply: installed build ${INSTALLED_BUILD:-unknown}, Steam has $LATEST_BUILD."
		fi
	fi

	# Run the update check if it's not been run before
	if [ ! -f "/steamcmd/rust/build.id" ]; then
		./app/update_check.sh
	else
		OLD_BUILDID="$(cat /steamcmd/rust/build.id)"
		STRING_SIZE=${#OLD_BUILDID}
		if [ "$STRING_SIZE" -lt "6" ]; then
			./app/update_check.sh
		fi
	fi
fi

# Check if Oxide is enabled
if [ "$RUST_OXIDE_ENABLED" = "1" ]; then
	# Next check if Oxide doesn't' exist, or if we want to always update it.
	# Keep RUST_OXIDE_UPDATE_ON_BOOT=1 whenever the game update step runs: steamcmd's
	# validate restores the vanilla game DLLs, which silently removes Oxide's patches.
	INSTALL_OXIDE="0"
	if [ ! -f "/steamcmd/rust/CSharpCompiler.x86_x64" ]; then
		INSTALL_OXIDE="1"
	fi
	if [ "$RUST_OXIDE_UPDATE_ON_BOOT" = "1" ]; then
		INSTALL_OXIDE="1"
	fi

	# If necessary, download and install latest Oxide
	if [ "$INSTALL_OXIDE" = "1" ]; then
		echo "Downloading and installing latest Oxide.."
		if ! install_oxide; then
			if [ -f "/steamcmd/rust/CSharpCompiler.x86_x64" ]; then
				send_alert "Could not download Oxide; starting with the Oxide files already on disk, which may not match this Rust build."
			else
				echo "Exiting, Oxide is enabled but could not be installed!"
				exit 1
			fi
		fi
	fi
fi

# Start mode 1 means we only want to update
if [ "$RUST_START_MODE" = "1" ]; then
	echo "Exiting, start mode is 1.."
	exit
fi

# Remove extra whitespace from startup command
RUST_STARTUP_COMMAND=$(echo "$RUST_SERVER_STARTUP_ARGUMENTS" | tr -s " ")

# Add RCON support if necessary
if [ ! -z ${RUST_RCON_PORT+x} ]; then
	RUST_STARTUP_COMMAND="$RUST_STARTUP_COMMAND +rcon.port $RUST_RCON_PORT"
fi
if [ ! -z ${RUST_RCON_PASSWORD+x} ]; then
	RUST_STARTUP_COMMAND="$RUST_STARTUP_COMMAND +rcon.password $RUST_RCON_PASSWORD"
fi

if [ ! -z ${RUST_RCON_WEB+x} ]; then
	RUST_STARTUP_COMMAND="$RUST_STARTUP_COMMAND +rcon.web $RUST_RCON_WEB"
	if [ "$RUST_RCON_WEB" = "1" ]; then
		# Fix the webrcon (customizes a few elements)
		bash -c "RUST_RCON_SECURE_WEBSOCKET=${RUST_RCON_SECURE_WEBSOCKET} /tmp/fix_conn.sh"

		# Start nginx (in the background)
		echo "Starting web server.."
		nginx
		NGINX=$!
		sleep 5
	fi
fi

# Disable logrotate if "-logfile" is set in $RUST_STARTUP_COMMAND
LOGROTATE_ENABLED=1
RUST_STARTUP_COMMAND_LOWERCASE=`echo "$RUST_STARTUP_COMMAND" | sed 's/./\L&/g'`
if [[ $RUST_STARTUP_COMMAND_LOWERCASE == *" -logfile "* ]]; then
	LOGROTATE_ENABLED=0
fi

if [ "$LOGROTATE_ENABLED" = "1" ]; then
	echo "Log rotation enabled!"

	# RustDedicated already prints its console to stdout, which the pipeline below
	# captures and tees into the rotating log file. Also passing "-logfile /dev/stdout"
	# made Unity write every line to stdout a second time, so every line showed up
	# twice. Set RUST_LOGFILE_STDOUT=1 to get the old behaviour back.
	if [ "${RUST_LOGFILE_STDOUT:-0}" = "1" ]; then
		RUST_STARTUP_COMMAND="$RUST_STARTUP_COMMAND -logfile /dev/stdout"
	fi
	echo "Using startup arguments: $RUST_SERVER_STARTUP_ARGUMENTS"

	# Create the logging directory structure
	if [ ! -d "/steamcmd/rust/logs/archive" ]; then
		mkdir -p /steamcmd/rust/logs/archive
	fi

	# Set the logfile filename/path
	DATE=`date '+%Y-%m-%d_%H-%M-%S'`
	RUST_SERVER_LOG_FILE="/steamcmd/rust/logs/$RUST_SERVER_IDENTITY"_"$DATE.txt"

	# Archive old logs
	echo "Cleaning up old logs.."
	mv /steamcmd/rust/logs/*.txt /steamcmd/rust/logs/archive | true
else
	echo "Log rotation disabled!"
fi

# Disable logging to stdout/stderr if "-logfile /dev/" is used
STDLOG_ENABLED=1
if [[ $RUST_STARTUP_COMMAND_LOWERCASE == *" -logfile /dev/"* ]]; then
	echo "Disabling internal stdout/stderr logging!"
	STDLOG_ENABLED=0
fi

# Start the scheduler (only if update checking is enabled)
if [ "$RUST_UPDATE_CHECKING" = "1" ]; then
	echo "Starting scheduled task manager.."
	node /app/scheduler_app/app.js &
fi

# Start the heartbeat(only if enabled)
if [ "$RUST_HEARTBEAT" = "1" ]; then
	echo "Starting heartbeat.."
	node /app/heartbeat_app/app.js &
fi

# Set the working directory
cd /steamcmd/rust

# Run the server
echo "Starting Rust.."

# Preparing arguments
function add_argument_pair {
  local -n arr=$1
  if [ ! -z "${!3}" ]; then
    arr+=("${2}");
    arr+=("${!3}");
  fi
}

ARGUMENTS=()
add_argument_pair ARGUMENTS "+server.port" "RUST_SERVER_PORT"
add_argument_pair ARGUMENTS "+server.queryport" "RUST_SERVER_QUERYPORT"
add_argument_pair ARGUMENTS "+server.identity" "RUST_SERVER_IDENTITY"
if [ -z "$RUST_SERVER_LEVELURL" ]; then
  add_argument_pair ARGUMENTS "+server.worldsize" "RUST_SERVER_WORLDSIZE"
  add_argument_pair ARGUMENTS "+server.seed" "RUST_SERVER_SEED"
  echo "Generating procedural map.."
else
  add_argument_pair ARGUMENTS "+server.levelurl" "RUST_SERVER_LEVELURL"
  echo "Using custom map.."
fi
add_argument_pair ARGUMENTS "+server.hostname" "RUST_SERVER_NAME"
add_argument_pair ARGUMENTS "+server.url" "RUST_SERVER_URL"
add_argument_pair ARGUMENTS "+server.headerimage" "RUST_SERVER_BANNER_URL"
add_argument_pair ARGUMENTS "+server.description" "RUST_SERVER_DESCRIPTION"
add_argument_pair ARGUMENTS "+server.maxplayers" "RUST_SERVER_MAXPLAYERS"
add_argument_pair ARGUMENTS "+server.saveinterval" "RUST_SERVER_SAVE_INTERVAL"
add_argument_pair ARGUMENTS "+app.port" "RUST_APP_PORT"

# Launches RustDedicated and waits for it to exit
start_rust_server() {
  if [ "$LOGROTATE_ENABLED" = "1" ]; then
    unbuffer /steamcmd/rust/RustDedicated $RUST_STARTUP_COMMAND "${ARGUMENTS[@]}" 2>&1 | grep --line-buffered -Ev '^\s*$|Filename' | tee "$RUST_SERVER_LOG_FILE" &
  elif [ "$STDLOG_ENABLED" = "1" ]; then
    /steamcmd/rust/RustDedicated $RUST_STARTUP_COMMAND "${ARGUMENTS[@]}" 2>&1 | tee /tmp/rust-last-boot.log &
  else
    /steamcmd/rust/RustDedicated $RUST_STARTUP_COMMAND "${ARGUMENTS[@]}" > /tmp/rust-last-boot.log 2>&1 &
  fi
  child=$!
  wait "$child"
}

# Checks the most recent boot log for the known Oxide/Rust-update incompatibility crash
crashed_with_oxide_incompatibility() {
  local logfile="${RUST_SERVER_LOG_FILE:-/tmp/rust-last-boot.log}"
  [ -f "$logfile" ] && grep -qE "MissingMethodException|Could not load signature" "$logfile"
}

start_rust_server

MAX_SELF_HEAL_ATTEMPTS=1
attempt=0
while crashed_with_oxide_incompatibility && [ "$attempt" -lt "$MAX_SELF_HEAL_ATTEMPTS" ]; do
  attempt=$((attempt + 1))
  send_alert "Rust server hit an Oxide/game-update incompatibility crash. Attempting automatic clean reinstall (attempt $attempt/$MAX_SELF_HEAL_ATTEMPTS).."

  # Full clean reinstall, preserving only oxide/ (plugins/config/data) and server/ (world saves/identity)
  find /steamcmd/rust -mindepth 1 -maxdepth 1 ! -name 'oxide' ! -name 'server' -exec rm -rf {} +

  if ! install_or_update; then
    send_alert "Clean reinstall failed, nothing is installed. Manual attention needed."
    exit 1
  fi

  if [ "$RUST_OXIDE_ENABLED" = "1" ]; then
    echo "Re-downloading and installing latest Oxide.."
    install_oxide || send_alert "Could not download Oxide during the clean reinstall."
  fi

  start_rust_server
done

if crashed_with_oxide_incompatibility; then
  send_alert "Rust server still crashing after automatic clean reinstall — this needs manual attention. Likely waiting on an upstream Oxide fix."
fi

pkill -f nginx
echo "Exiting.."
exit
