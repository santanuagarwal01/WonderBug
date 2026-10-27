"""Build-time wikitext extraction. No question/topic-specific facts or runtime rules.

Preserve prose, labelled infobox values, list entries, and simple labelled table rows.
Complex merged tables and unknown templates are omitted rather than guessed.
"""
import html
import re
from dataclasses import dataclass
import mwparserfromhell as mw
from mwparserfromhell import nodes
import legacy_extractor as legacy

VERSION = 'structured-evidence-v1'
BODY_BUDGET = 4000
SKIP_FIELD = re.compile(r'(?:image|caption|signature|logo|flag|map|style|color|colour|width|height|size|align|background|border|alt|module|embed|child|header|label|data|class|rowclass|rowstyle|coordinates|website|url|footnotes|name|title|honorific)', re.I)
LIST_LINE = re.compile(r'^\s*([*#]+)\s*(.*)$')
HEADING = re.compile(r'^[ \t]*(=+)[ \t]*([^=\n]+?)[ \t]*\1[ \t]*$', re.M)

@dataclass
class Block:
    section: str
    text: str
    kind: str

def plain(value):
    code = value if isinstance(value, mw.wikicode.Wikicode) else mw.parse(str(value))
    out = []
    for node in code.nodes:
        if isinstance(node, nodes.Text): out.append(str(node))
        elif isinstance(node, nodes.HTMLEntity): out.append(node.normalize())
        elif isinstance(node, nodes.Wikilink):
            title = str(node.title).strip()
            if not re.match(r'(?i)^(file|image|media|category):', title):
                out.append(plain(node.text if node.text is not None else node.title))
        elif isinstance(node, nodes.ExternalLink):
            if node.title is not None: out.append(plain(node.title))
        elif isinstance(node, nodes.Tag):
            tag = str(node.tag).strip().lower()
            if tag == 'br': out.append(' ')
            elif tag not in {'ref','references','gallery','math','chem','score','timeline','table','script','style'}:
                out.append(plain(node.contents))
        elif isinstance(node, nodes.Template):
            name = str(node.name).strip().lower().replace('_',' ')
            positional = [p.value for p in node.params if str(p.name).strip().isdigit()]
            if name in {'convert','cvt'}:
                out.append(legacy.CONVERT.sub(legacy.render_convert, str(node)) if legacy.CONVERT.fullmatch(str(node)) else '')
            elif name in {'nowrap','small','smaller','nobr','plainlist','flatlist','ubl','unbulleted list','hlist','plain list'}:
                out.append('; '.join(plain(v).strip('* \n') for v in positional))
            elif name in {'lang','lang-en','lang-fr','lang-de','lang-es','lang-la'} and positional:
                out.append(plain(positional[-1]))
            elif name in {'birth date','birth date and age','death date','death date and age','birth-date','death-date'}:
                vals = [str(v).strip() for v in positional[:3]]
                if len(vals)==3 and all(v.isdigit() for v in vals):
                    out.append(f'{int(vals[0]):04d}-{int(vals[1]):02d}-{int(vals[2]):02d}')
    text = html.unescape(''.join(out))
    text = re.sub(r'\s+', ' ', text).strip()
    text = re.sub(r'\s+([,.;:!?])', r'\1', text)
    return re.sub(r'\(\s*\)', '', text).strip()

def pieces(text, limit=85):
    """Pack complete sentences; never cut a measurement or sentence to meet the budget."""
    sentences = re.split(r'(?<=[.!?])\s+(?=[A-Z])', text)
    result, current = [], ''
    for sentence in sentences:
        if current and len((current+' '+sentence).split()) > limit:
            result.append(current); current = ''
        current = (current+' '+sentence).strip()
    if current: result.append(current)
    return result

def list_label(raw):
    # Explicit source labels only. Do not invent labels by summarizing a statement.
    value = re.sub(r'^(?:A|An|The)\s+', '', raw.strip())
    match = re.match(r"^('{2,3})(.+?)\1", value)
    if match: return plain(match[2])
    code = mw.parse(value)
    if code.nodes and isinstance(code.nodes[0], nodes.Wikilink): return plain(code.nodes[0])
    if len(plain(raw).split()) <= 8: return plain(raw)
    return None

def table_blocks(table, section):
    # Row/column span interpretation needs a full rendered DOM. Reject, do not mislabel.
    if any(str(a.name).lower() in {'rowspan','colspan'} and str(a.value).strip('"\' ') != '1'
           for t in table.contents.filter_tags() for a in t.attributes): return []
    headers = []
    direct = table.contents.filter_tags(recursive=False)
    for t in direct:
        if str(t.tag).lower() == 'th': headers.append(plain(t.contents))
    rows = [t for t in direct if str(t.tag).lower() == 'tr']
    out=[]
    for row in rows:
        cells = [t for t in row.contents.filter_tags(recursive=False) if str(t.tag).lower() in {'td','th'}]
        if cells and all(str(t.tag).lower()=='th' for t in cells):
            headers=[plain(t.contents) for t in cells]; continue
        values=[plain(t.contents) for t in cells]
        if headers and len(headers)==len(values) and all(headers):
            out.append(Block(section, '; '.join(h+': '+v for h,v in zip(headers,values) if v)+'.', 'table'))
    return out

def extract(raw, title, lead, budget=BODY_BUDGET):
    code=mw.parse(raw)
    blocks=[]
    for template in code.filter_templates(recursive=False):
        name=str(template.name).strip().lower().replace('_',' ')
        if name.startswith('infobox'):
            for param in template.params:
                key=str(param.name).strip()
                if not param.showkey or key.isdigit() or SKIP_FIELD.search(key): continue
                value=plain(param.value)
                if not value or len(value)>350 or not re.search(r'[A-Za-z]',value): continue
                label=key.replace('_',' ').strip()
                blocks.append(Block('Infobox', f'{title}: {label}: {value.rstrip(".")}.', 'infobox'))
            code.replace(template,'\n\n')
    raw=str(code)
    matches=list(HEADING.finditer(raw))
    sections=[('',raw[:matches[0].start()] if matches else raw)]
    stack=[]; skip_depth=None
    for i,m in enumerate(matches):
        depth=len(m[1]); name=plain(m[2])
        if skip_depth is not None and depth>skip_depth: continue
        skip_depth=None
        if name.lower() in legacy.SKIP_SECTIONS:
            skip_depth=depth; continue
        while stack and stack[-1][0]>=depth: stack.pop()
        stack.append((depth,name))
        sections.append((' / '.join(n for _,n in stack),raw[m.end():matches[i+1].start() if i+1<len(matches) else len(raw)]))
    for section, source in sections:
        section_code=mw.parse(source)
        for table in list(section_code.filter_tags(recursive=False)):
            if str(table.tag).lower()=='table':
                blocks.extend(table_blocks(table,section)); section_code.replace(table,'\n\n')
        lines=str(section_code).splitlines()
        prose=[]; group=[]
        def flush_prose():
            text=plain('\n'.join(prose)); prose.clear()
            if not text or text in lead: return
            if lead and text.startswith(lead) and lead[-1:] in '.!?': text=text[len(lead):].strip()
            for p in pieces(text):
                if len(p)>=20: blocks.append(Block(section,p,'prose'))
        def flush_list():
            if not group: return
            labels=[list_label(item) for _,item in group]
            if len(labels)>=2 and all(labels) and len('; '.join(labels).split())<=85:
                blocks.append(Block(section, 'List entries'+(' under '+section if section else '')+': '+'; '.join(labels)+'.', 'list_overview'))
            parents=[]
            for depth,item in group:
                text=plain(item)
                while len(parents)>=depth: parents.pop()
                path=' > '.join(parents)
                if text:
                    for p in pieces((path+': ' if path else '')+text): blocks.append(Block(section,p,'list'))
                parents.append(text)
            group.clear()
        for line in lines:
            m=LIST_LINE.match(line)
            if m:
                flush_prose(); group.append((len(m[1]),m[2]))
            elif not line.strip(): flush_prose(); flush_list()
            else:
                flush_list(); prose.append(line)
        flush_prose(); flush_list()
    # Reserve some of the SAME per-article budget for previously discarded structure.
    selected=[]; seen=set(); remaining=budget
    def take(block):
        nonlocal remaining
        text=block.text.strip()
        key=' '.join(text.lower().split())
        if key in seen or len(text)+1>remaining or len(text)>1500: return False
        if text in lead: return False
        selected.append(block); seen.add(key); remaining-=len(text)+1; return True
    structured_used=0
    for kind in ['list_overview','infobox','table']:
        for block in blocks:
            if block.kind==kind and structured_used+len(block.text)<=min(1200,budget):
                if take(block): structured_used+=len(block.text)
    # Keep explanatory prose ahead of long catalogues once structure has its reservation.
    for block in blocks:
        if block.kind=='prose': take(block)
    for block in blocks:
        if block.kind not in {'infobox','prose'}: take(block)
    packed=[]
    for block in selected:
        if (packed and block.kind in {'list','infobox','table'} and
            (packed[-1].section,packed[-1].kind)==(block.section,block.kind) and
            len((packed[-1].text+' '+block.text).split())<=85):
            packed[-1]=Block(block.section,packed[-1].text+' '+block.text,block.kind)
        else: packed.append(block)
    return packed
