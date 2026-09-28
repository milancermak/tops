#!/usr/bin/env python3
"""Explicit live Pathfinder diagnostic; credentials stay in a private temporary copy."""
import argparse, json, os, platform, shutil, subprocess, tempfile, threading, time
from pathlib import Path
from urllib.request import Request, build_opener, HTTPRedirectHandler
from urllib.error import HTTPError

ROOT = Path(__file__).resolve().parents[1]
ENDPOINT = 'https://api-partner.spotify.com/pathfinder/v2/query'
DESKTOP_USER_AGENT = 'Spotify/1.2.52.442 OSX/0 (Tops/0.1)'
BROWSER_USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36'
# name: (bearer source, desktop headers, explicit User-Agent, client token)
VARIANTS = {
    'oauth-desktop-default-ua': ('oauth', True, None, True),
    'oauth-desktop-ua': ('oauth', True, DESKTOP_USER_AGENT, True),
    'login5-web-default-ua': ('login5', False, None, True),
    'login5-desktop-default-ua': ('login5', True, None, True),
    'oauth-browser-ua': ('oauth', True, BROWSER_USER_AGENT, True),
    'oauth-no-client-token': ('oauth', True, DESKTOP_USER_AGENT, False),
    'login5-desktop-ua': ('login5', True, DESKTOP_USER_AGENT, True),
}
DEFAULT_VARIANTS = ('oauth-desktop-default-ua', 'oauth-desktop-ua')


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


HTTP = build_opener(NoRedirect)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session-dir', type=Path, default=Path.home() / 'Library/Application Support/Tops/session')
    parser.add_argument('--variant', action='append', choices=VARIANTS,
                        help='Explicit comparison variant; repeat to select several. Default: two requests differing only in User-Agent.')
    args = parser.parse_args()
    variants = list(dict.fromkeys(args.variant or DEFAULT_VARIANTS))
    # Only Tops' own specifically configured session is read. No browser/Spotify profile access.
    saved = json.loads((args.session_dir / 'oauth.json').read_text())
    if saved['expires_at'] < time.time() + 180:
        raise SystemExit('Saved OAuth token is near expiry; reconnect Tops before running this comparison.')
    manifest = json.loads((ROOT / 'config/operations.json').read_text())
    payload = {'operationName': 'browsePage', 'variables': {
        'uri': 'spotify:page:0JQ5DAt0tbjZptfcdMSKl3',
        'pagePagination': {'offset': 0, 'limit': 10},
        'sectionPagination': {'offset': 0, 'limit': 10},
        'browseEndUserIntegration': 'INTEGRATION_WEB_PLAYER',
        'includeEpisodeContentRatingsV2': False},
        'extensions': {'persistedQuery': {'version': 1, 'sha256Hash': manifest['operations']['browsePage']['hash']}}}
    with tempfile.TemporaryDirectory(prefix='tops-api-diagnostic-') as private:
        private = Path(private)
        os.chmod(private, 0o700)
        target = private / 'oauth.json'
        with target.open('x') as stream:
            os.chmod(target, 0o600)
            json.dump(saved, stream)
        cached = args.session_dir / 'session'
        if cached.is_dir():
            shutil.copytree(cached, private / 'session')
        process = subprocess.Popen([str(ROOT / 'engine/target/release/tops-engine'), '--data-dir', str(private)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        # Bound helper startup/IPC as well as each HTTP request. No automatic retry
        # or token-refresh probe: an expired grant must be refreshed by Tops itself.
        watchdog = threading.Timer(90 + 30 * len(variants), process.kill)
        watchdog.daemon = True
        watchdog.start()
        try:
            def call(number, method):
                process.stdin.write(json.dumps({'id': number, 'method': method, 'params': {}}) + '\n'); process.stdin.flush()
                while True:
                    line = process.stdout.readline()
                    if not line: raise RuntimeError('Diagnostic helper stopped')
                    value = json.loads(line)
                    if value.get('id') == number:
                        if 'error' in value: raise RuntimeError('Diagnostic helper command failed: ' + method)
                        return value['result']
            call(1, 'authenticate')
            print(json.dumps({'phase': 'authenticated', 'playback_started': False}), flush=True)
            auth = call(2, 'authContext')
            secrets = [saved['access_token'], saved['refresh_token'], auth['access_token'], auth['client_token']]
            for name in variants:
                token_source, desktop, agent, include_client = VARIANTS[name]
                token = saved['access_token'] if token_source == 'oauth' else auth['access_token']
                headers = {'Authorization': 'Bearer ' + token, 'client-token': auth['client_token'], 'Content-Type': 'application/json', 'Accept': 'application/json', 'Accept-Language': 'en', 'Origin': 'https://open.spotify.com'}
                if desktop:
                    headers.update({'App-Platform': 'OSX_ARM64' if platform.machine() == 'arm64' else 'OSX', 'Origin': 'https://xpui.app.spotify.com', 'Referer': 'https://xpui.app.spotify.com'})
                if agent is not None: headers['User-Agent'] = agent
                if not include_client: headers.pop('client-token')
                request = Request(ENDPOINT, data=json.dumps(payload).encode(), headers=headers, method='POST')
                try:
                    response = HTTP.open(request, timeout=30)
                except HTTPError as error:
                    response = error
                with response:
                    body = response.read(2_000_000)
                try: data = json.loads(body)
                except (ValueError, UnicodeDecodeError): data = {}
                if not isinstance(data, dict): data = {}
                # Output only HTTP status, schema names, counts and selected sanitized error strings.
                errors = list(data.get('errors') or [])
                if isinstance(data.get('error'), dict): errors.append(data['error'])
                messages = [str(item.get('message', ''))[:240] for item in errors if isinstance(item, dict)]
                for secret in secrets: messages = [m.replace(secret, '[redacted]') for m in messages]
                browse = (data.get('data') or {}).get('browse') or {}
                print(json.dumps({'auth': name, 'http': response.status, 'content_type': response.headers.get('Content-Type'), 'error_messages': messages, 'response_type': browse.get('__typename'), 'shelf_count': len((browse.get('sections') or {}).get('items', []))}), flush=True)
            call(3, 'shutdown')
        finally:
            watchdog.cancel()
            process.stdin.close()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()

if __name__ == '__main__': main()
