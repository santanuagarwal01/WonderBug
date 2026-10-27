#!/usr/bin/env python3
"""Compile an offline Swift bridge using the app's real tokenizer, safety and reranker.

Only a copied service in the build directory gains experiment accessors; app files are
never edited. The SQL adapter lets vector hits use the identical passage preparation.
"""
import argparse,hashlib,json,subprocess
from pathlib import Path

HOOKS='''
extension WikiSearchService {
    func experimentPools(_ question: String) -> [String: [WikiEvidenceRecord]] {
        let raw = Array(Self.words(in: question).prefix(64))
        let content = raw.filter { !Self.stopWords.contains($0) }.map { indexForm($0) }
        guard !content.isEmpty else { return ["article": [], "body": []] }
        let terms = retrievalTerms(content)
        let articles = articleCandidates(question: question, raw: raw, content: content, terms: terms)
        let articlePool = articlePassageCandidates(content: content, terms: terms, articles: articles)
        let bodyPool = directCandidates(question, articleID: nil, limit: 48)
        return ["article": articlePool.map { WikiEvidenceRecord(sourceID: $0.sourceID, title: $0.article.title,
            section: $0.section, text: $0.text, relevance: nil) }, "body": bodyPool.map { $0.record }]
    }
    func experimentPrepare(_ question: String, sourceIDs: [String]) -> [WikiEvidenceRecord] {
        directCandidates(question, articleID: nil, limit: 512, sourceIDs: sourceIDs).map { $0.record }
    }
}
'''

def instrument(source):
 signature='private func directCandidates(_ query: String, articleID: Int64? = nil, limit: Int)'
 assert source.count(signature)==1
 source=source.replace(signature,'private func directCandidates(_ query: String, articleID: Int64? = nil, limit: Int, sourceIDs: [String]? = nil)')
 start=source.index('        step("""',source.index('private func directCandidates'))
 end=source.index('        trace?.retrievedSources',start)
 original=source[start:end]
 branch='''        if let sourceIDs {
            for id in sourceIDs.prefix(256) {
                step("SELECT d.source_id,d.article,d.ordinal,d.title,a.lead,d.section,d.text FROM passage_documents d JOIN articles a ON a.id=d.article WHERE d.source_id=?", [id]) {
                    documents.append((Self.text($0, 0), Article(id: sqlite3_column_int64($0, 1), title: Self.text($0, 3), lead: Self.text($0, 4)), Int(sqlite3_column_int64($0, 2)), Self.text($0, 5), Self.text($0, 6)))
                }
            }
        } else {
'''+original+'        }\n'
 instrumented=source[:start]+branch+source[end:]+HOOKS
 # Canonical preparation must not let one arm's source suppress a different arm's
 # identical-text source. Ordinary keyword retrieval keeps its existing deduplication.
 old='if seen.insert(candidate.record.text).inserted { candidates.append(candidate) }'
 new='if seen.insert(sourceIDs == nil ? candidate.record.text : (candidate.record.sourceID ?? "") + "|" + candidate.record.text).inserted { candidates.append(candidate) }'
 assert instrumented.count(old)==1
 return instrumented.replace(old,new)

def build(repo,output):
 repo=Path(repo);here=Path(__file__).resolve().parent;output=Path(output);output.mkdir(parents=True,exist_ok=True)
 original=repo/'WonderBug/Services/WikiSearchService.swift';copy=output/'WikiSearchService.swift';copy.write_text(instrument(original.read_text()))
 tokenizer=output/'WikiPassageReranker.swift'
 tokenizer.write_text((repo/'WonderBug/Services/WikiPassageReranker.swift').read_text()+"""
// Offline adapter: single-sentence BERT input differs from question/passage input.
extension WikiWordPieceTokenizer {
    func encodeSentence(_ text: String) -> (ids: [Int], mask: [Int], types: [Int]) {
        let ids = [101] + Array(tokens(text).prefix(254)) + [102]
        let padding = Array(repeating: 0, count: 256 - ids.count)
        return (ids + padding, Array(repeating: 1, count: ids.count) + padding, Array(repeating: 0, count: 256))
    }
}
""")
 files=[here/'VectorMain.swift',here/'WikiSentenceEmbedder.swift',copy,tokenizer]+[repo/'WonderBug/Services'/name for name in ['WikiRetrievalTrace.swift','SafetyService.swift','DebugLog.swift']]
 binary=output/'vector-eval'
 subprocess.run(['swiftc','-O','-module-cache-path',str(output/'modules'),*[str(f)for f in files],'-o',str(binary)],check=True)
 report={'original_service_sha256':hashlib.sha256(original.read_bytes()).hexdigest(),'instrumented_service_sha256':hashlib.sha256(copy.read_bytes()).hexdigest(),'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'app_modified':False}
 (output/'build-manifest.json').write_text(json.dumps(report,indent=2)+'\n');print(binary)

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--repo',required=True);p.add_argument('--output',required=True);a=p.parse_args();build(a.repo,a.output)
