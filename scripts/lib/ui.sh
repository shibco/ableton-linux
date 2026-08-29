# shellcheck shell=bash
# The installer's renderer. Every sentence the installer shows lives in the
# dictionary below; the functions after "# END UI_TEXT" draw the nested tree
# from it. Edit the right-hand side of an entry to change what people read.
# %s placeholders are filled in the order the comment gives.
#
# Environment: ABLETON_UI_ACTION (which step list applies), ABLETON_UI_KIT=1
# (rendering under the .run header, whose "prepare" step comes first),
# ABLETON_UI_TTY_FD (the terminal; unset means stdout, static),
# ABLETON_UI_CHARSET (utf8|ascii, captured before LC_ALL is exported),
# ABLETON_UI_PROMPT_TIMEOUT (seconds, minimum 1), ABLETON_INSTALLER_LOG.

declare -A UI_TEXT=(
    # ---- glyphs, UTF-8 set --------------------------------------------------
    [g_trunk]='│'          [g_branch]='├─'        [g_last]='└─'
    [g_sub_trunk]='│'      [g_step_join]='├──'    [g_ok]='✓'
    [g_fail]='𐄂'           [g_info]='🛈'          [g_warn]='⚠'
    [g_detail]='>'         [g_ellipsis]='…'
    [g_box_top]='╒═╤═╕'    [g_box_rule]='├┈┴┈┤'   [g_box_side]='│'
    [g_box_bottom]='╞═╛'   [g_box_sep]='┊'
    [g_step_top]='┲━┳━┓'   [g_step_mid]='┃╏┃'     [g_step_bottom]='┡━┻━┛'
    [g_foot_top]='╞═╤═╕'   [g_foot_rule]='├─┼─┤'  [g_foot_dash]='├┈┼┈┤'
    [g_foot_merge]='├┈┴┈┤' [g_foot_bottom]='╘═╛'
    [g_spinner]='⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷ ⠁ ⠂ ⠄ ⡀ ⢀ ⠠ ⠐ ⠈'

    # ---- glyphs, ASCII set (used when the locale is not UTF-8) --------------
    [a_trunk]='|'          [a_branch]='|-'        [a_last]='`-'
    [a_sub_trunk]='|'      [a_step_join]='|--'    [a_ok]='+'
    [a_fail]='x'          [a_info]='i'         [a_warn]='!'
    [a_detail]='>'         [a_ellipsis]='...'
    [a_box_top]='+=+=+'    [a_box_rule]='+-+-+'   [a_box_side]='|'
    [a_box_bottom]='+=+'   [a_box_sep]='|'
    [a_step_top]='+=+=+'   [a_step_mid]='|:|'     [a_step_bottom]='+=+=+'
    [a_foot_top]='+=+=+'   [a_foot_rule]='+-+-+'  [a_foot_dash]='+-+-+'
    [a_foot_merge]='+-+-+' [a_foot_bottom]='+=+'
    [a_spinner]='- \ | /'

    # ---- banner ---------------------------------------------------------------
    [banner_title]='ABLETON-LINUX INSTALLER'
    [banner_version]='v %s'                                       # version
    [banner_url]='https://github.com/shibco/ableton-linux/'

    # ---- headings -------------------------------------------------------------
    [h_system]='System Check'
    [h_disk]='Disk Space'
    [h_warnings]='Warnings'
    [h_action]='Ableton-Linux Installer Choice:'
    [h_found_at]='Found Ableton Live install files at'
    [h_candidates]='Found multiple Ableton Live install candidates:'

    # ---- System Check rows ----------------------------------------------------
    [r_date]='Date and time'
    [r_distro]='Distribution'
    [r_kernel]='Kernel'
    [r_cpu]='CPU'
    [r_gpu]='GPU'
    [r_memory]='Memory'
    [r_desktop]='Desktop'
    [r_pipewire]='PipeWire'
    [r_deps]='Dependencies'
    [r_temp]='Temporary'
    [r_install]='Installation'
    [r_kit]='Kit workspace'
    [v_unavailable]='unavailable'
    [v_desktop]='%s (%s)'                                         # desktop, session type
    [v_deps_ready]='%s (ready)'                                   # list
    [v_deps_missing]='missing: %s'                                # list
    [v_free_at]='%s free at %s'                                   # size, path
    [v_free_under]='%s free under %s'                             # size, path
    [v_required]='%s required'                                    # size

    # ---- host warnings --------------------------------------------------------
    [w_none]='No host warnings found.'
    [w_not_linux]='This installer requires Linux.'
    [w_not_x86_64]='Ableton Linux currently requires an x86_64 host.'
    [w_missing_command]='Required command is missing: %s.'       # name
    [w_temp_small]='Temporary storage is too small for the embedded installer kit.'
    [w_home_small]='Less than 10 GiB is free for Wine, the prefix, and Live.'
    [w_no_display]='No graphical desktop display was detected; Live cannot open without one.'
    [w_pipewire_unknown]='PipeWire could not be identified; the installer will run its bundled compatibility check before changing audio support.'
    [w_pipewire_old]='PipeWire %s is older than the required %s.' # found, floor

    # ---- action menu ----------------------------------------------------------
    [m_install]='[I]nstall'
    [m_update]='[U]pdate'
    [m_reinstall]='[R]einstall'
    [m_remove]='Remo[v]e Ableton Linux'
    # m_exit remains for renderer/API compatibility with callers of ui.sh.
    [m_exit]='E[x]it'
    [m_quit]='[Q]uit'
    [m_default_hint]=' (or press Enter)'
    [m_prompt]='Choose an action:'
    [m_unknown]='Unknown action: %s'                              # answer
    [m_uninstall_scope]='Choose what to remove'
    [m_uninstall_runtime]='Runtime only[R]'
    [m_uninstall_prefix]='Prefix only[P]'
    [m_uninstall_all]='All[A]'
    [m_uninstall_exit]='Exit[E]'
    [m_uninstall_prompt]='Choose an uninstall scope:'
    [m_uninstall_unknown]='Unknown uninstall scope: %s'            # answer
    [label_update]='Update'
    [label_install]='Install'
    [label_reinstall]='Reinstall'
    [label_remove]='Remove'
    [label_runtime]='Install Wine runtime'
    [label_prefix]='Wine prefix %s'                               # subcommand
    [label_link]='Ableton Link %s'                                # subcommand
    [label_extract]='Extract installer kit'
    [label_plan]='Show installation plan'

    # ---- Live installer candidates --------------------------------------------
    [c_item]='[%s] %s'                                            # number, file name
    [c_dir]='%s'                                                  # directory
    [c_prompt]='Which one?:'
    [c_hint]='(Press Enter for [1] or wait %s seconds)'          # seconds
    [c_none]='No Ableton Live installer was found in %s. Copy the Live download next to the installer, or run with --live-installer FILE or --skip-live-install.'
    [c_invalid]='No valid installer was selected.'

    # ---- questions inside a step ----------------------------------------------
    [q_title]='QUESTION: %s'                                      # title
    [q_default_tag]=' (Default)'
    [q_prompt]='Which one?:'
    [q_hint]='(Press Enter for default or wait %s seconds)'      # seconds
    [q_current_tag]=' (Current)'
    [q_back_hint]='Press Esc to go back'
    [q_buffer_title]='1/6 Audio buffer'
    [q_buffer_explanation]='Lower numbers reduce audio delay; higher numbers are less likely to crackle.'
    [q_buffer_64]='[1] 64 frames'
    [q_buffer_128]='[2] 128 frames'
    [q_buffer_256]='[3] 256 frames'
    [q_buffer_512]='[4] 512 frames'
    [q_buffer_1024]='[5] 1024 frames'
    [q_buffer_custom]='%s frames'
    [q_shortcuts_title]='2/6 Keyboard shortcuts'
    [q_shortcuts_explanation]='On GNOME, Assign to Live lets Live use conflicting desktop shortcuts until Live closes.'
    [q_shortcuts_take]='[A] Assign to Live'
    [q_shortcuts_preserve]='[P] Preserve desktop shortcuts'
    [q_dpi_title]='3/6 Display scaling'
    [q_dpi_explanation]='Automatic matches your desktop; 100%% is normal, Fractional suits scaled displays, and Preserve changes nothing.'
    [q_dpi_auto]='[A] Automatic'
    [q_dpi_100]='[1] 100%%'
    [q_dpi_fractional]='[F] Fractional'
    [q_dpi_preserve]='[P] Preserve'
    [q_threads_title]='4/6 Audio workers'
    [q_threads_explanation]='Automatic chooses how many workers suit your CPU; Let Live decide uses Live'\''s own setting, or enter 1–63 yourself.'
    [q_threads_auto]='[A] Automatic'
    [q_threads_off]='[L] Let Live decide'
    [q_threads_custom]='[1-63] Enter a custom value from 1 to 63'
    [q_threads_value]='%s workers'
    [q_threads_invalid]='Choose Automatic, Let Live decide, or a number from 1 to 63.'
    [q_rt_title]='5/6 Real-time scheduling'
    [q_rt_explanation]='Automatic uses higher CPU priority when allowed and Normal uses standard priority; neither changes permissions.'
    [q_rt_auto]='[A] Automatic'
    [q_rt_off]='[N] Normal scheduling'
    [q_power_title]='6/6 Power profile'
    [q_power_explanation]='Performance favors speed, Balanced saves power, and Don'\''t change keeps the current mode while Live or Max is open.'
    [q_power_performance]='[P] Performance'
    [q_power_balanced]='[B] Balanced'
    [q_power_off]='[O] Don'\''t change'
    [q_choice_invalid]='Choose one of the listed options.'
    [q_overwrite_title]='Some files from an earlier installation already exist.'
    [q_overwrite_all]='[O]verwrite all'
    [q_keep]='[K]eep originals'
    [q_abort]='[A]bort'
    [q_overwrite_chosen]='Existing files will be moved to %s before they are replaced.'   # backup dir
    [q_keep_chosen]='Existing files are kept unchanged; new files are written only where nothing exists.'
    [q_abort_chosen]='Stopping before any existing file is replaced.'
    [q_stop_prefix_title]='A program is still using the Wine prefix.'
    [q_stop_prefix_end]='[E]nd every program in the prefix'
    [q_stop_prefix_leave]='[L]eave it running'
    [q_stop_wine_title]='Wine processes are still running. Quit them before continuing?'
    [q_stop_wine_yes]='[Y]es - quit them and continue'
    [q_stop_wine_no]='[N]o - exit the installer'

    # ---- steps ----------------------------------------------------------------
    [s_prepare]='Prepare the installer kit'
    [s_validate]='Check the host and the request'
    [s_runtime_install]='Install the Wine runtime'
    [s_runtime_update]='Update the Wine runtime'
    [s_prefix_create]='Prepare the Wine prefix'
    [s_prefix_update]='Update the Wine prefix'
    [s_prefix_repair]='Repair Live 11 preferences'
    [s_live]='Install Ableton Live'
    [s_launchers]='Install launchers and shortcuts'
    [s_link_settings]='Configure Ableton Link and save settings'
    [s_link]='Configure Ableton Link'
    [s_link_status]='Show Ableton Link status'
    [s_remove]='Remove Ableton Linux'
    [s_plan]='Show the plan'
    [s_extract]='Extract the installer kit'
    [s_finish_install]='Finish the installation'
    [s_finish_update]='Finish the update'
    [s_finish_runtime]='Finish the Wine runtime install'
    [s_finish_prefix]='Finish the Wine prefix setup'
    [s_finish_link]='Finish the Ableton Link change'
    [s_complete]='Step %s Complete!'                              # number
    [s_failed]='Step %s Failed!'                                  # number
    [i_done]='Done.'
    [i_failed]='Failed.'

    # ---- .run header items (before the kit exists) ----------------------------
    [i_copy]='Copy the embedded kit'
    [i_copy_done]='Copied %s MiB.'                                # total
    [i_check]='Check the embedded kit'
    [i_check_done]='The kit is intact.'
    [i_extract]='Extract the embedded kit'
    [i_extract_to]='Extracted the kit to %s.'                     # dir
    [i_progress]='(%s / %s MiB)'                                  # done, total
    [e_copy]='The embedded installer kit could not be copied.'
    [e_check]='The embedded installer kit could not be checked.'
    [e_integrity]='The installer integrity check failed. Download or copy the .run file again.'
    [e_extract]='The embedded installer kit could not be extracted.'
    [e_damaged]='This installer file is incomplete or damaged. Download it again.'
    [e_workspace]='The installer could not create its temporary workspace under %s.'   # dir
    [e_temp_left]='The installer finished, but temporary files remain at %s.'          # dir
    [e_extract_args]='extract needs one destination directory.'

    # ---- footer ---------------------------------------------------------------
    [f_title]='Ableton-Linux %s v. %s'                            # action label, version
    [f_complete]='Complete'
    [f_failed]='Failed'
    [f_interrupted]='Interrupted'
    [f_cancelled]='Cancelled'
    [f_time]='Time taken:'
    [f_seconds]='%s sec'                                          # seconds
    [f_warnings]='Warnings:'
    [f_errors]='Errors:'
    [f_runtime]='runtime:'
    [f_prefix]='prefix:'

    # ---- tail (plain text after the footer) -----------------------------------
    [t_launch]='Launch Ableton Live via your desktop applications launcher or in the terminal:'
    [t_launch_cmd]='> $ ableton-live'
    [t_bsky_h]='Stay up to date:'
    [t_bsky]='https://bsky.app/profile/wires.sh'
    [t_discord_h]='Ableton on Linux Discord:'
    [t_discord]='https://discord.gg/XD5EeZyP3'
    [t_help_h]='Need help?'
    [t_help]='https://github.com/shibco/ableton-linux'
    [t_report_h]='Report this error:'
    [t_report]='https://github.com/shibco/ableton-linux/issues'
    [t_errors_h]='Errors:'
    [t_error_item]='> %s'                                         # message
    [t_log_h]='Saved a log of this operation at'
    [t_log_none]='The installer could not save its log.'

    # ---- help -----------------------------------------------------------------
    [help_title]='Ableton Linux installer'
    [help_commands]='install, update, runtime install, prefix create|update|repair-live11, link enable|disable|status, uninstall, extract DIR, plan COMMAND ...'
    [help_menu]='Run without a command for the interactive action menu.'

    # ---- sentences owned by the installer scripts -----------------------------
    # Keys start with the script: d_ installer.sh, i_ install.sh,
    # p_ setup-prefix.sh, l_ setup-link.sh, u_ uninstall.sh, m_ manifest.sh,
    # pa_ pipeasio.sh.
    [d_plan_prefix_update_line]='Update the Ableton Wine prefix at %s'   # prefix
    [d_plan_prefix_create_line]='Create the Ableton Wine prefix at %s'   # prefix
    [d_sum_updated]='Ableton is updated'
    [d_sum_live_installed]='Ableton Live %s is installed'                # major
    [d_sum_runtime_prefix_ready]='The Ableton runtime and Wine prefix are ready'
    [d_deprecated_option]='%s is deprecated; use %s instead.'             # old, new
    [i_integration_partial]='Some shortcuts or support files could not be updated.'
    [i_kept_files]='Kept %s existing files unchanged.'                   # count
    [i_runtime_ready]='The Wine runtime is ready.'
    [m_kept_file]='Kept existing file unchanged: %s.'                    # path
    [d_link_files_retry]='Some Ableton Link support files need another try.'
    [d_settings_kept]='Saved settings were kept unchanged.'
    [d_prefix_held_unknown]='The Live installer finished, but a program is still using its Wine prefix:'
    [d_prefix_held_background]='The Live installer finished; a background program is still using its Wine prefix.'
    [d_prefix_held_hint]='You can leave it running. To stop every program in the prefix instead, run:'
    [m_overwrite_all_failed]='Overwrite all could not be saved for this installer run. This file was left unchanged.'
    # -- scripts/installer.sh --
    [d_plan_prefix_create]='Create the Wine prefix %s using the runtime at %s'
    [d_plan_prefix_update]='Update the Ableton Wine prefix at %s'
    [d_plan_repair_live11]='Move aside stale Live 11 Max preferences in %s'
    [d_plan_pipeasio_config]='Configure PipeASIO at %s/pipeasio/config.ini'
    [d_plan_run_live_installer]='Run the Live %s installer: %s'
    [d_plan_save_settings]='Save installer settings to %s'
    [d_plan_link_mode]='Set Ableton Link mode to %s'
    [d_link_enabled]='Ableton Link is enabled (%s)'
    [d_link_off]='Ableton Link is off.'
    [d_reusing_extracted_installer]='Reusing the extracted Live installer at %s'
    [d_extract_live_installer]='Extract the Live installer (up to %s seconds)'
    [d_run_live_installer]='Run the Live installer (up to %s seconds)'
    [d_prefix_holder_entry]='%s (pid %s)'
    [d_prefix_held_command]='WINEPREFIX=%s %s/bin/wineserver -k'
    [d_prefix_programs_stopped]='Stopped the programs in the prefix'
    [d_prefix_programs_left]='Left them running; the next update may ask you to close them'
    [d_link_configured_mode]='Ableton Link is set to %s mode'
    [d_settings_ready]='Saved settings are ready'
    [d_sum_runtime_installed]='The Wine runtime is installed'
    [d_sum_runtime_path]='Runtime: %s'
    [d_sum_prefix_path]='Prefix: %s'
    [d_sum_shortcuts_retry]='Desktop shortcuts need another try'
    [d_sum_link_retry]='Link is unchanged; you can retry its setup'
    [d_settings_retry]='Saved settings need another try'
    [d_sum_recovery_files_remain]='Old recovery files remain at %s'
    [d_sum_prefix_ready]='The Wine prefix is ready'
    [d_sum_prefix_updated]='The Wine prefix is updated'
    [d_sum_command_completed]='%s%s completed'
    # -- scripts/install.sh --
    [i_check_wine_package]='Check the Wine package %s'
    [i_wine_package_valid]='%s is valid'
    [i_unpack_runtime]='Unpack the Wine runtime'
    [i_runtime_checks_passed]='The Wine runtime passed its checks'
    [i_validate_ok]='The selected files passed all checks'
    [i_plan_heading]='Resolved configuration'
    [i_plan_runtime]='Install or update Wine at %s'
    [i_plan_panel_shortcuts]='Update the PipeASIO Settings shortcuts to match this Wine build'
    [i_plan_integration]='Install or update launchers, desktop shortcuts, file-opening support, and icons'
    [i_plan_tools]='Install diagnostic and recovery tools'
    [i_plan_max9]='Install or update the Max 9 launcher and file-opening support'
    [i_plan_link]='Install or update Ableton Link support'
    [i_plan_link_external]='Use the configured Ableton Link helper and leave it unchanged: %s'
    [i_plan_backups]='Back up each replaced project file under %s/backups'
    [i_q_stop_clients]='Stop every program in this prefix (including Live or Max)?'
    [i_setup_launchers]='Set up Ableton launchers and desktop shortcuts'
    [i_refresh_desktop_menus]='Refresh desktop menus and file associations'
    [i_install_link_files]='Install Ableton Link support files'
    [i_link_helper_external]='Using the configured Ableton Link helper at %s and leaving it unchanged'
    [i_panel_files_available]='Launcher setup continues with the PipeASIO files that are available'
    [i_backed_up_files]='Backed up %s replaced files in this step'
    [i_launchers_ready]='Launchers, shortcuts, and file support are ready'
    [i_link_files_ready]='Ableton Link support files are ready'
    [i_hint_audio_report]='Audio report: %s/audio-report.sh'
    [i_hint_ntsync_check]='NTSync check: %s/check-ntsync.sh'
    [i_hint_realtime_setup]='Realtime setup: %s/setup-realtime.sh'
    [i_hint_rollback]='Restore previous Wine version: %s/rollback.sh'
    # -- scripts/setup-prefix.sh --
    [p_using_existing_prefix]='Using the existing Wine prefix at %s'
    [p_settings_valid]='Wine prefix settings are valid'
    [p_repair_moved]='Max preferences moved aside; Max regenerates them on next start'
    [p_repair_nothing]='No Live 11 Max preferences needed repair'
    [p_copy_existing_prefix]='Copy the existing Wine prefix'
    [p_options_line_removed]='Removed %s from %s'
    [p_options_file_removed]='Removed %s because it contained only %s'
    [p_scale_detected]='Detected display scale %s (%s); applying %s scaling settings'
    [p_scale_already_configured]='Display scaling is already set for scale %s'
    [p_scale_undetected_existing]='Display scale could not be detected, so existing settings were kept'
    [p_zip_live_major]='%s is Live %s; preparing its required Windows support files'
    [p_prepare_wine]='Prepare Wine at %s'
    [p_update_prefix_files]='Update Wine prefix files'
    [p_keep_fonts_support]='Keep the installed Windows fonts and support files'
    [p_install_fonts_support]='Install Windows fonts and support files for Live %s'
    [p_using_bundled_cache]='Using the bundled dependency cache'
    [p_install_m4l_fonts]='Install Max for Live fallback fonts'
    [p_check_vc]='Check Microsoft Visual C++ support'
    [p_vc_install_from_live]='Installing the Microsoft Visual C++ files included with Live'
    [p_vc_already_installed]='Required Microsoft Visual C++ files are already installed'
    [p_vc_installing_file]='Installing %s'
    [p_configure_scaling]='Configure display scaling'
    [p_scaling_kept]='Existing display scaling settings were kept'
    [p_scaling_deferred_to_launch]='Live-specific scaling is applied automatically when Live first starts'
    [p_configure_theme]='Configure the desktop theme'
    [p_theme_applying]='Applying the %s theme'
    [p_theme_kept]='Existing theme settings were kept'
    [p_configure_text]='Configure text rendering'
    [p_subpixel_bgr]='Using BGR subpixel order'
    [p_subpixel_rgb]='Using RGB subpixel order'
    [p_configure_pipeasio]='Configure PipeASIO audio'
    [p_pipeasio_settings_created]='Created default PipeASIO settings at %s'
    [p_pipeasio_settings_kept]='Kept the existing PipeASIO settings at %s'
    [p_pipeasio_settings_link_kept]='Kept your PipeASIO settings link even though its target is missing: %s'
    [p_configure_dialogs_push]='Configure file dialogs and Push USB access'
    [p_removing_obsolete_shortcut]='Removing an obsolete desktop shortcut: %s'
    [p_remove_obsolete_audio_setting]='Remove an obsolete Live audio setting'
    [p_enable_gpu_renderer]='Enable Live'\''s GPU renderer'
    [p_check_live]='Check Ableton Live'
    [p_live_installed]='Live is already installed'
    [p_live_install_pending]='The installer installs Live after Wine setup finishes'
    [p_live_installed_unchanged]='Live is already installed and was left unchanged'
    [p_live_autoinstall_disabled]='Automatic Live installation is disabled'
    [p_live_zip_found]='Found %s. Set ABLETON_LIVE_AUTOINSTALL=1 to install it'
    [p_live_zip_missing_hint]='Put the official ableton.com zip there, or set ABLETON_INSTALLER_DIR to its directory'
    [p_live_eula_note]='Ableton'\''s license agreement appears when Live first starts'
    [p_live_autoinstall_hint]='To install your own Ableton download automatically, place it in %s and set ABLETON_LIVE_AUTOINSTALL=1'
    [p_live_unpacking]='Unpacking %s'
    [p_live_installer_window]='Starting the Ableton installer. Follow the installer window'
    [p_live_installing]='Installing Ableton Live. This can take a few minutes'
    [p_prefix_ready]='Ableton Wine prefix is ready'
    [p_wine_ready_at]='Wine is ready at %s'
    [p_remaining_steps_licensed]='Remaining steps (you supply your own license):'
    [p_remaining_step1_installed]='1. Live is installed; nothing more to supply here'
    [p_remaining_steps_unlicensed]='Remaining steps (you supply Ableton and your own license):'
    [p_remaining_step1_install]='1. Install Live (any edition) through this Wine (plain wine reads WINEPREFIX, not the ABLETON_* launcher variables). For Live 12 these flags let the installer run by itself and skip Ableton'\''s Windows USB audio driver, which does nothing on Linux: WINEPREFIX=%s %s/bin/wine "/path/to/Ableton Live 12 Edition Installer.exe" /SILENT /SUPPRESSMSGBOXES /NORESTART '\''/MERGETASKS=!audiodriver'\''. Live 11'\''s installer is a WiX Burn bundle and ignores those flags; run it without them and click through its window'
    [p_remaining_step2_launch]='2. Launch: ableton-live'
    [p_remaining_step3_authorize]='3. Authorize Live with your own account (this binds to the prefix'\''s MachineGuid)'
    [p_remaining_step4_audio]='4. Audio: Settings/Preferences > Audio > Driver Type: ASIO > Audio Device: PipeASIO. PipeASIO is a native PipeWire client with no JACK layer involved'
    # -- scripts/setup-link.sh --
    [l_remove_ufw_rule]='Removing the ufw rule added for Ableton Link'
    [l_remove_firewalld_rule]='Removing the firewalld rule added for Ableton Link'
    [l_remove_multicast_hook]='Removing the old Ableton Link multicast hook'
    [l_turn_off_link]='Turn off Ableton Link'
    [l_kept_pr182_helper]='Kept the older custom Link helper at %s'
    [l_kept_external_helper]='Kept the external Link helper at %s'
    [l_off_unsaved]='Ableton Link is off; run the installer again to save that preference'
    [l_off]='Ableton Link is off'
    [l_off_residual]='Ableton Link is off; a later installer run can clean up some obsolete local files'
    [l_check_ufw_rule]='Checking the ufw rule for Link (UDP 20808)'
    [l_restore_ufw_rule]='Restoring the missing ufw rule for Link'
    [l_check_firewalld_rule]='Checking the firewalld rule for Link (UDP 20808)'
    [l_restore_firewalld_rule]='Restoring the missing firewalld rule for Link'
    [l_ufw_rule_exists]='ufw already allows UDP 20808; the existing rule is left unchanged'
    [l_ufw_open_port]='ufw is active; opening UDP 20808 for Ableton Link'
    [l_firewalld_rule_exists]='firewalld already allows UDP 20808; the existing rule is left unchanged'
    [l_firewalld_open_port]='firewalld is active; opening UDP 20808 for Ableton Link'
    [l_no_firewall]='No active ufw or firewalld; the firewall is unchanged'
    [l_plan_disable_heading]='Turn off Ableton Link'
    [l_plan_stop_service]='Stop the Ableton Link service and helper'
    [l_plan_remove_firewall]='Remove the firewall rule added for Link'
    [l_plan_remove_multicast]='Remove the old Link multicast route'
    [l_plan_keep_files_save_off]='Keep installed Link support files and save Link as off'
    [l_plan_enable_heading]='Enable Ableton Link'
    [l_plan_keep_ufw]='Keep the existing ufw rule for UDP 20808'
    [l_plan_open_ufw]='Open UDP 20808 with ufw'
    [l_plan_check_ufw]='Check ufw and open UDP 20808 if needed'
    [l_plan_keep_firewalld]='Keep the existing firewalld rule for UDP 20808'
    [l_plan_open_firewalld]='Open UDP 20808 with firewalld'
    [l_plan_check_firewalld]='Check firewalld and open UDP 20808 if needed'
    [l_plan_firewall_unchanged]='Leave the firewall unchanged'
    [l_plan_mode_session]='Start Link only while Ableton Live is running'
    [l_plan_mode_always]='Start Link in the background with your user session'
    [l_plan_save_setting]='Save the Link setting'
    [l_enable_link]='Enable Ableton Link'
    [l_enabled_unsaved]='Ableton Link system changes finished; run the installer again to save the preference'
    [l_enabled_session]='Ableton Link is enabled while Ableton Live is running'
    [l_enabled_always]='Ableton Link is enabled in the background'
    [l_status_mode_off]='mode: off'
    [l_status_mode_session]='mode: session (while Ableton Live is running)'
    [l_status_mode_always]='mode: always (background)'
    [l_status_running_systemd]='state: running (systemd)'
    [l_status_running_pid]='state: running (pid %s)'
    [l_status_stopped]='state: stopped'
    [l_status_not_installed]='state: not installed'
    [l_status_firewall_unknown]='firewall: unknown (the saved Link firewall information is unreadable)'
    [l_status_firewall_unchanged]='firewall: unchanged'
    [l_status_firewall_ufw]='firewall: UDP 20808 opened with ufw'
    [l_status_firewall_firewalld]='firewall: UDP 20808 opened with firewalld'
    # -- scripts/uninstall.sh --
    [u_component_integration]='Remove Linux integration'
    [u_component_runtime]='Remove the Wine runtime'
    [u_component_prefix]='Remove the Wine prefix'
    [u_component_settings]='Remove installer settings'
    [u_component_state]='Remove shared state'
    [u_moved_to_trash]='Moved to Trash: %s'
    [u_deleted_permanently]='Permanently deleted: %s'
    [u_changed_path]='The installed file or link differs from the recorded version: %s'
    [u_kept_changed]='Left the changed file or link in place: %s'
    [u_q_remove_changed]='The file or link changed after installation. Remove it?'
    [u_q_remove_changed_yes]='[R]emove this path'
    [u_q_remove_changed_no]='[K]eep this path'
    [u_no_trash]='No supported Trash tool is available; removal would permanently delete files.'
    [u_q_permanent]='Permanently delete the selected files?'
    [u_q_permanent_yes]='[D]elete permanently'
    [u_q_permanent_no]='[K]eep everything'
    [u_q_delete_prefix]='Delete the Wine prefix? This removes Live and its Wine-side authorisation'
    [u_q_delete_yes]='[D]elete the Wine prefix'
    [u_q_delete_no]='[K]eep the Wine prefix'
    [u_report_heading]='What remains'
    [u_report_runtime]='Runtime: %s'
    [u_report_prefix]='Prefix: %s'
    [u_report_integration]='Linux integration: %s'
    [u_report_settings]='Installer settings: %s'
    [u_report_state]='Shared state: %s'
    # -- scripts/lib/manifest.sh --
    [m_rebuilding_file_list]='Rebuilding the installed-file list'
    # -- scripts/lib/pipeasio.sh --
    [pa_pipewire_supported]='PipeWire %s (client %s) is supported'
    [pa_preserved_existing]='Kept your existing %s'
    [pa_restored_previous]='Restored your previous %s'
    [pa_optional_tools_missing]='Optional PipeWire tools missing: %s.'
    [pa_optional_tools_hint]='pw-dump enables panel device lists; pw-top enables Monitor; both enrich audio-report.sh.'
    [pa_qt_advice]='PipeASIO Settings is optional. To enable it, run: %s'
    [pa_panel_not_packaged]='PipeASIO Settings was not packaged; existing shortcut files were left unchanged'
    [pa_registered]='PipeASIO is registered with Wine'
    # -- scripts/lib/config.sh --
)

# Steps per action, in table order; X is the count and N the position.
# Without ABLETON_UI_KIT=1 the leading s_prepare step belongs to nobody and
# is dropped.
declare -A UI_STEPS=(
    [install]='s_prepare s_validate s_runtime_install s_prefix_create s_live s_launchers s_link_settings s_finish_install'
    [update]='s_prepare s_validate s_runtime_update s_prefix_update s_launchers s_link_settings s_finish_update'
    [runtime]='s_prepare s_validate s_runtime_install s_finish_runtime'
    [prefix_create]='s_prepare s_validate s_prefix_create s_finish_prefix'
    [prefix_update]='s_prepare s_validate s_prefix_update s_finish_prefix'
    [prefix_repair]='s_prepare s_validate s_prefix_repair'
    [link_enable]='s_prepare s_validate s_link s_finish_link'
    [link_disable]='s_prepare s_validate s_link s_finish_link'
    [link_status]='s_prepare s_validate s_link_status'
    [uninstall]='s_prepare s_validate s_remove'
    [plan]='s_prepare s_validate s_plan'
    [extract]='s_extract'
)
# END UI_TEXT

# ---------------------------------------------------------------------------
# The charset is read from the environment the user started with. Scripts
# source this file before they export LC_ALL=C.UTF-8 so the capture is real.
if [ -z "${ABLETON_UI_CHARSET:-}" ]; then
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ABLETON_UI_CHARSET=utf8 ;;
        *) ABLETON_UI_CHARSET=ascii ;;
    esac
fi
export ABLETON_UI_CHARSET
UI_SPINNER_PID=""
export UI_SPINNER_PID

# ---- state of this process ------------------------------------------------
UI_READY=0
UI_FD=1 UI_LIVE=0 UI_ROWS=0 UI_COLS=80 UI_WIDTH=78 UI_LOG=""
UI_STEP_OPEN=0 UI_STEP_N=0 UI_STEP_ITEMS=0
UI_ITEM_OPEN=0 UI_ITEM_TITLE="" UI_ITEM_MARK="" UI_ITEM_LINES=0 UI_ITEM_LAST=0
UI_ITEM_ROWS=0 UI_ITEM_COLS=0 UI_RUN_ACTIVE=0 UI_SPINNER_KIND="" UI_ITEM_WAIT=0
UI_ITEM_STATE=""
UI_ANSWER="" UI_R="" UI_G="" UI_WRAPPED=0 UI_READ_ACTIVE=0
UI_STAMP_FORMAT='%(%d/%m/%Y, %H:%M:%S)T'

ui__init()
{
    [ "$UI_READY" -eq 0 ] || return 0
    UI_READY=1
    # Character counting must match the glyph set: a UTF-8 dictionary under a
    # C locale would pad by bytes. The scripts export C.UTF-8 themselves; this
    # covers a renderer used on its own.
    if [ "$ABLETON_UI_CHARSET" = utf8 ]; then
        case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
            *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
            *) if [ -n "${LC_ALL:-}" ]; then export LC_ALL=C.UTF-8; else export LC_CTYPE=C.UTF-8; fi ;;
        esac
    fi
    UI_LOG="${ABLETON_INSTALLER_LOG:-}"
    [ "$UI_LOG" != /dev/null ] || UI_LOG=""
    case "${ABLETON_UI_TTY_FD:-}" in
        ''|*[!0-9]*) UI_FD=1 ;;
        *) UI_FD="$ABLETON_UI_TTY_FD" ;;
    esac
    if [ -n "${ABLETON_UI_TTY_FD:-}" ] && [ -t "$UI_FD" ] 2>/dev/null \
       && [ -n "${TERM:-}" ] && [ "$TERM" != dumb ]; then
        UI_LIVE=1
    fi
    ui__size
}

# Rows and columns of the screen. Live rendering needs the real terminal
# size; static rendering takes COLUMNS or 80.
ui__size()
{
    local size rows cols
    if [ "$UI_LIVE" -eq 1 ]; then
        size="$(stty size <&"$UI_FD" 2>/dev/null)" || size=""
        rows="${size%% *}"; cols="${size#* }"
        [ "$size" != "$rows" ] || cols=""
        case "$rows$cols" in
            ''|*[!0-9]*) UI_LIVE=0 ;;
            *) if [ "$rows" -gt 0 ] && [ "$cols" -gt 0 ]; then
                   UI_ROWS="$rows"; UI_COLS="$cols"
               else
                   UI_LIVE=0
               fi ;;
        esac
    fi
    if [ "$UI_LIVE" -eq 0 ]; then
        # Static output is a log or a pipe: it wraps only when COLUMNS asks
        # for it, so paths and sentences stay whole for grep.
        UI_ROWS=0
        case "${COLUMNS:-}" in
            ''|*[!0-9]*) UI_COLS=100002 ;;
            *) UI_COLS="$COLUMNS" ;;
        esac
    fi
    UI_WIDTH=$((UI_COLS - 2))
    [ "$UI_WIDTH" -ge 20 ] || UI_WIDTH=20
}

ui__g()   # glyph name -> UI_G
{
    if [ "$ABLETON_UI_CHARSET" = utf8 ]; then
        UI_G="${UI_TEXT[g_$1]-}"
    else
        UI_G="${UI_TEXT[a_$1]-}"
    fi
}

ui__text()   # key, args -> UI_R
{
    local key="$1" fmt
    shift
    fmt="${UI_TEXT[$key]-}"
    [ -n "$fmt" ] || fmt="[$key]"
    case "$fmt" in
        *%*) printf -v UI_R -- "$fmt" "$@" ;;
        *) UI_R="$fmt" ;;
    esac
}

ui_text()   # key, args -> stdout, for callers that compose a value
{
    ui__text "$@"
    printf '%s' "$UI_R"
}

ui__rep()   # glyph, count -> UI_R
{
    local pad
    printf -v pad '%*s' "$2" ''
    UI_R="${pad// /$1}"
}

ui__pad()   # text, width -> UI_R (left aligned, character count)
{
    local n=$(( $2 - ${#1} ))
    if [ "$n" -gt 0 ]; then printf -v UI_R '%s%*s' "$1" "$n" ''; else UI_R="$1"; fi
}

ui__rpad()   # text, width -> UI_R (right aligned)
{
    local n=$(( $2 - ${#1} ))
    if [ "$n" -gt 0 ]; then printf -v UI_R '%*s%s' "$n" '' "$1"; else UI_R="$1"; fi
}

ui__log()   # level, text
{
    local stamp
    [ -n "$UI_LOG" ] || return 0
    printf -v stamp "$UI_STAMP_FORMAT" -1
    printf '%-7s%s [ableton-linux][installer][ui] %s\n' "[$1]" "$stamp" "$2" >> "$UI_LOG" 2>/dev/null || true
    return 0
}

ui__screen()   # raw bytes to the screen, no log
{
    { printf '%s' "$1" >&"$UI_FD"; } 2>/dev/null || true
    return 0
}

# Add live-terminal presentation without changing the text that is measured
# or written to the log. OSC 8 turns displayed web addresses into links. SGR
# colours start after the tree prefix and end before trailing whitespace, so
# every box-drawing glyph remains in the terminal's default colour.
ui__decorate()   # state, plain text -> UI_R
{
    local state="$1" shown="$2" scheme="" before rest url after linked code=""
    local prefix="" body trailing="" t branch last sub
    if [ "$UI_LIVE" -eq 1 ]; then
        if [ -z "${NO_COLOR:-}" ]; then
            case "$state" in
                active|status) code=96 ;;
                complete) code=36 ;;
                wait|warn) code=93 ;;
                fail) code=91 ;;
            esac
        fi

        # Coloured lines can have an outer trunk and one inner trunk or
        # branch. Keep that structural prefix, its indentation, and trailing
        # padding outside the SGR span. The branch alternatives must be tested
        # before the one-character sub-trunk in the ASCII glyph set.
        if [ -n "$code" ]; then
            rest="$shown"
            while [ "${rest# }" != "$rest" ]; do prefix="$prefix "; rest="${rest# }"; done
            ui__g trunk; t="$UI_G"
            case "$rest" in "$t"*) prefix="$prefix$t"; rest="${rest#"$t"}" ;; esac
            while [ "${rest# }" != "$rest" ]; do prefix="$prefix "; rest="${rest# }"; done
            ui__g branch; branch="$UI_G"; ui__g last; last="$UI_G"; ui__g sub_trunk; sub="$UI_G"
            case "$rest" in
                "$branch"*) prefix="$prefix$branch"; rest="${rest#"$branch"}" ;;
                "$last"*) prefix="$prefix$last"; rest="${rest#"$last"}" ;;
                "$sub"*) prefix="$prefix$sub"; rest="${rest#"$sub"}" ;;
            esac
            while [ "${rest# }" != "$rest" ]; do prefix="$prefix "; rest="${rest# }"; done
            body="$rest"
            while [ "${body% }" != "$body" ]; do trailing=" $trailing"; body="${body% }"; done
            shown="$body"
        fi

        case "$shown" in *https://*) scheme=https:// ;; *http://*) scheme=http:// ;; esac
        if [ -n "$scheme" ]; then
            before="${shown%%"$scheme"*}"
            rest="${shown#*"$scheme"}"
            url="$scheme${rest%%[[:space:]]*}"
            after="${shown#"$before$url"}"
            linked=$'\033]8;;'"$url"$'\033\\'"$url"$'\033]8;;\033\\'
            shown="$before$linked$after"
        fi
        if [ -n "$code" ]; then
            if [ -n "$body" ]; then
                shown="$prefix"$'\033['"${code}m$shown"$'\033[0m'"$trailing"
            else
                shown="$prefix$trailing"
            fi
        fi
    fi
    UI_R="$shown"
}

ui__emit_log_only()   # a rendered line for the log only (settled form)
{
    local logged="$1" t b l
    ui__g trunk; t="$UI_G"; ui__g last; l="$UI_G"; ui__g branch; b="$UI_G"
    case "$logged" in "$t  $l "*) logged="$t  $b ${logged#"$t  $l "}" ;; esac
    ui__log INFO "$logged"
}

ui__emit()   # one finished line: screen plus log (always the settled form)
{
    local logged="$1" level="${2:-INFO}" state="${3:-}" saved="$UI_R" t b l s
    if [ -z "$state" ]; then
        case "$level" in OK) state=complete ;; WARN) state=warn ;; ERR) state=fail ;; esac
    fi
    ui__decorate "$state" "$1"
    { printf '%s\n' "$UI_R" >&"$UI_FD"; } 2>/dev/null || true
    if [ "$UI_ITEM_LAST" -eq 1 ]; then
        ui__g trunk; t="$UI_G"; ui__g last; l="$UI_G"; ui__g branch; b="$UI_G"; ui__g sub_trunk; s="$UI_G"
        case "$logged" in
            "$t  $l "*) logged="$t  $b ${logged#"$t  $l "}" ;;
            "$t     "*) logged="$t  $s  ${logged#"$t     "}" ;;
            "$t") logged="$t  $s" ;;
        esac
    fi
    ui__log "$level" "$logged"
    UI_R="$saved"
    return 0
}

# Wrap text at the width on the last space; a token longer than the room is
# cut hard. Each output line starts with its prefix. UI_WRAPPED counts them.
ui__wrap()   # first prefix, continuation prefix, text, [level], [state]
{
    local prefix="$1" cont="$2" text="$3" level="${4:-INFO}" state="${5:-}" room line="" word
    local -a words=()
    UI_WRAPPED=0
    read -r -a words <<< "$text"
    room=$((UI_WIDTH - ${#prefix}))
    for word in "${words[@]}"; do
        while [ "${#word}" -gt "$room" ]; do
            if [ -n "$line" ]; then
                ui__emit "$prefix$line" "$level" "$state"; UI_WRAPPED=$((UI_WRAPPED + 1))
                line=""; prefix="$cont"; room=$((UI_WIDTH - ${#prefix}))
            fi
            ui__emit "$prefix${word:0:room}" "$level" "$state"; UI_WRAPPED=$((UI_WRAPPED + 1))
            word="${word:room}"; prefix="$cont"; room=$((UI_WIDTH - ${#prefix}))
        done
        if [ -z "$line" ]; then
            line="$word"
        elif [ $(( ${#line} + 1 + ${#word} )) -le "$room" ]; then
            line="$line $word"
        else
            ui__emit "$prefix$line" "$level" "$state"; UI_WRAPPED=$((UI_WRAPPED + 1))
            prefix="$cont"; room=$((UI_WIDTH - ${#prefix})); line="$word"
        fi
    done
    ui__emit "$prefix$line" "$level" "$state"; UI_WRAPPED=$((UI_WRAPPED + 1))
}

# ---- trunk level ------------------------------------------------------------
ui_banner()   # version
{
    local t title version side sep left=26 right=17 l r
    ui__init
    ui__g box_top; t="$UI_G"
    ui__rep "${t:1:1}" "$left"; l="$UI_R"; ui__rep "${t:3:1}" "$right"; r="$UI_R"
    ui__emit "${t:0:1}$l${t:2:1}$r${t:4:1}"
    ui__text banner_version "$1"; version="$UI_R"
    ui__pad "  ${UI_TEXT[banner_title]} " "$left"; title="$UI_R"
    ui__pad " $version" "$right"; version="$UI_R"
    ui__g box_side; side="$UI_G"; ui__g box_sep; sep="$UI_G"
    ui__emit "$side$title$sep$version$side"
    ui__g box_rule; t="$UI_G"
    ui__rep "${t:1:1}" "$left"; l="$UI_R"; ui__rep "${t:3:1}" "$right"; r="$UI_R"
    ui__emit "${t:0:1}$l${t:2:1}$r${t:4:1}"
    ui__g box_side; ui__pad "  ${UI_TEXT[banner_url]}" 44; ui__emit "$UI_G$UI_R$UI_G"
    ui__g box_bottom; t="$UI_G"
    ui__rep "${t:1:1}" 44; ui__emit "${t:0:1}$UI_R${t:2:1}"
}

ui_blank()
{
    ui__init
    ui__g trunk; ui__emit "$UI_G"
}

ui_heading()   # key
{
    ui__init
    ui__text "$@"; ui__g trunk; ui__emit "$UI_G $UI_R"
}

ui_row()   # label key, value
{
    local label
    ui__init
    ui__text "$1"; ui__pad "$UI_R" 14; label="$UI_R"
    ui__g trunk
    ui__wrap "$UI_G  $label " "$UI_G                 " "$2"
}

ui_note()   # key, args
{
    ui__init
    ui__text "$@"; ui__g trunk
    ui__wrap "$UI_G  " "$UI_G  " "$UI_R"
}

ui_host_warning()   # key, args
{
    local t
    ui__init
    ui__text "$@"; ui__g trunk; t="$UI_G"; ui__g warn
    ui__wrap "$t  $UI_G " "$t    " "$UI_R" WARN
}

ui_menu_option()   # key, [default], args
{
    local key="$1" hint="" t
    shift
    if [ "${1:-}" = default ]; then ui__text m_default_hint; hint="$UI_R"; shift; fi
    ui__init
    ui__text "$key" "$@"; ui__g trunk; t="$UI_G"; ui__g detail
    ui__emit "$t  $UI_G $UI_R$hint"
}

# A pre-flight option has either the compatibility-default tag or the current
# value tag.  The caller owns the option mapping; this function owns its tree
# rendering so the wrapper never prints presentation text itself.
ui_preflight_option()   # key, default|current|plain, [args]
{
    local key="$1" tag="$2" hint="" t
    shift 2
    case "$tag" in
        default) ui__text q_default_tag; hint="$UI_R" ;;
        current) ui__text q_current_tag; hint="$UI_R" ;;
    esac
    ui__init
    ui__text "$key" "$@"; ui__g trunk; t="$UI_G"; ui__g detail
    ui__emit "$t  $UI_G $UI_R$hint"
}

# Read a normal line, except that a bare Escape is accepted immediately.  A
# line-oriented read cannot implement the documented one-key back navigation.
ui_preflight_read()
{
    local first="" rest="" rc=0
    ui__init
    ui_note q_back_hint
    ui_prompt q_prompt
    UI_READ_ACTIVE=1
    IFS= read -r -s -n 1 first || rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$first" ] && [ "$first" != $'\033' ]; then
        IFS= read -r -s rest || true
    fi
    UI_READ_ACTIVE=0
    if [ "$rc" -ne 0 ]; then
        UI_ANSWER=""
    else
        UI_ANSWER="$first$rest"
    fi
    if [ "$rc" -ne 0 ] || [ "$first" = $'\033' ]; then
        ui__screen $'\n'
    else
        ui__screen "$UI_ANSWER"$'\n'
    fi
    ui__log INFO "answer: ${UI_ANSWER:-(default)}"
}

ui_prompt()   # key: a prompt on the trunk, no newline; the caller reads
{
    ui__init
    ui__text "$@"; ui__g trunk
    ui__decorate wait "$UI_G  $UI_R "
    ui__screen "$UI_R"
    ui__log INFO "$UI_G  $UI_R"
}

# A trunk-level question: prompt line, hint line, the answer typed on the
# prompt line. UI_ANSWER contains the raw answer; EOF and the timeout leave it
# empty.
ui_ask()   # prompt key, hint key, hint args
{
    local prompt hint t
    ui__init
    ui__text "$1"; prompt="$UI_R"; shift
    ui__text "$@"; hint="$UI_R"
    ui__g trunk; t="$UI_G"
    ui__read_inline "$t  $prompt " "$t  $hint"
}

ui__timeout()   # -> UI_R seconds, minimum 1
{
    UI_R="${ABLETON_UI_PROMPT_TIMEOUT:-5}"
    case "$UI_R" in ''|*[!0-9]*) UI_R=5 ;; esac
    [ "$UI_R" -ge 1 ] || UI_R=1
}

# Print the prompt line and the hint line, then read the answer on the
# prompt line. Live rendering moves the cursor back up; static rendering
# reads after both lines.
ui__read_inline()   # prompt line (with trailing space), hint line
{
    local prompt="$1" hint="$2" seconds rc=0
    ui__timeout; seconds="$UI_R"
    UI_ANSWER=""
    ui__emit "$prompt" INFO wait
    ui__emit "$hint" INFO wait
    if [ "$UI_LIVE" -eq 1 ]; then
        ui__screen $'\033[2A\r'"$(printf '\033[%sC' "${#prompt}")"
    fi
    UI_READ_ACTIVE=1
    IFS= read -r -t "$seconds" UI_ANSWER || rc=$?
    UI_READ_ACTIVE=0
    if [ "$rc" -ne 0 ]; then UI_ANSWER=""; fi
    if [ "$UI_LIVE" -eq 1 ]; then
        [ "$rc" -eq 0 ] || ui__screen $'\n'
        ui__screen $'\033[1B\r'
    fi
    ui__log INFO "answer: ${UI_ANSWER:-(default)}"
    return 0
}

# ---- steps ---------------------------------------------------------------------
ui__step_list()   # -> UI_R: the step keys for this action
{
    local action="${ABLETON_UI_ACTION:-}" list
    list="${UI_STEPS[$action]-}"
    if [ "${ABLETON_UI_KIT:-0}" != 1 ]; then
        list="${list#s_prepare }"
        [ "$list" != s_prepare ] || list=""
    fi
    UI_R="$list"
}

ui_step_begin()   # step key
{
    local key="$1" list n=0 x=0 k name t counter w1 w2 left mid right
    ui__init
    [ "$UI_ITEM_OPEN" -eq 0 ] || { ui__log INFO "ui_step_begin with an item still open"; ui_item_end ok; }
    [ "$UI_STEP_OPEN" -eq 0 ] || { ui__log INFO "ui_step_begin with a step still open"; ui_step_end ok; }
    ui__step_list; list="$UI_R"
    for k in $list; do
        x=$((x + 1))
        [ "$k" != "$key" ] || n="$x"
    done
    if [ "$n" -eq 0 ]; then
        ui__log ERR "unknown step key $key for action ${ABLETON_UI_ACTION:-}"
        exit 70
    fi
    ui__text "$key"; name="${UI_R^^}"
    counter="$n/$x"
    w1=$(( ${#counter} + 2 )); w2=$(( ${#name} + 2 ))
    ui__g step_join; left="$UI_G"
    ui__g step_top; t="$UI_G"
    ui__rep "${t:1:1}" "$w1"; mid="$UI_R"; ui__rep "${t:3:1}" "$w2"; right="$UI_R"
    ui__emit "$left${t:0:1}$mid${t:2:1}$right${t:4:1}"
    ui__g trunk; left="$UI_G"
    ui__g step_mid; t="$UI_G"
    ui__emit "$left  ${t:0:1} $counter ${t:1:1} $name ${t:2:1}"
    ui__g step_bottom; t="$UI_G"
    ui__rep "${t:1:1}" "$w1"; mid="$UI_R"; ui__rep "${t:3:1}" "$w2"; right="$UI_R"
    ui__emit "$left  ${t:0:1}$mid${t:2:1}$right${t:4:1}"
    ui__g sub_trunk; ui__emit "$left  $UI_G"
    UI_STEP_OPEN=1; UI_STEP_N="$n"; UI_STEP_ITEMS=0
    UI_ITEM_LAST=0; UI_ITEM_LINES=0
}

ui_step_end()   # ok|fail
{
    local t mark text
    ui__init
    if [ "$UI_STEP_OPEN" -eq 0 ]; then
        ui__log INFO "ui_step_end with no open step"
        return 0
    fi
    [ "$UI_ITEM_OPEN" -eq 0 ] || ui_item_end "$1"
    ui_settle
    ui__g trunk; t="$UI_G"
    ui__g sub_trunk; ui__emit "$t  $UI_G"
    if [ "$1" = ok ]; then
        ui__g ok; mark="$UI_G"; ui__text s_complete "$UI_STEP_N"
    else
        ui__g fail; mark="$UI_G"; ui__text s_failed "$UI_STEP_N"
    fi
    text="$UI_R"
    ui__g last
    if [ "$1" = ok ]; then
        ui__emit "$t  $UI_G $text $mark" OK complete
    else
        ui__emit "$t  $UI_G $text $mark" INFO fail
    fi
    ui__emit "$t"
    UI_STEP_OPEN=0; UI_STEP_ITEMS=0
}

# ---- items ---------------------------------------------------------------------
ui__detail_prefix()   # -> UI_R: "│  │  " or "│     " for the current block
{
    local t
    ui__g trunk; t="$UI_G"
    if [ "$UI_ITEM_LAST" -eq 1 ]; then
        UI_R="$t     "
    else
        ui__g sub_trunk; UI_R="$t  $UI_G  "
    fi
}

ui__detail_blank()
{
    local t
    ui__pause_item_spinner
    ui__g trunk; t="$UI_G"
    if [ "$UI_ITEM_LAST" -eq 1 ]; then
        ui__emit "$t"
    else
        ui__g sub_trunk; ui__emit "$t  $UI_G"
    fi
    UI_ITEM_LINES=$((UI_ITEM_LINES + 1))
    ui__start_detail_spinner
}

ui__detail()   # marker glyph name, text, level, [state]
{
    local prefix cont g state="${4:-$UI_ITEM_STATE}"
    ui__pause_item_spinner
    ui__detail_prefix; prefix="$UI_R"; cont="$prefix  "
    ui__g "$1"; g="$UI_G"
    ui__wrap "$prefix$g " "$cont" "$2" "${3:-INFO}" "$state"
    UI_ITEM_LINES=$((UI_ITEM_LINES + UI_WRAPPED))
    ui__start_detail_spinner
}

ui__title()   # text -> UI_R cut to one line
{
    local room ell
    ui__g ellipsis; ell="$UI_G"
    room=$((UI_WIDTH - 6 - 2))
    if [ "${#1}" -gt "$room" ]; then
        UI_R="${1:0:room-${#ell}}$ell"
    else
        UI_R="$1"
    fi
}

ui__item_open()   # title text, [wait]: settle the previous block, draw the title
{
    local t b line mode="${2:-active}"
    [ "$UI_ITEM_OPEN" -eq 0 ] || ui_item_end ok
    ui_settle
    if [ "$UI_STEP_ITEMS" -gt 0 ]; then
        UI_ITEM_LAST=0; ui__detail_blank
    fi
    UI_STEP_ITEMS=$((UI_STEP_ITEMS + 1))
    UI_ITEM_WAIT=0; UI_ITEM_STATE=active
    if [ "$mode" = wait ]; then UI_ITEM_WAIT=1; UI_ITEM_STATE=wait; fi
    ui__title "$1"; UI_ITEM_TITLE="$UI_R"; UI_ITEM_MARK=""
    ui__g trunk; t="$UI_G"
    if [ "$UI_LIVE" -eq 1 ]; then
        ui__size
        ui__g last; b="$UI_G"
        UI_ITEM_LAST=1; UI_ITEM_ROWS="$UI_ROWS"; UI_ITEM_COLS="$UI_COLS"
        line="$t  $b $UI_ITEM_TITLE"
        if [ "$mode" = wait ]; then
            ui__emit "$line" INFO wait
        else
            ui__decorate active "$line"
            ui__screen "$UI_R"$'\033[?25l'
            UI_RUN_ACTIVE=1; UI_SPINNER_KIND=title
            ui__spinner "$$" "$line" "" 0 &
            UI_SPINNER_PID=$!
        fi
    else
        ui__g branch; b="$UI_G"
        ui__emit "$t  $b $UI_ITEM_TITLE"
        UI_ITEM_LAST=0
    fi
    UI_ITEM_LINES=1
    UI_ITEM_OPEN=1
}

ui_item_begin()   # key, args
{
    ui__init
    ui__text "$@"
    ui__item_open "$UI_R"
}

ui_status()   # key, args
{
    ui__init
    ui__text "$@"
    ui__detail detail "$UI_R" INFO status
}

ui_info()   # key, args
{
    local text
    ui__init
    ui__text "$@"; text="$UI_R"
    ui__detail_blank
    ui__detail info "$text" INFO status
}

ui_warn()   # key, args
{
    local text
    ui__init
    ui__text "$@"; text="$UI_R"
    ui__detail_blank
    ui__detail warn "$text" WARN warn
}

# Rewrite the block's title line n lines up. Only when the block still fits
# the screen and the terminal has not changed size since it was drawn.
ui__rewrite_title()   # branch glyph name, mark, n, [state]
{
    local t b line n="$3" state="${4:-$UI_ITEM_STATE}"
    ui__size
    [ "$UI_LIVE" -eq 1 ] || return 1
    [ "$UI_ROWS" -eq "$UI_ITEM_ROWS" ] && [ "$UI_COLS" -eq "$UI_ITEM_COLS" ] || return 1
    [ "$n" -lt $((UI_ROWS - 1)) ] || return 1
    ui__g trunk; t="$UI_G"; ui__g "$1"; b="$UI_G"
    line="$t  $b $UI_ITEM_TITLE${2:+ $2}"
    ui__decorate "$state" "$line"
    ui__screen "$(printf '\033[%sA\r\033[2K%s\033[%sB\r' "$n" "$UI_R" "$n")"
}

ui_item_end()   # ok|fail
{
    local mark text level=OK
    ui__init
    if [ "$UI_ITEM_OPEN" -eq 0 ]; then
        ui__log INFO "ui_item_end with no open item"
        return 0
    fi
    if [ "$1" = ok ]; then
        ui__g ok; UI_ITEM_STATE=complete
    else
        ui__g fail; level=ERR; UI_ITEM_STATE=fail
    fi
    mark="$UI_G"
    UI_ITEM_MARK="$mark"
    if [ "$UI_RUN_ACTIVE" -eq 1 ]; then
        ui__finish_item_spinner "$mark" "$UI_ITEM_STATE"
    elif [ "$UI_ITEM_LAST" -eq 1 ]; then
        ui__rewrite_title last "$mark" "$UI_ITEM_LINES" "$UI_ITEM_STATE" || true
    else
        if [ "$1" = ok ]; then ui__text i_done; else ui__text i_failed; fi
        text="$UI_R"
        ui__detail_prefix
        ui__emit "$UI_R$mark $text" INFO "$UI_ITEM_STATE"
    fi
    ui__log "$level" "$UI_ITEM_TITLE $mark"
    UI_ITEM_OPEN=0
    # A resolved operation always has the step-completion node after it. Draw
    # its permanent branch and detail trunk now instead of leaving the live
    # screen temporarily in the active └─ form.
    ui_settle
}

# Flip the last block to its settled form: the title from └─ to ├─ and each
# detail line's sub-trunk from blank to │.
ui_settle()
{
    local i n t
    ui__init
    [ "$UI_ITEM_LAST" -eq 1 ] || return 0
    n="$UI_ITEM_LINES"
    UI_ITEM_LAST=0
    if ui__rewrite_title branch "$UI_ITEM_MARK" "$n" "$UI_ITEM_STATE"; then
        ui__g sub_trunk; t="$UI_G"
        i=$((n - 1))
        while [ "$i" -ge 1 ]; do
            ui__screen "$(printf '\033[%sA\r\033[3C%s\033[%sB\r' "$i" "$t" "$i")"
            i=$((i - 1))
        done
    fi
}

# ---- one command with a spinner ------------------------------------------------
ui__spinner()   # parent pid, line, progress file, total bytes
{
    local parent="$1" line="$2" progress="$3" total="$4"
    local frame cur suffix
    local -a frames=()
    ui__g spinner; read -r -a frames <<< "$UI_G"
    local cols shown rendered
    while kill -0 "$parent" 2>/dev/null; do
        frame="${frames[RANDOM % ${#frames[@]}]}"
        suffix=""
        if [ -n "$progress" ]; then
            cur="$(stat -c %s -- "$progress" 2>/dev/null)" || cur=0
            ui__text i_progress "$((cur / 1048576))" "$((total / 1048576))"
            suffix="$UI_R "
        fi
        shown="$line $suffix$frame"
        cols="$(stty size <&"$UI_FD" 2>/dev/null)"; cols="${cols#* }"
        case "$cols" in ''|*[!0-9]*) ;; *) [ "${#shown}" -lt "$cols" ] || shown="${shown:0:cols-1}" ;; esac
        ui__decorate active "$shown"
        # Keep formatting in this background shell. If the spinner is killed
        # during a command substitution, its child printf can otherwise lose
        # the substitution pipe and leak a "Broken pipe" line into the tree.
        printf -v rendered '\r\033[2K%s' "$UI_R"
        ui__screen "$rendered"
        sleep 0.08
    done
}

ui__stop_spinner()
{
    if [ -n "$UI_SPINNER_PID" ]; then
        kill "$UI_SPINNER_PID" 2>/dev/null || true
        wait "$UI_SPINNER_PID" 2>/dev/null || true
        UI_SPINNER_PID=""
    fi
}

ui__run_finish()   # mark, [state]: settle a spinner on the title line
{
    local mark="$1" state="${2:-active}" saved="$UI_R" t b line
    ui__stop_spinner
    ui__g trunk; t="$UI_G"; ui__g last; b="$UI_G"
    line="$t  $b $UI_ITEM_TITLE${mark:+ $mark}"
    ui__decorate "$state" "$line"
    ui__screen "$(printf '\r\033[2K%s\033[?25h' "$UI_R")"$'\n'
    ui__emit_log_only "$t  $b $UI_ITEM_TITLE"
    UI_RUN_ACTIVE=0; UI_SPINNER_KIND=""
    UI_R="$saved"
}

# Stop the temporary spinner before the renderer writes another line. A title
# spinner becomes a normal title line. A detail spinner is temporary and is
# erased, so it never remains in the completed tree.
ui__pause_item_spinner()
{
    [ "$UI_RUN_ACTIVE" -eq 1 ] || return 0
    if [ "$UI_SPINNER_KIND" = detail ]; then
        ui__stop_spinner
        ui__screen $'\r\033[2K\033[?25h'
        UI_RUN_ACTIVE=0; UI_SPINNER_KIND=""
    else
        ui__run_finish "" active
    fi
}

# After detail text, keep an animated state marker on the current line until
# more text arrives or the item resolves.
ui__start_detail_spinner()
{
    local line saved="$UI_R"
    [ "$UI_LIVE" -eq 1 ] && [ "$UI_ITEM_OPEN" -eq 1 ] \
        && [ "$UI_ITEM_WAIT" -eq 0 ] && [ "$UI_RUN_ACTIVE" -eq 0 ] || return 0
    ui__detail_prefix
    line="${UI_R% }"
    ui__decorate active "$line"
    ui__screen "$UI_R"$'\033[?25l'
    UI_RUN_ACTIVE=1; UI_SPINNER_KIND=detail
    ui__spinner "$$" "$line" "" 0 &
    UI_SPINNER_PID=$!
    UI_R="$saved"
}

ui__finish_item_spinner()   # mark, state
{
    if [ "$UI_SPINNER_KIND" = detail ]; then
        ui__pause_item_spinner
        ui__rewrite_title last "$1" "$UI_ITEM_LINES" "$2" || true
    else
        ui__run_finish "$1" "$2"
    fi
}

ui_run()   # key [title args] [--progress FILE TOTAL] -- command...
{
    local key="$1" progress="" total=0 rc=0 t b line mark title level=OK
    local -a targs=()
    shift
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --progress) progress="$2"; total="$3"; shift 3 ;;
            --) shift; break ;;
            *) targs+=("$1"); shift ;;
        esac
    done
    ui__init
    ui__text "$key" "${targs[@]}"; title="$UI_R"
    [ "$UI_ITEM_OPEN" -eq 0 ] || ui_item_end ok
    ui_settle
    if [ "$UI_STEP_ITEMS" -gt 0 ]; then UI_ITEM_LAST=0; ui__detail_blank; fi
    UI_STEP_ITEMS=$((UI_STEP_ITEMS + 1))
    UI_ITEM_WAIT=0; UI_ITEM_STATE=active; UI_ITEM_OPEN=1
    ui__title "$title"; UI_ITEM_TITLE="$UI_R"; UI_ITEM_MARK=""
    ui__g trunk; t="$UI_G"
    if [ "$UI_LIVE" -eq 1 ]; then
        # The title is the last line and stays open: the spinner redraws it
        # in place until the command returns.
        ui__size
        ui__g last; b="$UI_G"
        line="$t  $b $UI_ITEM_TITLE"
        UI_ITEM_LAST=1; UI_ITEM_ROWS="$UI_ROWS"; UI_ITEM_COLS="$UI_COLS"; UI_ITEM_LINES=1
        ui__decorate active "$line"
        ui__screen "$UI_R"$'\033[?25l'
        UI_RUN_ACTIVE=1; UI_SPINNER_KIND=run
        ui__spinner "$$" "$line" "$progress" "$total" &
        UI_SPINNER_PID=$!
        "$@" || rc=$?
        if [ "$rc" -eq 0 ]; then
            ui__g ok; UI_ITEM_STATE=complete
        else
            ui__g fail; level=ERR; UI_ITEM_STATE=fail
        fi
        mark="$UI_G"; UI_ITEM_MARK="$mark"
        if [ "$UI_RUN_ACTIVE" -eq 1 ]; then
            ui__finish_item_spinner "$mark" "$UI_ITEM_STATE"
        else
            ui__rewrite_title last "$mark" "$UI_ITEM_LINES" "$UI_ITEM_STATE" || true
        fi
    else
        "$@" || rc=$?
        if [ "$rc" -eq 0 ]; then
            ui__g ok; UI_ITEM_STATE=complete
        else
            ui__g fail; level=ERR; UI_ITEM_STATE=fail
        fi
        mark="$UI_G"; UI_ITEM_MARK="$mark"
        ui__g branch; b="$UI_G"
        ui__emit "$t  $b $UI_ITEM_TITLE $mark"
        UI_ITEM_LINES=1; UI_ITEM_LAST=0
    fi
    UI_ITEM_OPEN=0
    ui__log "$level" "$UI_ITEM_TITLE $mark"
    ui_settle
    return "$rc"
}

# ---- a question inside a step ----------------------------------------------------
# ui_question TITLE_KEY DEFAULT_LETTER OPTION_KEY... ; the answer's letter
# lands in UI_ANSWER. An unknown answer repeats the prompt.
ui_question()
{
    local title_key="$1" default="$2" key text letter label prefix prompt hint seconds
    local -a letters=() labels=()
    shift 2
    ui__init
    ui__text "$title_key"; ui__text q_title "$UI_R"
    ui__item_open "$UI_R" wait
    ui__detail_blank
    for key in "$@"; do
        ui__text "$key"; text="$UI_R"
        letter="${text#*[}"; letter="${letter%%]*}"; letter="${letter,,}"
        label="${text//[/}"; label="${label//]/}"; label="${label,,}"
        letters+=("$letter"); labels+=("$label")
        [ "$letter" != "$default" ] || { ui__text q_default_tag; text="$text$UI_R"; }
        ui__detail detail "$text"
    done
    ui__detail_blank
    ui__timeout; seconds="$UI_R"
    ui__text q_prompt; prompt="$UI_R"
    ui__text q_hint "$seconds"; hint="$UI_R"
    while :; do
        ui__detail_prefix; prefix="$UI_R"
        ui__read_inline "$prefix$prompt " "$prefix$hint"
        UI_ITEM_LINES=$((UI_ITEM_LINES + 2))
        text="${UI_ANSWER,,}"
        text="${text#"${text%%[![:space:]]*}"}"; text="${text%"${text##*[![:space:]]}"}"
        if [ -z "$text" ]; then UI_ANSWER="$default"; break; fi
        UI_ANSWER=""
        for key in "${!letters[@]}"; do
            if [ "$text" = "${letters[key]}" ] || [ "$text" = "${labels[key]}" ] \
               || [ "$text" = "${labels[key]%% *}" ]; then
                UI_ANSWER="${letters[key]}"
            fi
        done
        [ -z "$UI_ANSWER" ] || break
    done
    UI_ITEM_OPEN=0; UI_ITEM_WAIT=0
    ui_settle
    ui__log INFO "chosen: $UI_ANSWER"
}

# ---- footer and tail ---------------------------------------------------------------
ui__foot_line()   # glyph set (5 chars), left width, right width
{
    local t="$1"
    ui__rep "${t:1:1}" "$2"; local l="$UI_R"
    ui__rep "${t:3:1}" "$3"; local r="$UI_R"
    ui__emit "${t:0:1}$l${t:2:1}$r${t:4:1}"
}

ui__foot_row()   # left text, right text, left width, right width
{
    local side
    ui__g box_side; side="$UI_G"
    ui__pad " $1" "$3"; local l="$UI_R"
    ui__rpad "$2" $(( $4 - 1 )); local r="$UI_R "
    ui__emit "$side$l$side$r$side"
}

# ui_footer LABEL VERSION STATUS SECONDS WARNINGS ERRORS RUNTIME PREFIX
ui_footer()
{
    local label="$1" version="$2" status="$3" seconds="$4" warnings="$5" errors="$6"
    local runtime="$7" prefix="$8" inner=53 left right title state t side row
    local -a rows=()
    ui__init
    ui__text f_title "$label" "$version"; title="$UI_R"
    case "$status" in
        complete) ui__text f_complete ;;
        interrupted) ui__text f_interrupted ;;
        cancelled) ui__text f_cancelled ;;
        *) ui__text f_failed ;;
    esac
    state="$UI_R"
    [ -z "$runtime" ] || { ui__text f_runtime; rows+=("$UI_R $runtime"); }
    [ -z "$prefix" ] || { ui__text f_prefix; rows+=("$UI_R $prefix"); }
    right=10
    [ $(( ${#state} + 2 )) -le "$right" ] || right=$(( ${#state} + 2 ))
    if [ $(( ${#title} + 2 + right + 1 )) -gt $((UI_WIDTH - 2)) ]; then
        ui__g ellipsis
        title="${title:0:$((UI_WIDTH - 2 - right - 1 - 2 - ${#UI_G}))}$UI_G"
    fi
    for row in "${rows[@]}"; do
        [ $(( ${#row} + 2 )) -le "$inner" ] || inner=$(( ${#row} + 2 ))
    done
    [ $(( ${#title} + 2 + right + 1 )) -le "$inner" ] || inner=$(( ${#title} + 2 + right + 1 ))
    [ "$inner" -le $((UI_WIDTH - 2)) ] || inner=$((UI_WIDTH - 2))
    left=$((inner - right - 1))
    ui__g foot_top; ui__foot_line "$UI_G" "$left" "$right"
    ui__foot_row "$title" "$state" "$left" "$right"
    ui__g foot_rule; ui__foot_line "$UI_G" "$left" "$right"
    ui__text f_time; t="$UI_R"; ui__text f_seconds "$seconds"
    ui__foot_row "$t" "$UI_R" "$left" "$right"
    ui__g foot_dash; ui__foot_line "$UI_G" "$left" "$right"
    ui__text f_warnings; ui__foot_row "$UI_R" "$warnings" "$left" "$right"
    ui__g foot_dash; ui__foot_line "$UI_G" "$left" "$right"
    ui__text f_errors; ui__foot_row "$UI_R" "$errors" "$left" "$right"
    ui__g foot_merge; ui__foot_line "$UI_G" "$left" "$right"
    ui__g box_side; side="$UI_G"
    for row in "${rows[@]}"; do
        if [ $(( ${#row} + 2 )) -gt "$inner" ]; then
            ui__g ellipsis
            t="${row%% *} "
            if [ $((inner - 2 - ${#t} - ${#UI_G})) -gt 0 ]; then
                row="$t$UI_G${row:$(( ${#row} - (inner - 2 - ${#t} - ${#UI_G}) ))}"
            else
                row="${row:0:$((inner - 2))}"
            fi
        fi
        ui__pad " $row" "$inner"; ui__emit "$side$UI_R$side"
    done
    ui__g foot_bottom; t="$UI_G"
    ui__rep "${t:1:1}" "$inner"; ui__emit "${t:0:1}$UI_R${t:2:1}"
}

# ui_tail STATUS LOG_PATH [ERROR...]
ui_tail()
{
    local status="$1" log="$2" error
    shift 2
    ui__init
    ui__emit ""
    if [ "$#" -gt 0 ]; then
        ui__text t_errors_h; ui__emit "$UI_R" INFO fail
        for error in "$@"; do ui__text t_error_item "$error"; ui__emit "  $UI_R" INFO fail; done
        ui__emit ""
    fi
    if [ "$status" = complete ]; then
        ui__text t_launch; ui__emit "$UI_R"; ui__emit ""
        ui__text t_launch_cmd; ui__emit "  $UI_R"; ui__emit ""
    fi
    ui__text t_bsky_h; ui__emit "$UI_R"; ui__text t_bsky; ui__emit "  $UI_R"; ui__emit ""
    ui__text t_discord_h; ui__emit "$UI_R"; ui__text t_discord; ui__emit "  $UI_R"; ui__emit ""
    case "$status" in
        complete|cancelled) ui__text t_help_h; ui__emit "$UI_R"; ui__text t_help; ui__emit "  $UI_R" ;;
        *) ui__text t_report_h; ui__emit "$UI_R"; ui__text t_report; ui__emit "  $UI_R" ;;
    esac
    ui__emit ""
    if [ -n "$log" ]; then
        ui__text t_log_h; ui__emit "$UI_R"; ui__emit "  $log"
    else
        ui__text t_log_none; ui__emit "$UI_R" WARN
    fi
}

# ---- exit path -----------------------------------------------------------------------
# ui_cleanup STATUS: called first by every script's EXIT handler. Stops the
# spinner, ends an open item and step (ok when STATUS is 0), settles the
# last block, and shows the cursor.
ui_cleanup()
{
    local outcome=fail
    IFS=$' \t\n'
    ui__init
    if [ "$UI_READ_ACTIVE" -eq 1 ]; then
        UI_READ_ACTIVE=0
        [ "$UI_LIVE" -eq 0 ] || ui__screen $'\n'
    fi
    [ "${1:-1}" != 0 ] || outcome=ok
    if [ "$UI_RUN_ACTIVE" -eq 1 ]; then
        if [ "$outcome" = ok ]; then
            ui__g ok; UI_ITEM_STATE=complete
        else
            ui__g fail; UI_ITEM_STATE=fail
        fi
        UI_ITEM_MARK="$UI_G"
        ui__finish_item_spinner "$UI_G" "$UI_ITEM_STATE"
        UI_ITEM_OPEN=0
        if [ "$outcome" = ok ]; then ui__log OK "$UI_ITEM_TITLE $UI_G"; else ui__log ERR "$UI_ITEM_TITLE $UI_G"; fi
    fi
    ui__stop_spinner
    [ "$UI_ITEM_OPEN" -eq 0 ] || ui_item_end "$outcome"
    [ "$UI_STEP_OPEN" -eq 0 ] || ui_step_end "$outcome"
    ui_settle
    [ "$UI_LIVE" -eq 0 ] || ui__screen $'\033[?25h'
    return 0
}
