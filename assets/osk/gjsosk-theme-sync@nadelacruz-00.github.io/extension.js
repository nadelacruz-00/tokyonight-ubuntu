// GJS OSK Theme Sync: colours the GJS OSK keyboard from the Rewaita palette.
//
// Rewaita writes the active GTK 4 palette to ~/.config/gtk-4.0/gtk.css.  While
// that palette is dark this loads a key stylesheet built from it and sets the
// OSK's dark panel colour; a light palette drops the stylesheet so GJS OSK's
// own light look applies.  The file is watched, so a Rewaita theme change
// follows without a relogin.

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import {parsePalette, isDark, rgb, buildCss} from './palette.js';

const OSK_UUID = 'gjsosk@vishram1123.com';
const OSK_SCHEMA = 'org.gnome.shell.extensions.gjsosk';

export default class ThemeSync extends Extension {
    enable() {
        this._gtkCss = Gio.File.new_for_path(
            GLib.build_filenamev([GLib.get_user_config_dir(), 'gtk-4.0', 'gtk.css']));
        this._cacheDir = GLib.build_filenamev([GLib.get_user_cache_dir(), 'gjsosk-theme-sync']);
        GLib.mkdir_with_parents(this._cacheDir, 0o755);
        this._stylesheet = null;
        this._serial = 0;

        // Rewaita may replace gtk.css instead of rewriting it, so watch the folder.
        this._monitor = this._gtkCss.get_parent().monitor_directory(Gio.FileMonitorFlags.WATCH_MOVES, null);
        this._monitorId = this._monitor.connect('changed', (_m, file, other) => {
            if (file?.get_basename() === 'gtk.css' || other?.get_basename() === 'gtk.css')
                this._queueSync();
        });
        this._sync();
    }

    disable() {
        if (this._syncId) {
            GLib.source_remove(this._syncId);
            this._syncId = 0;
        }
        this._monitor?.disconnect(this._monitorId);
        this._monitor?.cancel();
        this._monitor = null;
        this._unloadStylesheet();
        this._oskSettings = null;
    }

    _queueSync() {
        if (this._syncId)
            GLib.source_remove(this._syncId);
        this._syncId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, () => {
            this._syncId = 0;
            this._sync();
            return GLib.SOURCE_REMOVE;
        });
    }

    _sync() {
        let palette = null;
        try {
            const [, bytes] = this._gtkCss.load_contents(null);
            palette = parsePalette(new TextDecoder().decode(bytes));
        } catch (e) {
            // no gtk.css: Rewaita is not theming GTK 4
        }
        if (!palette || !isDark(palette.bg)) {
            this._unloadStylesheet();
            return;
        }
        this._setPanelColour(palette.bg);
        this._loadStylesheet(buildCss(palette));
    }

    _loadStylesheet(css) {
        // A fresh file name per change, so St never serves a cached parse.
        const path = GLib.build_filenamev([this._cacheDir, `osk-${Date.now()}-${++this._serial}.css`]);
        GLib.file_set_contents(path, css);
        const file = Gio.File.new_for_path(path);
        this._unloadStylesheet();
        St.ThemeContext.get_for_stage(global.stage).get_theme().load_stylesheet(file);
        this._stylesheet = file;
    }

    _unloadStylesheet() {
        if (!this._stylesheet)
            return;
        St.ThemeContext.get_for_stage(global.stage).get_theme().unload_stylesheet(this._stylesheet);
        try {
            this._stylesheet.delete(null);
        } catch (e) {
            // already gone
        }
        this._stylesheet = null;
    }

    // The panel behind the keys is an inline style GJS OSK builds from its
    // background-*-dark settings; only write them when they differ, since
    // every write rebuilds the keyboard.
    _setPanelColour(hex) {
        const settings = this._getOskSettings();
        if (!settings)
            return;
        const [r, g, b] = rgb(hex);
        const want = {'background-r-dark': r, 'background-g-dark': g, 'background-b-dark': b, 'background-a-dark': 1};
        const stale = Object.entries(want).filter(([k, val]) => settings.get_double(k) !== val);
        if (stale.length === 0)
            return;
        settings.delay();
        for (const [k, val] of stale)
            settings.set_double(k, val);
        settings.apply();
    }

    _getOskSettings() {
        if (this._oskSettings)
            return this._oskSettings;
        const osk = Main.extensionManager.lookup(OSK_UUID);
        const dir = osk?.dir.get_child('schemas');
        if (!dir?.query_exists(null))
            return null;
        const source = Gio.SettingsSchemaSource.new_from_directory(
            dir.get_path(), Gio.SettingsSchemaSource.get_default(), false);
        const schema = source.lookup(OSK_SCHEMA, false);
        this._oskSettings = schema ? new Gio.Settings({settings_schema: schema}) : null;
        return this._oskSettings;
    }
}
