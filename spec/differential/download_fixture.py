"""Generate a deterministic, wholly synthetic EPUB for both implementations."""
import base64,hashlib,io,json,zipfile
from pathlib import Path
io_out=io.BytesIO()
with zipfile.ZipFile(io_out,'w',compression=zipfile.ZIP_STORED) as archive:
 for name,data in [('mimetype',b'application/epub+zip'),('META-INF/container.xml',b'<container/>'),('content.xhtml',b'<html><body>Wholly synthetic authorized fixture.</body></html>'),('LICENSE.txt',b'CC0: synthetic fixture text dedicated to the public domain for testing.')]:
  info=zipfile.ZipInfo(name,date_time=(2020,1,1,0,0,0));archive.writestr(info,data)
data=io_out.getvalue()
Path(__file__).with_name('download_cases.json').write_text(json.dumps(dict(archive_b64=base64.b64encode(data).decode(),md5=hashlib.md5(data).hexdigest(),sha256=hashlib.sha256(data).hexdigest(),bytes=len(data),cases=['success','mismatch','truncated','forbidden','server_error','interrupted','cancelled','crc_corruption']),indent=2)+'\n')
