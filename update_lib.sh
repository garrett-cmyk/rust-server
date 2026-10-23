#!/usr/bin/env bash
#
# Update helpers, sourced by start_rust.sh.
#
# Every path can be overridden through the environment so the functions can be
# exercised outside the container (see the test notes in the commit message).

APP_ID="${APP_ID:-258550}"
RUST_DIR="${RUST_DIR:-/steamcmd/rust}"
STEAMCMD="${STEAMCMD:-/steamcmd/steamcmd.sh}"
INSTALL_TXT="${INSTALL_TXT:-/app/install.txt}"
STEAM_HOME="${STEAM_HOME:-/app/Steam}"

updater_log() {
	echo "[updater] $*"
}

# Posts to Discord if RUST_ALERT_WEBHOOK is set, always logs.
send_alert() {
	local message="${1//\"/\'}"
	echo "ALERT: $message"
	if [ -n "${RUST_ALERT_WEBHOOK}" ]; then
		curl -s -X POST -H "Content-Type: application/json" \
			-d "{\"content\": \"$message\"}" "$RUST_ALERT_WEBHOOK" > /dev/null 2>&1
	fi
}

# Build id that steamcmd recorded for what is installed on disk (empty if unknown).
installed_buildid() {
	local manifest="$RUST_DIR/steamapps/appmanifest_${APP_ID}.acf"
	[ -f "$manifest" ] || return 0
	grep -m1 -oP '"buildid"\s+"\K[0-9]+' "$manifest" || true
}

# Newest build id Steam publishes on $RUST_UPDATE_BRANCH (empty if the lookup failed).
latest_buildid() {
	rm -f "$STEAM_HOME/appcache/appinfo.vdf"
	bash "$STEAMCMD" +login anonymous +app_info_update 1 +app_info_print "$APP_ID" +quit 2>/dev/null |
		awk -v branch="${RUST_UPDATE_BRANCH:-public}" '
			/^[[:space:]]*"branches"[[:space:]]*$/ { in_branches = 1; next }
			in_branches && $0 ~ "^[[:space:]]*\"" branch "\"[[:space:]]*$" { in_branch = 1; next }
			in_branch && /^[[:space:]]*"buildid"/ { gsub(/[^0-9]/, ""); print; exit }
			in_branch && /^[[:space:]]*}/ { exit }
		'
}

# One steamcmd run of the given script. steamcmd exits 0 even when the update
# failed ("Error! App '258550' state is 0x486 after update job."), so success is
# decided from its output, not from its exit code.
steam_run_install() {
	local script="${1:-$INSTALL_TXT}" out rc
	out="$(mktemp)"
	bash "$STEAMCMD" +runscript "$script" 2>&1 | tee "$out"
	rc=${PIPESTATUS[0]}
	# Remember whether we got as far as logging in, to tell "no network" from "Steam refused"
	if grep -q "Connecting anonymously to Steam Public...OK" "$out"; then UPDATER_CONNECTED=1; else UPDATER_CONNECTED=0; fi
	if [ "$rc" -eq 0 ] && grep -q "Success! App '$APP_ID'" "$out" && ! grep -q "Error! App '$APP_ID'" "$out"; then
		rm -f "$out"
		return 0
	fi
	rm -f "$out"
	return 1
}

# Forget what steamcmd believes is installed so the next run treats the existing
# files as a fresh install and re-verifies them against the current manifests.
reset_steam_app_state() {
	local manifest="$RUST_DIR/steamapps/appmanifest_${APP_ID}.acf"
	if [ -f "$manifest" ]; then
		cp -f "$manifest" "$manifest.bak"
		rm -f "$manifest"
	fi
	rm -f "$STEAM_HOME/appcache/appinfo.vdf" "$STEAM_HOME/appcache/packageinfo.vdf"
}

# Everything in $RUST_DIR that is data rather than game files.
is_kept_entry() {
	case "$1" in
		oxide|server|logs|HarmonyMods|HarmonyConfig|.staging|.old) return 0 ;;
	esac
	return 1
}

# Downloads a complete fresh copy next to the live install and swaps it in only
# if the download fully succeeded. If anything goes wrong the live install is
# put back exactly as it was.
fresh_install_swap() {
	local stage="$RUST_DIR/.staging" old="$RUST_DIR/.old" script entry name failed=0

	updater_log "Fresh install into $stage (live files are replaced only if this fully succeeds)"
	rm -rf "$stage" "$old"
	mkdir -p "$stage" || return 1

	script="$(mktemp)"
	sed "s#^force_install_dir .*#force_install_dir $stage#" "$INSTALL_TXT" > "$script"
	if ! steam_run_install "$script" || [ ! -f "$stage/RustDedicated" ]; then
		rm -f "$script"
		rm -rf "$stage"
		updater_log "Fresh install failed, live install left untouched"
		return 1
	fi
	rm -f "$script"

	mkdir -p "$old" || return 1
	for entry in "$RUST_DIR"/* "$RUST_DIR"/.[!.]*; do
		[ -e "$entry" ] || continue
		name="$(basename "$entry")"
		is_kept_entry "$name" && continue
		mv "$entry" "$old/" || { failed=1; break; }
	done

	if [ "$failed" -eq 0 ]; then
		for entry in "$stage"/* "$stage"/.[!.]*; do
			[ -e "$entry" ] || continue
			name="$(basename "$entry")"
			is_kept_entry "$name" && continue
			mv "$entry" "$RUST_DIR/" || { failed=1; break; }
		done
	fi

	if [ "$failed" -ne 0 ]; then
		updater_log "Swap failed, restoring the previous install"
		for entry in "$old"/* "$old"/.[!.]*; do
			[ -e "$entry" ] || continue
			name="$(basename "$entry")"
			rm -rf "${RUST_DIR:?}/$name"
			mv "$entry" "$RUST_DIR/"
		done
		rm -rf "$old" "$stage"
		return 1
	fi

	rm -rf "$old" "$stage"
	return 0
}

# Install or update Rust, escalating only as far as needed:
#   1. normal steamcmd update (retried a few times if Steam is unreachable)
#   2. drop steamcmd's stale app state (appmanifest + cached app info), retry
#   3. fresh install in a staging dir, swapped in only on success
# Returns non-zero only if all of them failed; the caller decides whether the
# existing install is good enough to start.
install_or_update() {
	local try
	echo "Installing or updating Rust.. (this might take a while, be patient)"
	for try in 1 2 3; do
		steam_run_install && return 0
		[ "$UPDATER_CONNECTED" = "1" ] && break
		updater_log "Could not reach Steam (try $try of 3)"
		[ "$try" -lt 3 ] && sleep "${RUST_UPDATE_RETRY_DELAY:-20}"
	done
	if [ "$UPDATER_CONNECTED" != "1" ]; then
		# A network problem says nothing about the install, so don't touch it
		updater_log "Steam was never reachable, leaving the existing install as it is"
		return 1
	fi

	updater_log "Update failed, dropping stale app state and retrying (step 2 of 3)"
	reset_steam_app_state
	steam_run_install && return 0

	if [ "${RUST_UPDATE_FRESH_FALLBACK:-1}" = "1" ]; then
		updater_log "Retry failed, trying a fresh install (step 3 of 3)"
		fresh_install_swap && return 0
	fi

	# Everything failed: put steamcmd's record back so the installed build is still known
	local manifest="$RUST_DIR/steamapps/appmanifest_${APP_ID}.acf"
	if [ -f "$manifest.bak" ] && [ ! -f "$manifest" ]; then
		cp -f "$manifest.bak" "$manifest"
	fi
	return 1
}

# Install the newest Oxide over the game files. steamcmd's validate restores the
# vanilla game DLLs, so this has to run after every update, not only when Oxide
# is missing. GitHub releases first, uMod as a fallback; override with RUST_OXIDE_URL.
install_oxide() {
	local zip url ok=1
	zip="$(mktemp)"
	for url in \
		"${RUST_OXIDE_URL:-https://github.com/OxideMod/Oxide.Rust/releases/latest/download/Oxide.Rust-linux.zip}" \
		"https://umod.org/games/rust/download/develop"; do
		updater_log "Downloading Oxide from $url"
		if curl -fsSL --retry 3 --retry-delay 2 -o "$zip" "$url" && [ -s "$zip" ] && bsdtar -tf "$zip" > /dev/null 2>&1; then
			ok=0
			break
		fi
		updater_log "That download failed or was not a valid archive"
	done
	if [ "$ok" -ne 0 ]; then
		rm -f "$zip"
		return 1
	fi
	bsdtar -xf "$zip" -C "$RUST_DIR" || { rm -f "$zip"; return 1; }
	rm -f "$zip"
	chmod 755 "$RUST_DIR/CSharpCompiler.x86_x64" > /dev/null 2>&1
	updater_log "Oxide installed"
	return 0
}
