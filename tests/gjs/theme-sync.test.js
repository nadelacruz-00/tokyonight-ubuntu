// gjs -m tests/gjs/theme-sync.test.js
import GLib from 'gi://GLib';
import {parsePalette, isDark, buildCss} from '../../assets/osk/gjsosk-theme-sync@nadelacruz-00.github.io/palette.js';

let fails = 0;
const eq = (name, got, want) => {
    const ok = JSON.stringify(got) === JSON.stringify(want);
    if (!ok) fails++;
    print(`${ok ? 'ok  ' : 'FAIL'} ${name}${ok ? '' : `: got ${JSON.stringify(got)} want ${JSON.stringify(want)}`}`);
};

const tokyo = `:root {\n  --window-bg-color: #1a1b26;\n  --window-fg-color: #a9b1d6;\n  --card-bg-color: #282a38;\n}\n@define-color accent_bg_color #cfc9ff;\n@define-color accent_fg_color #222222;\n`;
eq('tokyo palette', parsePalette(tokyo), {bg: '#1a1b26', fg: '#a9b1d6', card: '#282a38', accentBg: '#cfc9ff', accentFg: '#222222'});
eq('missing card -> null', parsePalette(':root { --window-bg-color: #1a1b26; --window-fg-color: #a9b1d6; }'), null);
eq('no accent -> fg/bg fallback', parsePalette(':root { --window-bg-color: #1a1b26; --window-fg-color: #a9b1d6; --card-bg-color: #282a38; }').accentBg, '#a9b1d6');
eq('tokyo bg is dark', isDark('#1a1b26'), true);
eq('light bg is not dark', isDark('#fafafa'), false);
const css = buildCss(parsePalette(tokyo));
eq('css key colour', css.includes('background-color: #282a38;'), true);
eq('css pressed accent', css.includes('rgba(207, 201, 255, 0.35)'), true);
eq('css selected', css.includes('color: #222222;'), true);

// the vendored Rewaita CSS (both variants must parse as dark palettes)
const here = GLib.path_get_dirname(GLib.filename_from_uri(import.meta.url)[0]);
for (const v of ['tokyonight', 'storm']) {
    const path = GLib.build_filenamev([here, '..', '..', 'assets', 'rewaita', v, 'gtk4.css']);
    const [, bytes] = GLib.file_get_contents(path);
    const p = parsePalette(new TextDecoder().decode(bytes));
    eq(`vendored ${v} parses`, p !== null, true);
    eq(`vendored ${v} is dark`, p !== null && isDark(p.bg), true);
}
if (fails) throw new Error(`${fails} failed`);
