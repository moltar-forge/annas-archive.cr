"""Offline reference oracle. Imported reference code is pinned and network disabled."""
import json
import socket
import sys
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

reference = Path(sys.argv[1]).resolve()
# Pin executable source content, not a mutable branch or installed CLI entrypoint.
import hashlib
expected = json.loads((Path(__file__).parent / 'reference_hashes.json').read_text())
for name, digest in expected.items():
    assert hashlib.sha256((reference / name).read_bytes()).hexdigest() == digest, name

def no_network(*args, **kwargs):
    raise RuntimeError('Live network forbidden in differential tests')
socket.getaddrinfo = no_network
socket.create_connection = no_network
socket.socket.connect = no_network
socket.socket.connect_ex = no_network
sys.path.insert(0, str(reference / 'src'))
import httpx
from anna.client import Client, check_status, download_link
from anna.parsing import document, parse_search, parse_info
from anna.errors import DownloadWaitError

# Never execute the reference's challenge retry branch. The successful ordinary
# path is unchanged; challenge fixtures use only the pure document parser.
def one_page(self, path, params=None):
    response = self.http.get(self.base_url + path, params=params)
    check_status(response)
    document(response.text)
    return response
Client.page = one_page
Client.download = no_network

def project(book):
    return dict(md5=book.md5, url=book.url, title=book.title, language=book.language.lower(), format=book.format,
                summary=book.metadata, author=book.author, publisher=book.publisher,
                size=book.size, cover_url=book.cover_url, description=book.description,
                links=[dict(url=x.url, kind={'fast':'member','slow':'browser'}.get(x.kind,x.kind), label=x.label) for x in book.links])

def run(case):
    origin = 'https://catalog.example.invalid'
    body = case.get('body','')
    if case['kind'] == 'search_limit':
        return [project(x) for x in parse_search(body, origin)[:case['limit']]]
    if case['kind'] == 'search':
        return [project(x) for x in parse_search(body, origin)]
    if case['kind'] == 'detail':
        return project(parse_info(body, origin, '1'*32))
    if case['kind'] == 'landing':
        try: return dict(url=download_link(body, origin+'/slow_download/'+'1'*32+'/0/0'), wait_seconds=None)
        except DownloadWaitError as ex: return dict(url=None, wait_seconds=ex.seconds)
    if case['kind'] == 'redirect':
        requests=[]
        def handler(request):
            requests.append(str(request.url))
            if request.url.path=='/search': return httpx.Response(302,headers={'Location':'/results?signature=a%2Bb'})
            return httpx.Response(200,text=body)
        with Client(origin,transport=httpx.MockTransport(handler)) as client:
            books=client.search('Example')
        return dict(requests=requests,count=len(books))
    if case['kind'] == 'cooldown':
        requests=[]; errors=[]
        def handler(request):
            requests.append(str(request.url))
            return httpx.Response(case['status'],text=body,headers={'Retry-After':'90'})
        with Client(origin,transport=httpx.MockTransport(handler)) as client:
            for _ in range(2):
                try: client.search('Example')
                except Exception as ex: errors.append(ex.code)
        return dict(request_count=len(requests),errors=errors)
    if case['kind'] == 'request':
        requests=[]
        def handler(request):
            requests.append(dict(path=request.url.path, params=parse_qsl(request.url.query.decode(), keep_blank_values=True)))
            return httpx.Response(200,text='<p>No results found</p>')
        with Client(origin, transport=httpx.MockTransport(handler)) as client:
            client.search(case['query'], **case.get('filters',{}))
        return requests
    if case['kind'] == 'error':
        # Pure status/body classification only: no Client.page and no retry.
        check_status(httpx.Response(case.get('status',200), text=body))
        document(body)
        return dict(ok=True)
    raise ValueError(case['kind'])

cases=json.loads(Path(sys.argv[2]).read_text())
results=[]
for case in cases:
    try: value=run(case); results.append(dict(name=case['name'],value=value))
    except Exception as ex:
        code=getattr(ex,'code',type(ex).__name__)
        if code=='http_error': code={401:'authentication_required',403:'access_denied'}.get(case.get('status'),'unavailable')
        results.append(dict(name=case['name'],error=code))
print(json.dumps(results,ensure_ascii=False))
