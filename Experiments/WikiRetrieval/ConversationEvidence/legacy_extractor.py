# Archived extraction functions from the original local Tools repository, for audit parity only.
"""Stream the Simple English Wikipedia XML dump into a SQLite FTS5 index of article lead sections,
plus the body paragraphs that follow them.

Only the lead is searchable (the `fts` table): an article is still chosen by its title and opening,
exactly as before. The body paragraphs are stored so that once an article is chosen, a follow-up
question can be answered from the part of it that matches ("How long do they live?" → the Elephant
article's lifespan paragraph, which its opening never mentions).

Usage: python3 build_index.py OUT.db [PAGE_LIMIT]
"""
import html
import os
import re
import sqlite3
import sys
import time
import xml.etree.ElementTree as ET

NS = '{http://www.mediawiki.org/xml/export-0.11/}'
SRC = os.path.expanduser('~/Downloads/simplewiki-latest-pages-articles.xml')
OUT = None
PAGE_LIMIT = None
LEAD_CAP = 1000
# Per-article body budget. Kids' follow-ups are answered by the descriptive sections near the top
# (diet, size, life), not by the filmography at the bottom, so a cap costs little and keeps the
# shipped database from growing without bound.
BODY_CAP = 4000
PARAGRAPH_MIN = 80

HEADING = re.compile(r'^\s*=+[^=\n]+=+\s*$', re.M)
# Same heading, but capturing its level and name so the body can be split into sections.
HEADING_PARTS = re.compile(r'^[ \t]*(=+)[ \t]*([^=\n]+?)[ \t]*\1[ \t]*$', re.M)
BLANK_LINE = re.compile(r'\n\s*\n')
# Sections that are link lists, citations or trivia: never an answer to a child's question.
SKIP_SECTIONS = {
    'references', 'other websites', 'related pages', 'see also', 'further reading', 'notes',
    'sources', 'external links', 'bibliography', 'gallery', 'footnotes', 'citations', 'media',
    'discography', 'filmography', 'awards', 'honours', 'honors', 'publications', 'works',
    'external sources',
}
# Wikitext line starts that are markup rather than prose (lists, tables, indents).
MARKUP_LINE = ('*', '#', ';', ':', '|', '!', '{', '}', '__', '=')
DISAMBIG = re.compile(
    r'\{\{\s*(disambig|disambiguation|dab|hndis|surname|given name|geodis|numberdis)\b', re.I)
COMMENT = re.compile(r'<!--.*?-->', re.S)
REF_SELF = re.compile(r'<ref[^>]*/>', re.I)
REF_PAIR = re.compile(r'<ref[^>]*>.*?</ref>', re.I | re.S)
TEMPLATE = re.compile(r'\{\{|\}\}')
TABLE = re.compile(r'\{\||\|\}')
FILE_LINK = re.compile(r'\[\[\s*(?:File|Image|Media|Category)\s*:', re.I)
BRACKETS = re.compile(r'\[\[|\]\]')
LINK = re.compile(r'\[\[(?:[^\[\]|]*\|)?([^\[\]]*)\]\]')
EXT_LINK = re.compile(r'\[(?:https?:)?//[^\s\]]+\s*([^\]]*)\]')
QUOTES = re.compile(r"'{2,}")
TAG = re.compile(r'<[^>]+>')
EMPTY_PARENS = re.compile(r'\(\s*[,;:]?\s*\)')
SPACE = re.compile(r'\s+')
SPACE_PUNCT = re.compile(r'\s+([,.;:!?])')
LEFTOVER_LINE = ('|', '!', '{', '}', '__')

CONVERT = re.compile(r'\{\{\s*(?:convert|cvt)\s*\|([^{}]*)\}\}', re.I)
NUMBER = re.compile(r'^[-−]?[\d.,]+$')
RANGE_WORDS = {'-': 'to', '–': 'to', 'to': 'to', 'and': 'and', 'or': 'or', 'x': 'by', 'by': 'by'}
UNITS = {
    'm': 'metres', 'meter': 'metres', 'metre': 'metres', 'km': 'kilometres', 'cm': 'centimetres',
    'mm': 'millimetres', 'ft': 'feet', 'foot': 'feet', 'feet': 'feet', 'in': 'inches', 'inch': 'inches',
    'mi': 'miles', 'mile': 'miles', 'yd': 'yards', 'kg': 'kilograms', 'g': 'grams', 'lb': 'pounds',
    't': 'tonnes', 'tonne': 'tonnes', 'ton': 'tons', 'C': 'degrees Celsius', 'F': 'degrees Fahrenheit',
    'K': 'kelvin', 'km2': 'square kilometres', 'sqmi': 'square miles', 'm2': 'square metres',
    'mph': 'miles per hour', 'km/h': 'kilometres per hour', 'kph': 'kilometres per hour',
    'ha': 'hectares', 'acre': 'acres', 'L': 'litres', 'l': 'litres',
}


def render_convert(match):
    """{{convert|8848|m|ft}} -> "8848 metres", {{cvt|13|ft|8|in}} -> "13 feet 8 inches". The number
    lives inside the template, so stripping it like any other template deletes the measurement."""
    parts = [p.strip() for p in match.group(1).split('|') if '=' not in p]
    if not parts or not NUMBER.match(parts[0]):
        return ''
    out, i = [parts[0]], 1
    if i + 1 < len(parts) and parts[i] in RANGE_WORDS and NUMBER.match(parts[i + 1]):
        out += [RANGE_WORDS[parts[i]], parts[i + 1]]
        i += 2
    if i < len(parts):
        out.append(UNITS.get(parts[i], parts[i]))
        i += 1
    if i + 1 < len(parts) and NUMBER.match(parts[i]) and parts[i + 1] in UNITS:
        out += [parts[i], UNITS[parts[i + 1]]]
    return ' '.join(out)


def strip_balanced(text, pattern, opener):
    """Remove every balanced span delimited by `pattern` (e.g. nested {{templates}})."""
    out, depth, last = [], 0, 0
    for m in pattern.finditer(text):
        if m.group() == opener:
            if depth == 0:
                out.append(text[last:m.start()])
            depth += 1
        elif depth:
            depth -= 1
            if depth == 0:
                last = m.end()
    if depth == 0:
        out.append(text[last:])
    return ''.join(out)


def strip_file_links(text):
    """Remove [[File:...]] / [[Category:...]] links, whose captions can contain nested links."""
    out, pos = [], 0
    while True:
        m = FILE_LINK.search(text, pos)
        if not m:
            out.append(text[pos:])
            return ''.join(out)
        out.append(text[pos:m.start()])
        depth, end = 0, len(text)
        for b in BRACKETS.finditer(text, m.start()):
            depth += 1 if b.group() == '[[' else -1
            if depth == 0:
                end = b.end()
                break
        pos = end


def clean(raw):
    t = COMMENT.sub('', raw)
    t = REF_SELF.sub('', t)
    t = REF_PAIR.sub('', t)
    t = CONVERT.sub(render_convert, t)
    t = strip_balanced(t, TEMPLATE, '{{')
    t = strip_balanced(t, TABLE, '{|')
    t = strip_file_links(t)
    for _ in range(2):
        t = LINK.sub(r'\1', t)
    t = EXT_LINK.sub(r'\1', t)
    t = QUOTES.sub('', t)
    t = TAG.sub('', t)
    t = html.unescape(t)
    t = '\n'.join(l for l in t.split('\n') if not l.lstrip().startswith(LEFTOVER_LINE))
    t = EMPTY_PARENS.sub('', t)
    t = SPACE.sub(' ', t).strip()
    return SPACE_PUNCT.sub(r'\1', t)


def cap(text):
    if len(text) <= LEAD_CAP:
        return text
    cut = text.rfind('. ', 0, LEAD_CAP)
    return text[:cut + 1] if cut > 0 else text[:LEAD_CAP]


def body_paragraphs(raw, start):
    """(section heading, paragraph) pairs from the article body, in document order.

    `start` is where the lead ends, i.e. the first heading. Skipped: the link-list and citation
    sections, bullet lists, and anything shorter than a sentence or two."""
    parts = HEADING_PARTS.split(raw[start:])
    out, skip_depth = [], None
    for i in range(1, len(parts), 3):
        depth, name, text = len(parts[i]), parts[i + 1].strip(), parts[i + 2]
        # A skipped heading takes its subsections with it ("References" → "Citations").
        if skip_depth is not None and depth > skip_depth:
            continue
        skip_depth = None
        if name.lower() in SKIP_SECTIONS:
            skip_depth = depth
            continue
        # Bullet and indent lines are dropped before cleaning, since cleaning collapses newlines.
        # Table and template lines are left to clean(), which needs them to stay balanced.
        text = '\n'.join(l for l in text.split('\n') if not l.lstrip().startswith(('*', '#', ';', ':')))
        for chunk in clean(BLANK_LINE.sub('\n\x00\n', text)).split('\x00'):
            chunk = chunk.strip()
            if len(chunk) < PARAGRAPH_MIN or chunk.endswith(':'):
                continue  # a paragraph ending in ':' introduces a list that was just dropped
            # Colour tables, coordinates and statistics read as gibberish to a child: the Rainbow
            # article's colour list ("Red (Hex: #FF0000) (RGB: 255, 0, 0)") scores 0.79 here, while
            # ordinary prose full of measurements ("251 pounds (114 kg)") stays above 0.85.
            if sum(c.isalpha() or c.isspace() for c in chunk) / len(chunk) >= 0.85:
                out.append((name, chunk))
    return out
