#!/usr/bin/env python3
"""Synthetic regression cases for the release PDF privacy gate. No live secrets."""
from pathlib import Path
import base64
import re
import zlib
from pdf_privacy import audit_pdf

ROOT=Path(__file__).resolve().parent.parent
PATTERNS=[rb'/(?:Users|home)/[A-Za-z0-9_.-]+/',rb'gh[pousr]_[A-Za-z0-9]{30,}']

def audit(data,name):
    assert not any(re.search(pattern,data) for pattern in PATTERNS), 'Sensitive pattern in '+name

def fixture(payload,filters=b'',metadata=b''):
    # No newline before endstream, matching the real ReportLab output. Exact
    # Length plus a classic xref table lets the parser distinguish stream bytes.
    objects=[
        b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
        b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
        b'<< /Length '+str(len(payload)).encode()+b' '+filters+b' >>\nstream\n'+payload+b'endstream',
    ]
    if metadata:
        objects.append(b'<< /Title <'+metadata.hex().encode()+b'> >>')
    document=b'%PDF-1.4\n'
    offsets=[]
    for number,obj in enumerate(objects,1):
        offsets.append(len(document))
        document+=str(number).encode()+b' 0 obj\n'+obj+b'\nendobj\n'
    xref=len(document)
    document+=b'xref\n0 '+str(len(objects)+1).encode()+b'\n0000000000 65535 f \n'
    for offset in offsets:
        document+=f'{offset:010d} 00000 n \n'.encode()
    document+=b'trailer\n<< /Size '+str(len(objects)+1).encode()+b' /Root 1 0 R >>\nstartxref\n'+str(xref).encode()+b'\n%%EOF\n'
    return document

def rejected(data,reason,**limits):
    try:
        audit_pdf(data,audit,**limits)
    except AssertionError as error:
        assert reason in str(error), 'Unexpected PDF audit failure category'
    else:
        raise AssertionError('Unsafe PDF passed its audit')

guide=(ROOT/'docs/install/Installation-Guide.pdf').read_bytes()
assert b'~>endstream' in guide, 'Real guide no longer exercises the missing-newline regression'
count=audit_pdf(guide,audit)
assert count==7, 'Every stream in the actual two-page guide must be decoded'

private_path='/'+ '/'.join(['Users','synthetic-fixture','file'])
token='gh'+'p_'+'A'*40
content=('BT /F1 12 Tf ('+private_path+' '+token+') Tj ET').encode()
compressed=zlib.compress(content)
ascii85=base64.a85encode(compressed)+b'~>'
assert private_path.encode() not in ascii85 and token.encode() not in ascii85
rejected(fixture(ascii85,b'/Filter [/ASCII85Decode /FlateDecode]'),'Sensitive pattern')
rejected(fixture(compressed,b'/Filter /FlateDecode'),'Sensitive pattern')
rejected(fixture(content),'Sensitive pattern')
escaped=''.join('\\'+format(ord(char),'03o') for char in private_path)
escaped_content=('BT /F1 12 Tf ('+escaped+') Tj ET').encode()
assert private_path.encode() not in escaped_content
rejected(fixture(zlib.compress(escaped_content),b'/Filter /FlateDecode'),'Sensitive pattern')
rejected(fixture(b'BT ET',metadata=b'\xfe\xff'+private_path.encode('utf-16-be')),'Sensitive pattern')
rejected(fixture(b'unknown',b'/Filter /LZWDecode'),'Unsupported')
rejected(fixture(zlib.compress(b'A'*50_000),b'/Filter /FlateDecode'),'limit',stream_limit=1_024)
rejected(fixture(compressed[:-2],b'/Filter /FlateDecode'),'truncated')
rejected(guide,'total limit',total_limit=1_024)
print(f'PDF privacy passed: {count} real decoded streams, compressed/Unicode secrets rejected, bounded fail-closed decoding')
