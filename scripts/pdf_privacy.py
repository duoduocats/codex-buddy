"""Strict, bounded privacy scan for the generated installation-guide PDF.

The generator emits a classic PDF 1.4 with ASCII85/Flate streams. Unsupported
encodings fail closed instead of silently skipping a privacy check.
"""
import base64
import io
import re
import zlib
from pypdf import PdfReader
from pypdf.generic import ArrayObject, IndirectObject, StreamObject


def audit_pdf(data, audit_bytes, *, stream_limit=8_000_000, total_limit=16_000_000):
    if not data.startswith(b'%PDF-1.4') or len(data) >= 500_000:
        raise AssertionError('Unexpected installation PDF format or size')
    # A classic, non-incremental cross-reference table avoids decoding an xref
    # stream before the size limits below can apply. Generated guides use this.
    match=re.search(rb'startxref\s+(\d+)\s+%%EOF\s*$',data)
    if not match or data[int(match.group(1)):][:4] != b'xref':
        raise AssertionError('Installation PDF must use a classic xref table')
    if re.search(rb'/(?:Prev|XRefStm)\b',data):
        raise AssertionError('Incremental or hybrid installation PDF is unsupported')
    audit_bytes(data,'installation PDF')
    try:
        reader=PdfReader(io.BytesIO(data),strict=True)
        if reader.is_encrypted or reader.xref_objStm:
            raise AssertionError('Encrypted or object-stream installation PDF is unsupported')
        identifiers=[(number,generation) for generation,table in reader.xref.items()
                     for number in table if number != 0]
        if len(identifiers) > 1_000:
            raise AssertionError('Installation PDF contains too many objects')
        streams=0
        decoded_total=0

        def scan_strings(obj):
            # Include decoded Unicode metadata and text strings, whose UTF-16
            # representation may not match a raw-byte sensitive-pattern scan.
            if isinstance(obj,str):
                audit_bytes(obj.encode('utf-8'),'installation PDF text/metadata')
            elif isinstance(obj,dict):
                for value in obj.values():
                    if not isinstance(value,IndirectObject):
                        scan_strings(value)
            elif isinstance(obj,list):
                for value in obj:
                    if not isinstance(value,IndirectObject):
                        scan_strings(value)

        for number,generation in identifiers:
            obj=reader.get_object(IndirectObject(number,generation,reader))
            scan_strings(obj)
            if not isinstance(obj,StreamObject):
                continue
            streams+=1
            payload=obj._data
            filters=obj.get('/Filter',[])
            if isinstance(filters,IndirectObject):
                filters=filters.get_object()
            if not isinstance(filters,(list,ArrayObject)):
                filters=[filters]
            for name in filters:
                if name in ('/ASCII85Decode','/A85'):
                    payload=base64.a85decode(payload,adobe=True)
                elif name in ('/FlateDecode','/Fl'):
                    inflater=zlib.decompressobj()
                    payload=inflater.decompress(payload,stream_limit+1)
                    if len(payload)>stream_limit or not inflater.eof or inflater.unconsumed_tail:
                        raise AssertionError('Installation PDF stream exceeds its limit or is truncated')
                    if inflater.unused_data:
                        raise AssertionError('Installation PDF stream has trailing encoded data')
                else:
                    raise AssertionError('Unsupported installation PDF stream filter')
                if len(payload)>stream_limit:
                    raise AssertionError('Installation PDF stream exceeds its limit')
            if len(payload)>stream_limit:
                raise AssertionError('Installation PDF stream exceeds its limit')
            decoded_total+=len(payload)
            if decoded_total>total_limit:
                raise AssertionError('Installation PDF decoded data exceeds its total limit')
            audit_bytes(payload,'installation PDF decoded stream')
        if streams == 0:
            raise AssertionError('Installation PDF contains no decoded streams')
        texts=[page.extract_text() or '' for page in reader.pages]
        text='\n'.join(texts)
        audit_bytes(text.encode('utf-8'),'installation PDF extracted text')
        if len(texts)!=2 or '仍要打开' not in text or 'Open Anyway' not in text:
            raise AssertionError('Installation PDF must contain both illustrated language guides')
        return streams
    except AssertionError:
        raise
    except Exception:
        # Parser diagnostics can include source content; keep release logs clean.
        raise AssertionError('Installation PDF could not be safely decoded') from None
