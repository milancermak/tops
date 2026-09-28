"""Offline regression coverage for parsing untrusted public JavaScript as data."""

import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("refresh_operations", Path(__file__).resolve().parents[1] / "tools" / "refresh_operations.py")
refresh = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(refresh)


class OperationExtractionTests(unittest.TestCase):
    def test_descriptor_spacing_unknown_operations_and_mutations(self):
        digest = "a" * 64
        source = f'''new x.q("home", "query", "{digest}", null);
            x("homeSection","query","{digest}",null);
            x("home","mutation","{'b' * 64}",null);
            x("unwanted","query","{digest}",null);'''
        self.assertEqual(refresh.extract_operations(source), {"home": digest, "homeSection": digest})

    def test_conflicting_descriptors_fail_closed(self):
        source = f'x("home","query","{"a" * 64}",null);x("home","query","{"b" * 64}",null);'
        with self.assertRaisesRegex(ValueError, "Conflicting"):
            refresh.extract_operations(source)

    def test_malformed_descriptor_and_non_null_query_are_ignored(self):
        source = 'x("home","query","short",null);' + f'x("home","query","{"a" * 64}",alert("never run"));'
        self.assertEqual(refresh.extract_operations(source), {})

    def test_chunk_map_resolves_js_without_confusing_css(self):
        source = '''u.u=e=>""+(({12:"browse-v2",34:"home-v2-section",56:"xpui-routes-search"})[e]||e)+"."+({12:"abcdef12",34:"0123abcd",56:"1234abcd"})[e]+".js";
        u.miniCssF=e=>""+(({12:"browse-v2"})[e]||e)+"."+({12:"99999999"})[e]+".css";'''
        base = "https://open.spotifycdn.com/cdn/build/web-player/web-player.1234.js"
        self.assertEqual(refresh.named_chunk_urls(source, base), {
            "browse-v2": "https://open.spotifycdn.com/cdn/build/web-player/browse-v2.abcdef12.js",
            "home-v2-section": "https://open.spotifycdn.com/cdn/build/web-player/home-v2-section.0123abcd.js",
            "xpui-routes-search": "https://open.spotifycdn.com/cdn/build/web-player/xpui-routes-search.1234abcd.js",
        })

    def test_html_only_accepts_real_spotify_script_sources(self):
        good = "https://open.spotifycdn.com/cdn/build/web-player/web-player.1234.js"
        html = f'<script src="{good}"></script><script src="https://evil.example/web-player.js"></script><script src="https://open.spotifycdn.com.evil.example/cdn/build/web-player/web-player.1234.js"></script>'
        self.assertEqual(refresh.player_bundle_urls(html), [good])
        with self.assertRaises(ValueError):
            refresh.player_bundle_urls('<script src="https://evil.example/web-player.1234.js"></script>')

    def test_collect_records_provenance_and_requires_all_operations(self):
        base = "https://open.spotifycdn.com/cdn/build/web-player/"
        bundle = base + "web-player.1234.js"
        digest = "a" * 64
        fixtures = {
            refresh.HOME_URL: f'<script src="{bundle}"></script>',
            bundle: ''.join(f'x("{op}","query","{digest}",null);' for op in ["home", "homeSection", "fetchPlaylist", "getAlbum", "queryArtistOverview"]) + 'u.u=e=>""+(({1:"browse-v2",2:"home-v2-section",3:"xpui-routes-search"})[e]||e)+"."+({1:"11111111",2:"22222222",3:"33333333"})[e]+".js";',
            base + "browse-v2.11111111.js": f'x("browsePage","query","{digest}",null);x("browseSection","query","{digest}",null);',
            base + "home-v2-section.22222222.js": "",
            base + "xpui-routes-search.33333333.js": f'x("searchDesktop","query","{digest}",null);',
        }
        manifest = refresh.collect(lambda url: fixtures[url].encode())
        self.assertEqual(set(manifest["operations"]), refresh.REQUIRED_OPERATIONS)
        self.assertEqual(len(manifest["sources"]), 5)
        self.assertEqual(manifest["operations"]["browsePage"]["sources"], [base + "browse-v2.11111111.js"])
        fixtures[base + "xpui-routes-search.33333333.js"] = ""
        with self.assertRaisesRegex(ValueError, "searchDesktop"):
            refresh.collect(lambda url: fixtures[url].encode())


if __name__ == "__main__":
    unittest.main()
