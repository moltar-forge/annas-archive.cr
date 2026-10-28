"""Offline full reference flow; no outer challenge retry or actual network."""
import base64,hashlib,json,socket,sys,tempfile,zipfile
from pathlib import Path
reference=Path(sys.argv[1]);fixture=json.loads(Path(sys.argv[2]).read_text())
expected=json.loads(Path(__file__).with_name('reference_hashes.json').read_text())
for name,digest in expected.items():assert hashlib.sha256((reference/name).read_bytes()).hexdigest()==digest,name

def forbidden(*args,**kwargs):raise RuntimeError('Live network prohibited')
socket.getaddrinfo=forbidden;socket.create_connection=forbidden;socket.socket.connect=forbidden;socket.socket.connect_ex=forbidden
sys.path.insert(0,str(reference/'src'))
import httpx
from anna.client import Client,check_status,download_link
from anna.parsing import document
from anna.errors import DownloadWaitError

def one_page(self,path,params=None):
 response=self.http.get(self.base_url+path,params=params);check_status(response);document(response.text);return response
Client.page=one_page
# _download is the inspected bounded ordinary transfer implementation. Never
# invoke download(), whose outer wrapper contains challenge-encoding retries.
Client.download=forbidden
class Cancelled(Exception):pass
class Interrupted(httpx.SyncByteStream):
 def __init__(self,data):self.data=data
 def __iter__(self):
  yield self.data[:512]
  raise httpx.ReadError('fixture interruption')

origin='https://catalog.example.invalid'
rows=[]
for case in fixture['cases']:
 data=base64.b64decode(fixture['archive_b64'])
 if case=='crc_corruption':data=data.replace(b'Wholly synthetic',b'Broken synthetic',1)
 md5='0'*32 if case=='mismatch' else hashlib.md5(data).hexdigest()
 requests=[];slow_calls=[0]
 def handler(request):
  requests.append(str(request.url));path=request.url.path
  if path=='/search':return httpx.Response(200,text=f'<a href="/md5/{md5}"><h3>Public Domain Fixture</h3><div class="text-gray-500">English [en], EPUB, 1 MB</div></a>')
  if path==f'/md5/{md5}':return httpx.Response(200,text=f'<div><div class="text-2xl font-semibold">Public Domain Fixture</div><div class="text-gray-800">English [en] · EPUB · 1 MB</div></div><a class="js-download-link" href="/slow_download/{md5}/0/0">Slow</a>')
  if path.startswith('/slow_download/'):
   slow_calls[0]+=1
   return httpx.Response(200,text='<span class="js-partner-countdown">2</span>' if slow_calls[0]==1 else '<a download href="/files/book.epub">Get</a>')
  if path=='/files/book.epub':return httpx.Response(302,headers={'Location':'/data/book.epub?signature=a%2Bb'})
  assert path=='/data/book.epub'
  status=403 if case=='forbidden' else 500 if case=='server_error' else 200
  headers={'Content-Type':'application/epub+zip','Content-Length':str(len(data)+(1 if case=='truncated' else 0))}
  return httpx.Response(status,headers=headers,stream=Interrupted(data) if case=='interrupted' else httpx.ByteStream(data))
 with tempfile.TemporaryDirectory(prefix='anna-reference-') as directory:
  output=Path(directory)/'book.epub';wait=None;outcome='ok';result=None
  try:
   with Client(origin,transport=httpx.MockTransport(handler)) as client:
    selected=client.search('Public Domain Fixture',lang='en',ext='epub')[0]
    record=client.info(selected.md5)
    route=record.links[0].url
    try:download_link(client.page(route.removeprefix(origin)).text,route)
    except DownloadWaitError as ex:wait=ex.seconds
    resolved=download_link(client.page(route.removeprefix(origin)).text,route)
    def progress(count):
     if case=='cancelled':raise Cancelled()
    result=client._download(resolved,output,Path(directory),selected.md5,progress)
   with zipfile.ZipFile(output) as archive:
    if archive.testzip():raise zipfile.BadZipFile()
  except Exception as ex:
   code=getattr(ex,'code',None)
   outcome='integrity_error' if code=='integrity_error' else 'http_error' if code=='http_error' else 'cancelled' if isinstance(ex,Cancelled) else 'archive_invalid' if isinstance(ex,zipfile.BadZipFile) else 'network_error' if isinstance(ex,httpx.TransportError) else code or type(ex).__name__
  exists=output.exists()
  raw=output.read_bytes() if exists else None
  rows.append(dict(name=case,outcome=outcome,wait_seconds=wait,file_exists=exists,bytes=len(raw) if raw else 0,md5=hashlib.md5(raw).hexdigest() if raw else None,sha256=hashlib.sha256(raw).hexdigest() if raw else None,partial_files=len(list(Path(directory).glob('.anna-*'))),requests=requests))
print(json.dumps(rows))
