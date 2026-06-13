import Foundation
import NaturalLanguage

guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
    print("Error: sentence embedding model not available.")
    exit(1)
}

func cosineSimilarity(v1: [Double], v2: [Double]) -> Double {
    guard v1.count == v2.count, !v1.isEmpty else { return 0.0 }
    var dotProduct = 0.0
    var magnitude1 = 0.0
    var magnitude2 = 0.0
    for i in 0..<v1.count {
        dotProduct += v1[i] * v2[i]
        magnitude1 += v1[i] * v1[i]
        magnitude2 += v2[i] * v2[i]
    }
    guard magnitude1 > 0 && magnitude2 > 0 else { return 0.0 }
    return dotProduct / (sqrt(magnitude1) * sqrt(magnitude2))
}

let q = "Where is the database located?"
let m1 = "database_path: /users/test/db"
let m2 = "cake: Baking a delicious chocolate cake recipe"

if let vq = embedding.vector(for: q),
   let vm1 = embedding.vector(for: m1),
   let vm2 = embedding.vector(for: m2) {
    let score1 = cosineSimilarity(v1: vq.map { Double($0) }, v2: vm1.map { Double($0) })
    let score2 = cosineSimilarity(v1: vq.map { Double($0) }, v2: vm2.map { Double($0) })
    print("Similar: \(score1)")
    print("Dissimilar: \(score2)")
}
