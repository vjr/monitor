namespace Monitor {
    public class ProcessManager {
        private static GLib.Once<ProcessManager> instance;
        public static unowned ProcessManager get_default () {
            return instance.once (() => { return new ProcessManager (); });
        }

        public double cpu_load { get; private set; }
        public double[] cpu_loads { get; private set; }

        uint64 cpu_last_used = 0;
        uint64 cpu_last_total = 0;
        uint64[] cpu_last_useds = new uint64[32];
        uint64[] cpu_last_totals = new uint64[32];

        private Gee.TreeMap<int, Process> process_list;
        private Gee.HashSet<int> kernel_process_blacklist;
        private Gee.HashMap<string, AppInfo> apps_info_list;
        private Gee.HashMap<string, AppInfo> apps_info_list_bwrap;
        private Gee.HashMap<string, AppInfo> apps_info_list_flatpak;
        private Gee.HashMap<string, AppInfo> apps_info_list_native;


        public signal void process_added (Process process);
        public signal void process_removed (int pid);
        public signal void updated ();

        // Construct a new ProcessManager
        public ProcessManager () {
            process_list = new Gee.TreeMap<int, Process> ();
            kernel_process_blacklist = new Gee.HashSet<int> ();
            apps_info_list = new Gee.HashMap<string, AppInfo> ();
            apps_info_list_bwrap = new Gee.HashMap<string, AppInfo> ();
            apps_info_list_flatpak = new Gee.HashMap<string, AppInfo> ();
            apps_info_list_native = new Gee.HashMap<string, AppInfo> ();

            populate_apps_info ();

            update_processes.begin ();
        }

        public void populate_apps_info () {
            var _apps_info = AppInfo.get_all ();

            foreach (AppInfo app_info in _apps_info) {
                string commandline = (app_info.get_commandline ());
                // debug ("%s\n", commandline);

                // GLib.DesktopAppInfo? dai = info as GLib.DesktopAppInfo;

                // if (dai != null) {
                // string id = dai.get_string ("X-Flatpak");
                // if (id != null)
                // appid_map.insert (id, info);
                // }


                if (commandline == null)
                    continue;

                // sanitize_cmd (ref cmd);
                if (commandline.contains ("bwrap")) {
                    apps_info_list_bwrap.set (commandline, app_info);
                } else if (commandline.contains ("flatpak")) {
                    apps_info_list_flatpak.set (commandline, app_info);
                } else {
                    apps_info_list_native.set (commandline, app_info);
                }
                apps_info_list.set (commandline, app_info);
                //message ("VJR: appinfo command: " + commandline);
            }
        }

        // private static void sanitize_cmd(ref string? commandline) {
        // if (commandline == null)
        // return;

        //// flatpak: parse the command line of the containerized program
        // if (commandline.contains("flatpak run")) {
        // var index = commandline.index_of ("--command=") + 10;
        // commandline = commandline.substring (index);
        // }

        //// TODO: unify this with the logic in get_full_process_cmd
        ////  commandline = Process.first_component (commandline);
        ////  commandline = Path.get_basename (commandline);
        ////  commandline = Process.sanitize_name (commandline);

        //// Workaround for google-chrome
        // if (commandline.contains ("google-chrome-stable"))
        // commandline = "chrome";
        // }

        // public static AppInfo? app_info_for_process (Process p) {
        // AppInfo? info = null;

        // if (p.command != null)
        // info = apps_info[p.command];

        // if (info == null && p.app_id != null)
        // info = appid_map[p.app_id];

        // return info;
        // }




        /**
         * Gets a process by its pid, making sure that it's updated.
         */
        public Process ? get_process (int pid) {
            // if the process is in the kernel blacklist, we don't want to deal with it.
            if (kernel_process_blacklist.contains (pid)) {
                return null;
            }

            // else, return our cached version.
            if (process_list.has_key (pid)) {
                return process_list[pid];
            }

            // else return the result of add_process
            // make sure to lazily call the callback since this is a greedy add
            // this way we don't interrupt whatever this method is being called for
            // with a handle_add_process
            return add_process (pid, true);
        }

        /**
         * Returns all direct sub processes of this process
         */
        public Gee.Set<int> get_sub_processes (int pid) {
            var sub_processes = new Gee.HashSet<int> ();

            // go through and add all of the processes with PPID set to this one
            foreach (var process in process_list.values) {
                if (process.stat.ppid == pid) {
                    sub_processes.add (process.stat.pid);
                }
            }

            return sub_processes;
        }

        /**
         * Gets a read only map of the processes currently cached
         */
        public Gee.Map<int, Process> get_process_list () {
            return process_list.read_only_view;
        }

        /**
         * Gets all new process and adds them
         */
        public async void update_processes () {
            /* CPU */
            GTop.Cpu cpu_data;
            GTop.get_cpu (out cpu_data);
            var used = cpu_data.user + cpu_data.nice + cpu_data.sys;
            cpu_load = ((double) (used - cpu_last_used)) / (cpu_data.total - cpu_last_total);
            cpu_loads = new double[cpu_data.xcpu_user.length];
            var useds = new uint64[cpu_data.xcpu_user.length];

            for (int i = 0; i < cpu_data.xcpu_user.length; i++) {
                useds[i] = cpu_data.xcpu_user[i] + cpu_data.xcpu_nice[i] + cpu_data.xcpu_sys[i];
            }

            for (int i = 0; i < cpu_data.xcpu_user.length; i++) {
                cpu_loads[i] = ((double) (useds[i] - cpu_last_useds[i])) /
                               (cpu_data.xcpu_total[i] - cpu_last_totals[i]);
            }

            var remove_me = new Gee.HashSet<int> ();

            /* go through each process and update it, removing the old ones */
            foreach (var process in process_list.values) {
                if (!process.update (cpu_data.total, cpu_last_total)) {
                    /* process doesn't exist any more, flag it for removal! */
                    remove_me.add (process.stat.pid);
                }
            }

            /* remove everything from flags */
            foreach (var pid in remove_me) {
                remove_process (pid);
            }

            var uid = Posix.getuid ();
            GTop.ProcList proclist;
            var pids = GTop.get_proclist (out proclist, GTop.GLIBTOP_KERN_PROC_UID, uid);
            // var pids = GTop.get_proclist (out proclist, GTop.GLIBTOP_KERN_PROC_ALLfla, uid);

            for (int i = 0; i < proclist.number; i++) {
                int pid = pids[i];

                if (!process_list.has_key (pid) && !kernel_process_blacklist.contains (pid)) {
                    add_process (pid);
                }
            }

            cpu_last_used = used;
            cpu_last_total = cpu_data.total;
            cpu_last_useds = useds;
            cpu_last_totals = cpu_data.xcpu_total;

            /* emit the updated signal so that subscribers can update */
            updated ();
        }

        /**
         * Parses a pid and adds a Process to our process_list or to the kernel_blacklist
         *
         * returns the created process
         */
        private Process ? add_process (int pid, bool lazy_signal = false) {
            // create the process
            var process = new Process (pid);

            // placeholding shortened commandline
            process.application_name = ProcessUtils.sanitize_commandline (process.command);
            process.full_name = ProcessUtils.sanitize_commandline (process.command, true);

            ProcessUtils.get_flatpak_command(process.command, ref process.application_name, ref process.full_name);

            if (process.command.contains ("bwrap")) {

            } else if (process.command.contains ("flatpak")) {

            } else {

            }

            //message ("VJR: process command: " + process.command);

            // checking maybe it's an application
            foreach (var key in apps_info_list.keys) {
                /*
                if (key.contains (process.application_name)) {
                    process.application_name = apps_info_list.get (key).get_name ();
                    // debug (apps_info_list.get (key).get_icon ().to_string ());
                    process.icon = apps_info_list.get (key).get_icon ();
                }
                */
                if (corelate_names (key, ref process)) {
                    //message ("VJR: corelate() DONE!!!");
                    //message ("VJR: KEY: " + key);
                    //message ("VJR: COMMAND: " + process.command);
                    //message ("VJR: APPNAME: " + process.application_name);
                    break;
                }
            }

            if (process.application_name == "bash") {
                debug ("app name is bash" + process.application_name);
                process.icon = ProcessUtils.get_bash_icon ();
            }

            if (process.exists) {
                if (process.stat.pgrp != 0) {
                    // regular process, add it to our cache
                    process_list.set (pid, process);

                    // call the signal, lazily if needed
                    if (lazy_signal)
                        Idle.add (() => { process_added (process); return false; });
                    else
                        process_added (process);

                    return process;
                } else {
                    // add it to our kernel processes blacklist
                    kernel_process_blacklist.add (pid);
                }
            }

            return null;
        }

        private bool corelate_names (string app_info_command, ref Process process) {
            //message ("VJR: SANITIZE KEY: " + app_info_command);
            string app_info_application_name = ProcessUtils.sanitize_commandline(app_info_command);
            string app_info_full_name = ProcessUtils.sanitize_commandline(app_info_command, true);

            if (ProcessUtils.get_flatpak_command(app_info_command, ref app_info_application_name, ref app_info_full_name)) {
                if (process.command.contains (app_info_full_name)) {
                    update_process_info (ref process, apps_info_list.get (app_info_command).get_name (), apps_info_list.get (app_info_command).get_icon ());
                    //message ("VJR: FLATPAK KEY:" + app_info_command);
                    //message ("VJR: FLATPAK BASE:" + app_info_application_name);
                    //message ("VJR: FLATPAK FULL:" + app_info_full_name);
                    //message ("VJR: FLATPAK COMMAND:" + process.command);
                    //message ("VJR: FLATPAK APPNAME:" + process.application_name);
                    return true;
                } else if (ProcessUtils.get_flatpak_command(process.command, ref app_info_application_name, ref app_info_full_name) && app_info_command.contains (app_info_full_name)) {
                    //message ("VJR: FAILED FLATPAK CORELATE APPINFO KEY: " + app_info_command);
                    //message ("VJR: FAILED FLATPAK CORELATE APPINFO BASE: " + app_info_application_name);
                    //message ("VJR: FAILED FLATPAK CORELATE APPINFO FULL: " + app_info_full_name);
                    //message ("VJR: FAILED FLATPAK CORELATE PROCESS COMMAND: " + process.command);
                    update_process_info (ref process, apps_info_list.get (app_info_command).get_name (), apps_info_list.get (app_info_command).get_icon ());
                    return true;
                }
            //} else if (app_info_command.contains (process.application_name)) {
            } else if (ProcessUtils.get_flatpak_command(process.command, ref app_info_application_name, ref app_info_full_name)) {
                message ("VJR: KEY:" + app_info_command);
                message ("VJR: BASE:" + app_info_application_name);
                message ("VJR: FULL:" + app_info_full_name);
                if (app_info_command.contains (app_info_full_name)) {
                    //string oldname = process.application_name;
                    update_process_info (ref process, apps_info_list.get (app_info_command).get_name (), apps_info_list.get (app_info_command).get_icon ());
                    //if (process.application_name.contains ("GoogleAppGoogle")) {
                        //message ("VJR: KEY:" + app_info_command);
                        //message ("VJR: BASE:" + app_info_application_name);
                        //message ("VJR: FULL:" + app_info_full_name);
                        //message ("VJR: COMMAND:" + process.command);
                        //message ("VJR: FULLNAME:" + process.full_name);
                        //message ("VJR: APPNAME1:" + oldname);
                        //message ("VJR: APPNAME2:" + process.application_name);
                    //}
                    return true;
                } else {
                   //message ("VJR: MISSED PROCESS:" + process.command);
                }
            } else if (app_info_command.contains (process.full_name)) {
                update_process_info (ref process, apps_info_list.get (app_info_command).get_name (), apps_info_list.get (app_info_command).get_icon ());
                return true;
            //} else if ((process.full_name.contains ("chromium") || process.full_name.contains ("bwrap")) && app_info_command.contains ("chrom")) {
            } else if (process.command.contains (app_info_full_name)) {
                update_process_info (ref process, apps_info_list.get (app_info_command).get_name (), apps_info_list.get (app_info_command).get_icon ());
                return true;
            } else {
                /*
                message ("***************************************************");
                message ("VJR: MISSED KEY:" + app_info_command);
                message ("VJR: MISSED BASE:" + app_info_application_name);
                message ("VJR: MISSED FULL:" + app_info_full_name);
                message ("VJR: MISSED COMMAND:" + process.command);
                message ("VJR: MISSED FULLNAME:" + process.full_name);
                message ("VJR: MISSED APPNAME:" + process.application_name);
                message ("***************************************************");
                */
            }

            return false;
        }

        private void update_process_info (ref Process process, string name, GLib.Icon ? icon) {
            process.application_name = name;
            process.icon = icon;
            //message ("VJR: ICON: " + (icon == null ? "NULL" : icon.to_string ()));
        }

        /**
         * Remove the process from all lists and broadcast the process_removed signal if removed.
         */
        private void remove_process (int pid) {
            if (process_list.has_key (pid)) {
                process_list.unset (pid);
                process_removed (pid);
            } else if (kernel_process_blacklist.contains (pid)) {
                kernel_process_blacklist.remove (pid);
            }
        }

    }
}
