"""Pinned original retry methods, offline MockTransport only; never CLI execution."""
import base64, hashlib, json, socket, sys, tempfile, zipfile
from pathlib import Path

reference = Path(sys.argv[1]).resolve()
expected = json.loads((Path(__file__).parent / 'reference_hashes.json').read_text())
for name, digest in expected.items():
    assert hashlib.sha256((reference / name).read_bytes()).hexdigest() == digest, name

def no_network(*args, **kwargs):
    raise RuntimeError('Live network forbidden in challenge comparison')
socket.getaddrinfo = no_network
socket.create_connection = no_network
socket.socket.connect = no_network
socket.socket.connect_ex = no_network
sys.path.insert(0, str(reference / 'src'))
import httpx
from anna.client import Client

origin = 'https://catalog.example.invalid'
challenge = '<title>Just a moment</title>'
archive = base64.b64decode(json.loads((Path(__file__).parent / 'download_cases.json').read_text())['archive_b64'])
md5 = hashlib.md5(archive).hexdigest()
results = []
for name in ['query_success', 'query_bounded', 'query_plain403', 'query_second429', 'slow_success', 'slow_bounded', 'slow_external', 'slow_encoded']:
    requests = []
    slow = name.startswith('slow_')
    def handler(request):
        requests.append(dict(url=str(request.url), cookie=request.headers.get('cookie')))
        if name == 'query_plain403':
            return httpx.Response(403, text='<html>ordinary denial</html>')
        if name == 'query_second429' and len(requests) == 2:
            return httpx.Response(429, headers={'Retry-After': '120'})
        if len(requests) == 1 or name.endswith('bounded') or name in {'slow_external', 'slow_encoded'}:
            return httpx.Response(403, text=challenge, headers={'Set-Cookie': 'session=test; Path=/; Secure'})
        return httpx.Response(200, content=archive if slow else b'<p>No results found</p>', headers={'Content-Type': 'application/epub+zip' if slow else 'text/html'})
    outcome = 'ok'
    artifact = None
    with tempfile.TemporaryDirectory() as directory:
        try:
            with Client(origin, transport=httpx.MockTransport(handler)) as client:
                if slow:
                    url = origin + '/slow_download/' + md5 + '/0/0?sig=a%2Bb&x=1&x=2&empty=&z=%ff+%20'
                    if name == 'slow_external': url = url.replace('catalog.example.invalid', 'other.example.invalid')
                    if name == 'slow_encoded': url = url.replace('/slow_download/', '/slow%5Fdownload/')
                    path = Path(directory) / 'book.epub'
                    client.download(url, output=path, expected_md5=md5, max_wait=0)
                    saved = path.read_bytes()
                    with zipfile.ZipFile(path) as zip:
                        assert zip.testzip() is None
                        assert zip.read('mimetype') == b'application/epub+zip'
                    artifact = dict(bytes=len(saved), md5=hashlib.md5(saved).hexdigest(), sha256=hashlib.sha256(saved).hexdigest())
                else:
                    assert client.search('中文 & Austen', ext=['epub', 'pdf']) == []
        except Exception as ex:
            outcome = getattr(ex, 'code', type(ex).__name__)
            if outcome == 'http_error': outcome = 'access_denied'
        files = len(list(Path(directory).iterdir()))
    results.append(dict(name=name, outcome=outcome, requests=requests, artifact=artifact, files=files))
print(json.dumps(results))
