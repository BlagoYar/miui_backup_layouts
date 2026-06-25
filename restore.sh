#!/data/data/com.termux/files/usr/bin/bash

########################################
# Check ROOT
########################################
if [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: This script must be run as root (su)"
	exit 1
fi

########################################

set -e

DB_DIR="/data/user_de/0/com.miui.home/databases"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

sql_escape() {
	printf "%s" "$1" | sed "s/'/''/g"
}

exit_script() {
	echo
	echo "[!] Exiting..."
	exit 0
}

########################################
# Checks
########################################
if ! command -v sqlite3 >/dev/null 2>&1; then
	echo
	echo "[!] sqlite3 not found"
	echo
	read -rp "Install sqlite3 now? [Y/n]: " answer
	answer=${answer:-Y}

	case "$answer" in
	Y | y)
		echo
		echo "[+] Installing sqlite..."
		echo
		set +e
		pkg install -y sqlite
		set -e

		if ! command -v sqlite3 >/dev/null 2>&1; then
			echo
			echo "[!] sqlite3 is still unavailable."
			echo "[!] Please install/fix it manually."
			exit 1
		fi
		;;
	*)
		echo
		echo "[!] sqlite3 is required."
		exit 1
		;;
	esac
fi

mapfile -t EXPORTS < <(find "$SCRIPT_DIR/export" -mindepth 1 -maxdepth 1 -type d | sort)
ecount=${#EXPORTS[@]}

[ "$ecount" -gt 0 ] || {
	echo "ERROR: export folders not found"
	exit 1
}

########################################
# Main Loop
########################################
while true; do
	########################################
	# Export Selection Menu
	########################################
	if [ "$ecount" -eq 1 ]; then
		EXPORT_DIR="${EXPORTS[0]}"
	else
		while true; do
			echo
			echo "========================================"
			echo "Found exports:"
			echo "========================================"
			i=1
			for e in "${EXPORTS[@]}"; do
				echo "  $i) $(basename "$e")"
				i=$((i + 1))
			done
			echo
			echo "Enter export number"
			echo
			echo "0) Exit"
			echo
			read -rp "Select export: " num

			case "$num" in
			0)
				exit_script
				;;
			*)
				if [ -z "$num" ]; then
					echo "[!] Invalid choice"
					continue
				fi
				idx=$((num - 1))
				if [ "$idx" -lt 0 ] || [ "$idx" -ge "$ecount" ]; then
					echo "[!] Invalid choice"
					continue
				fi
				EXPORT_DIR="${EXPORTS[$idx]}"
				break
				;;
			esac
		done
	fi

	mapfile -t FOLDER_LAYOUTS < <(find "$EXPORT_DIR/folders" -type f -name 'layout.txt' 2>/dev/null | sort)
	mapfile -t DESKTOP_LAYOUTS < <(find "$EXPORT_DIR/desktops" -type f -name 'layout.txt' 2>/dev/null | sort)
	mapfile -t WIDGET_LAYOUTS < <(find "$EXPORT_DIR/widgets" -type f -name 'layout.txt' 2>/dev/null | sort)
	mapfile -t DOCK_LAYOUTS < <(find "$EXPORT_DIR/dock" -type f -name 'layout.txt' 2>/dev/null | sort)

	# Правильный подсчет
	folder_count=${#FOLDER_LAYOUTS[@]}

	desktop_shortcut_count=0
	if [ -f "$EXPORT_DIR/desktops/layout.txt" ]; then
		desktop_shortcut_count=$(grep -c '^[^[:space:]]' "$EXPORT_DIR/desktops/layout.txt" || true)
		desktop_shortcut_count=$((desktop_shortcut_count - $(grep -c '^SCREEN ' "$EXPORT_DIR/desktops/layout.txt" || true)))
	fi

	widget_count=0
	if [ -f "$EXPORT_DIR/widgets/layout.txt" ]; then
		widget_count=$(grep -c '^WIDGET|' "$EXPORT_DIR/widgets/layout.txt" || true)
	fi

	dock_count=0
	if [ -f "$EXPORT_DIR/dock/layout.txt" ]; then
		dock_count=$(grep -c '^DOCK|' "$EXPORT_DIR/dock/layout.txt" || true)
	fi

	echo
	echo "Export: $(basename "$EXPORT_DIR")"
	echo "========================================"
	echo "  Folders: $folder_count"
	echo "  Desktop Shortcuts: $desktop_shortcut_count"
	echo "  Widgets: $widget_count"
	echo "  Dock Items: $dock_count"
	echo "========================================"

	[ "$folder_count" -gt 0 ] || {
		echo "ERROR: no folder layouts found"
		continue
	}

	########################################
	# DB loop
	########################################
	TARGET_DB_NAME="$(basename "$EXPORT_DIR").db"
	TARGET_DB_PATH="$DB_DIR/$TARGET_DB_NAME"

	if [ ! -f "$TARGET_DB_PATH" ]; then
		echo "ERROR: Target database $TARGET_DB_NAME not found in $DB_DIR"
		continue
	fi

	SELECTED_DBS=("$TARGET_DB_PATH")
	echo "TARGET DB=[$TARGET_DB_NAME]"

	########################################
	# Restore Mode Selection
	########################################
	restore_mode=""
	RESTORE_FOLDERS=()
	RESTORE_WIDGETS=()

	while true; do
		echo
		echo "========================================"
		echo "Restore Mode"
		echo "========================================"
		echo "  1) Restore All (folders, desktops, dock, widgets)"
		echo "  2) Selective Restore (choose folders)"
		echo "  3) Restore Widgets (all or selective)"
		echo
		echo "b) Back"
		echo
		echo "0) Exit"
		echo
		read -rp "Select: " restore_mode

		case "$restore_mode" in
		1)
			RESTORE_FOLDERS=("${FOLDER_LAYOUTS[@]}")
			RESTORE_WIDGETS=("${WIDGET_LAYOUTS[@]}")
			break
			;;
		2)
			widget_mode=0
			while true; do
				echo
				echo "========================================"
				echo "Select Folders to Restore"
				echo "========================================"
				echo "  0) Restore ALL folders ($folder_count total)"
				i=1
				declare -A FOLDER_NAMES
				for fl in "${FOLDER_LAYOUTS[@]}"; do
					folder_name=$(grep '^FOLDER ' "$fl" | head -n1 | cut -d' ' -f2-)
					echo "  $i) $folder_name"
					FOLDER_NAMES[$i]="$fl"
					i=$((i + 1))
				done
				echo
				echo "Enter numbers separated by comma (e.g. 1,3,5) or 0 for all"
				echo
				echo "b) Back"
				echo
				echo "0) Exit"
				echo
				read -rp "Select: " folder_choice

				case "$folder_choice" in
				0)
					exit_script
					;;
				b)
					unset FOLDER_NAMES
					break 2
					;;
				esac

				case "$folder_choice" in
				0)
					RESTORE_FOLDERS=("${FOLDER_LAYOUTS[@]}")
					unset FOLDER_NAMES
					break 2
					;;
				*)
					RESTORE_FOLDERS=()
					IFS=',' read -ra FNUMS <<<"$folder_choice"
					for fn in "${FNUMS[@]}"; do
						fn=$(echo "$fn" | tr -d ' ')
						if [ -n "${FOLDER_NAMES[$fn]}" ]; then
							RESTORE_FOLDERS+=("${FOLDER_NAMES[$fn]}")
						fi
					done
					if [ ${#RESTORE_FOLDERS[@]} -gt 0 ]; then
						unset FOLDER_NAMES
						break 2
					else
						echo "[!] No valid folders selected"
					fi
					;;
				esac
			done
			;;
		3)
			while true; do
				echo
				echo "========================================"
				echo "Restore Widgets"
				echo "========================================"
				echo "  1) Restore ALL widgets ($widget_count total)"
				echo "  2) Selective Restore (choose widgets)"
				echo
				echo "b) Back"
				echo
				echo "0) Exit"
				echo
				read -rp "Select: " widget_choice

				case "$widget_choice" in
				0)
					exit_script
					;;
				b)
					break
					;;
				1)
					RESTORE_WIDGETS=("${WIDGET_LAYOUTS[@]}")
					break 2
					;;
				2)
					while true; do
						echo
						echo "========================================"
						echo "Select Widgets to Restore"
						echo "========================================"

						i=1
						declare -A WIDGET_NAMES
						widget_idx=1
						while IFS='|' read -r w_type w_screen w_cellX w_cellY w_spanX w_spanY w_provider; do
							[ "$w_type" != "WIDGET" ] && continue
							short_prov=$(echo "$w_provider" | awk -F'.' '{print $NF}')
							echo "  $i) $short_prov (screen $w_screen)"
							WIDGET_NAMES[$i]="$w_type|$w_screen|$w_cellX|$w_cellY|$w_spanX|$w_spanY|$w_provider"
							i=$((i + 1))
						done < <(cat "${WIDGET_LAYOUTS[@]}")

						echo
						echo "Enter numbers separated by comma (e.g. 1,3,5)"
						echo
						echo "b) Back"
						echo
						echo "0) Exit"
						echo
						read -rp "Select: " widget_sel

						case "$widget_sel" in
						0)
							exit_script
							;;
						b)
							unset WIDGET_NAMES
							break 2
							;;
						*)
							RESTORE_WIDGETS=()
							IFS=',' read -ra WNUMS <<<"$widget_sel"
							for wn in "${WNUMS[@]}"; do
								wn=$(echo "$wn" | tr -d ' ')
								if [ -n "${WIDGET_NAMES[$wn]}" ]; then
									RESTORE_WIDGETS+=("${WIDGET_NAMES[$wn]}")
								fi
							done
							if [ ${#RESTORE_WIDGETS[@]} -gt 0 ]; then
								unset WIDGET_NAMES
								break 3
							else
								echo "[!] No valid widgets selected"
							fi
							;;
						esac
					done
					;;
				*)
					echo "[!] Invalid choice"
					;;
				esac
			done
			;;
		b)
			break
			;;
		0)
			exit_script
			;;
		*)
			echo "[!] Invalid choice"
			;;
		esac
	done

	if [ -z "$restore_mode" ] || [ "$restore_mode" = "b" ]; then
		continue
	fi

	RESTORE_ALL=0
	RESTORE_ONLY_WIDGETS=0
	if [ "$restore_mode" = "1" ]; then
		RESTORE_ALL=1
	elif [ "$restore_mode" = "3" ]; then
		RESTORE_ONLY_WIDGETS=1
	fi

	########################################
	# Start Restoration
	########################################
	for DB in "${SELECTED_DBS[@]}"; do
		echo
		echo "========================================"
		echo "Processing: $(basename "$DB")"
		echo "========================================"
		echo

		backup="${DB}.$(date +%d-%m-%Y_%H-%M-%S).bak"
		cp -a "$DB" "$backup"
		echo "Backup created"
		echo

		if [ "$RESTORE_ONLY_WIDGETS" -ne 1 ]; then
			for LAYOUT in "${RESTORE_FOLDERS[@]}"; do

				if grep -q '^FOLDER ' "$LAYOUT"; then
					LAYOUT_TYPE="folder"
				else
					LAYOUT_TYPE="desktop"
				fi

				if [ "$LAYOUT_TYPE" = "folder" ]; then
					folder_name=$(grep '^FOLDER ' "$LAYOUT" | head -n1 | cut -d' ' -f2-)
					safe_folder_name=$(sql_escape "$folder_name")
				fi

				desktop_screen=$(grep '^SCREEN ' "$LAYOUT" | awk '{print $2}')
				cellX=$(grep '^CELLX ' "$LAYOUT" | awk '{print $2}')
				cellY=$(grep '^CELLY ' "$LAYOUT" | awk '{print $2}')

				[ -n "$desktop_screen" ] || {
					echo "ERROR: no SCREEN line"
					continue
				}
				[ -n "$cellX" ] || {
					echo "ERROR: no CELLX line"
					continue
				}
				[ -n "$cellY" ] || {
					echo "ERROR: no CELLY line"
					continue
				}

				db_cellX=$((cellX - 1))
				db_cellY=$((cellY - 1))

				shortcut_count=$(grep -Ev '^(FOLDER|SCREEN|CELLX|CELLY) ' "$LAYOUT" | grep -c '^[^[:space:]]')

				[ "$shortcut_count" -gt 0 ] || {
					echo "ERROR: no shortcuts in layout"
					continue
				}

				# Вертификация
				missing=0
				declare -A ID_MAP

				while IFS='|' read -r col1 col2 col3 col4 col5; do
					[ -z "$col1" ] && continue

					if [ -n "$col5" ]; then
						title="$col1"
						profile_id="$col2"
						hex_intent="$col3"

						profile_cond="AND IFNULL(profileId, 0)=$profile_id"
						if [ "$hex_intent" = "NONE" ]; then
							intent_cond="AND intent IS NULL"
						else
							intent_cond="AND UPPER(hex(intent))='$hex_intent'"
						fi
					else
						title="$col1"
						profile_id="0"
						hex_intent="NONE"
						profile_cond=""
						intent_cond=""
					fi

					safe_title=$(sql_escape "$title")
					sids=$(sqlite3 "$DB" "SELECT _id FROM favorites WHERE title='$safe_title' $profile_cond $intent_cond;")
					count=$(echo "$sids" | awk 'NF{c++} END{print c+0}')

					if [ "$count" -gt 1 ]; then
						sid=$(echo "$sids" | head -n 1)
					elif [ -z "$sids" ]; then
						echo "[!] Missing in DB: $title"
						missing=$((missing + 1))
						continue
					else
						sid="$sids"
					fi

					key=$(printf '%s\037%s\037%s' "$title" "$profile_id" "$hex_intent")
					if [[ -v ID_MAP["$key"] ]]; then continue; fi
					ID_MAP["$key"]="$sid"

				done < <(grep -Ev '^(FOLDER|SCREEN|CELLX|CELLY) ' "$LAYOUT" | grep -v '^[[:space:]]*$')

				[ "$missing" -eq 0 ] || {
					echo "Folder: $folder_name - Aborting"
					continue
				}

				# Ищем/создаем папку
				folder_id=$(sqlite3 "$DB" "SELECT _id FROM favorites WHERE title='$safe_folder_name' AND itemType=2 LIMIT 1;")

				if [ -z "$folder_id" ]; then
					next_id=$(sqlite3 "$DB" "SELECT IFNULL(MAX(_id),0)+1 FROM favorites;")
					sqlite3 "$DB" "
              INSERT INTO favorites (_id, title, container, screen, cellX, cellY, spanX, spanY, itemType, appWidgetId, itemFlags, profileId, originWidgetId)
              VALUES ($next_id, '$safe_folder_name', -100, $desktop_screen, $db_cellX, $db_cellY, 1, 1, 2, -1, 0, 0, -1);"
					folder_id=$next_id
				fi
				echo "Folder: $folder_name [$folder_id]"

				# Восстанавливаем иконки (Без казино)
				curr_item=0
				while IFS='|' read -r col1 col2 col3 col4 col5; do
					[ -z "$col1" ] && continue

					if [ -n "$col5" ]; then
						title="$col1"
						profile_id="$col2"
						hex_intent="$col3"
						db_shortcut_cellX=$((col4 - 1))
						db_shortcut_cellY=$((col5 - 1))
					else
						title="$col1"
						profile_id="0"
						hex_intent="NONE"
						db_shortcut_cellX=$col2
						db_shortcut_cellY=$col3
					fi

					key=$(printf '%s\037%s\037%s' "$title" "$profile_id" "$hex_intent")
					shortcut_id="${ID_MAP["$key"]}"

					curr_item=$((curr_item + 1))

					if [ -n "$shortcut_id" ]; then
						sqlite3 "$DB" "UPDATE favorites SET container=$folder_id, screen=-1, cellX=$db_shortcut_cellX, cellY=$db_shortcut_cellY WHERE _id=$shortcut_id;"
						echo "  [$curr_item/$shortcut_count] $title"
					else
						echo "  [!] Warning: Could not find ID for $title in map"
					fi

				done < <(grep -Ev '^(FOLDER|SCREEN|CELLX|CELLY) ' "$LAYOUT" | grep -v '^[[:space:]]*$')
			done
		fi

		# Восстанавливаем рабочие столы только при полном восстановлении
		if [ "$RESTORE_ALL" -eq 1 ]; then
			echo "Restoring Desktops..."
			for LAYOUT2 in "${DESKTOP_LAYOUTS[@]}"; do
				desktop_screen=""
				total_d=$(grep -c '|' "$LAYOUT2" || true)
				curr_d=0

				while IFS= read -r line; do
					[ -z "$line" ] && continue

					if [[ "$line" == SCREEN\ * ]]; then
						desktop_screen=$(echo "$line" | awk '{print $2}')
						continue
					fi

					IFS='|' read -r title profile_id hex_intent cellX cellY <<<"$line"
					[ -z "$title" ] && continue
					safe_title=$(sql_escape "$title")

					profile_cond="AND IFNULL(profileId, 0)=$profile_id"
					if [ "$hex_intent" = "NONE" ]; then
						intent_cond="AND intent IS NULL"
					else
						intent_cond="AND UPPER(hex(intent))='$hex_intent'"
					fi

					sid=$(sqlite3 "$DB" "SELECT _id FROM favorites WHERE title='$safe_title' $profile_cond $intent_cond LIMIT 1;")
					[ -n "$sid" ] || continue

					db_shortcut_cellX=$((cellX - 1))
					db_shortcut_cellY=$((cellY - 1))

					sqlite3 "$DB" "UPDATE favorites SET container=-100, screen=$desktop_screen, cellX=$db_shortcut_cellX, cellY=$db_shortcut_cellY WHERE _id=$sid;"

					curr_d=$((curr_d + 1))
					echo "  [$curr_d/$total_d] $title"
				done <"$LAYOUT2"
			done

			# Восстанавливаем док (Без казино)
			echo "Restoring Dock..."
			for LAYOUT_DOCK in "${DOCK_LAYOUTS[@]}"; do
				total_dock=$(grep -c '^DOCK|' "$LAYOUT_DOCK" || true)
				curr_dock=0

				while IFS='|' read -r d_type d_cellX d_cellY d_title d_profile_id d_hex_intent; do
					[ "$d_type" != "DOCK" ] && continue

					safe_d_title=$(sql_escape "$d_title")

					profile_cond="AND IFNULL(profileId, 0)=$d_profile_id"
					if [ "$d_hex_intent" = "NONE" ]; then
						intent_cond="AND intent IS NULL"
					else
						intent_cond="AND UPPER(hex(intent))='$d_hex_intent'"
					fi

					sid=$(sqlite3 "$DB" "SELECT _id FROM favorites WHERE title='$safe_d_title' $profile_cond $intent_cond LIMIT 1;")

					curr_dock=$((curr_dock + 1))

					if [ -n "$sid" ]; then
						sqlite3 "$DB" "UPDATE favorites SET container=-101, cellX=$((d_cellX - 1)), cellY=$((d_cellY - 1)) WHERE _id=$sid;"
						echo "  [$curr_dock/$total_dock] $d_title"
					else
						echo "  [!] Warning: Dock item $d_title not found in DB"
					fi
				done <"$LAYOUT_DOCK"
			done
		fi

		# Восстанавливаем виджеты
		if [ ${#RESTORE_WIDGETS[@]} -gt 0 ]; then
			echo "Restoring Widgets..."

			if [ "$RESTORE_ALL" -eq 1 ] || ([ "$RESTORE_ONLY_WIDGETS" -eq 1 ] && [ ${#RESTORE_WIDGETS[@]} -eq ${#WIDGET_LAYOUTS[@]} ]); then
				# Восстанавливаем все виджеты из файлов
				total_w=0
				for LAYOUT3 in "${WIDGET_LAYOUTS[@]}"; do
					total_w=$((total_w + $(grep -c '^WIDGET|' "$LAYOUT3" || true)))
				done

				curr_w=0
				for LAYOUT3 in "${WIDGET_LAYOUTS[@]}"; do
					while IFS='|' read -r w_type w_screen w_cellX w_cellY w_spanX w_spanY w_provider; do
						[ "$w_type" != "WIDGET" ] && continue

						sid=$(sqlite3 "$DB" "SELECT _id FROM favorites WHERE itemType=4 AND appWidgetProvider='$w_provider' LIMIT 1;")

						curr_w=$((curr_w + 1))
						short_prov=$(echo "$w_provider" | awk -F'.' '{print $NF}')

						if [ -n "$sid" ]; then
							sqlite3 "$DB" "UPDATE favorites SET screen=$w_screen, cellX=$((w_cellX - 1)), cellY=$((w_cellY - 1)), spanX=$w_spanX, spanY=$w_spanY WHERE _id=$sid;"
							echo "  [$curr_w/$total_w] $short_prov"
						else
							echo "  [!] Warning: Widget $short_prov not found in DB"
						fi
					done <"$LAYOUT3"
				done
			else
				# Восстанавливаем выбранные виджеты
				total_w=${#RESTORE_WIDGETS[@]}
				curr_w=0

				for widget_data in "${RESTORE_WIDGETS[@]}"; do
					IFS='|' read -r w_type w_screen w_cellX w_cellY w_spanX w_spanY w_provider <<<"$widget_data"

					sid=$(sqlite3 "$DB" "SELECT _id FROM favorites WHERE itemType=4 AND appWidgetProvider='$w_provider' LIMIT 1;")

					curr_w=$((curr_w + 1))
					short_prov=$(echo "$w_provider" | awk -F'.' '{print $NF}')

					if [ -n "$sid" ]; then
						sqlite3 "$DB" "UPDATE favorites SET screen=$w_screen, cellX=$((w_cellX - 1)), cellY=$((w_cellY - 1)), spanX=$w_spanX, spanY=$w_spanY WHERE _id=$sid;"
						echo "  [$curr_w/$total_w] $short_prov"
					else
						echo "  [!] Warning: Widget $short_prov not found in DB"
					fi
				done
			fi
		fi

		echo "Verifying database..."
		result=$(sqlite3 "$DB" "PRAGMA integrity_check;")
		[ "$result" = "ok" ] || {
			echo "ERROR: integrity_check failed"
		}
		echo "DB OK. Done."

	done

	########################################
	# Reboot Launcher
	########################################
	/system/bin/am force-stop com.miui.home

	break
done
