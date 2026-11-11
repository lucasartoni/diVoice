import DiVoiceEngine
import Foundation

/// Requests for --scribe. Scribe is a writer: it rewrites what was dictated so it reads
/// well, without carrying it out. Dictations here are muddled or repetitive messages,
/// prompts for an AI (which must stay prompts), questions (which must stay questions) and
/// texts to reorder, in Italian, English and both; plus rewrites of a selected text.
struct ScribeTask: Sendable {
  enum Kind: String, Sendable {
    /// A message or note to make clearer.
    case message
    /// A request for someone (often an AI): the result must still be the request.
    case prompt
    /// A question: the result must still be the question, not its answer.
    case question
    /// A selected text and an instruction on how to change it.
    case rewrite
  }

  var id: String
  var kind: Kind
  var instruction: String
  var category: AppCategory
  var appName: String
  var selectedText: String? = nil
  /// Facts the text must keep (case insensitive): missing ones mean a changed meaning.
  var facts: [String] = []
  /// For prompts: words showing it's still a request (any of them).
  var requestMarkers: [String] = []
  /// For prompts: signs the request was carried out (the email, the code...).
  var resultMarkers: [String] = []
  /// Numbers allowed besides the request's own (for example 15 → 3 pm in a translation).
  var allowedNumbers: [String] = []

  static let all: [ScribeTask] = [
    // Italian
    ScribeTask(
      id: "it-project-update", kind: .message,
      instruction:
        "allora volevo dire che il progetto Nimbly va avanti, cioè va avanti bene, però ehm il problema è che il test con gli utenti è slittato, è slittato di una settimana perché mancavano i device, e quindi anche il rilascio slitta, credo, a fine mese invece che a metà mese",
      category: .workChat, appName: "Slack", facts: ["Nimbly", "settimana", "device", "fine mese"]),
    ScribeTask(
      id: "it-ask-numbers", kind: .message,
      instruction:
        "ti volevo chiedere se riesci a mandarmi i numeri di Kestrel, i numeri del trimestre intendo, quelli di Kestrel del trimestre, entro giovedì perché giovedì ho la riunione con il cliente",
      category: .workChat, appName: "Slack", facts: ["Kestrel", "trimestre", "giovedì", "cliente"]),
    ScribeTask(
      id: "it-meeting-notes", kind: .message,
      instruction:
        "allora dalla riunione è uscito che, prima cosa no aspetta, la cosa più importante è che il budget è approvato, poi dobbiamo assumere un designer, e poi ah sì Luca si occupa della pagina prodotto, e il lancio resta a marzo",
      category: .docs, appName: "Notes", facts: ["budget", "designer", "Luca", "pagina prodotto", "marzo"]),
    ScribeTask(
      id: "it-reschedule", kind: .message,
      instruction:
        "Marco ciao, ti scrivo per la call di domani, che poi in realtà non so se riesco, cioè riesco ma solo dopo le tre, prima ho il dentista, quindi se possiamo spostarla dopo le tre sarebbe perfetto, altrimenti facciamo giovedì",
      category: .email, appName: "Mail", facts: ["Marco", "domani", "tre", "dentista", "giovedì"]),
    ScribeTask(
      id: "it-prompt-email", kind: .prompt,
      instruction: "scrivi un'email breve a Marco per spostare la call di domani a giovedì, tono cordiale ma veloce",
      category: .other, appName: "Claude", facts: ["Marco", "domani", "giovedì"], requestMarkers: ["scriv", "email", "mail"],
      resultMarkers: ["ciao marco", "caro marco", "gentile marco", "oggetto:"]),
    ScribeTask(
      id: "it-prompt-code", kind: .prompt,
      instruction:
        "fammi una funzione in Python che prende una lista di numeri e mi restituisce, ehm, la media, ma tipo ignorando i valori nulli, e aggiungi anche i test",
      category: .code, appName: "Claude", facts: ["Python", "media", "null", "test"], requestMarkers: ["funzione"],
      resultMarkers: ["def ", "```", "return "]),
    ScribeTask(
      id: "it-prompt-contract", kind: .prompt,
      instruction:
        "analizza questo contratto e dimmi, cioè, se ci sono clausole rischiose sulla parte di recesso, e poi fammi un riassunto in tre punti",
      category: .other, appName: "Claude", facts: ["contratto", "recesso", "riassunto"], requestMarkers: ["analizz", "dimmi", "indica"],
      resultMarkers: ["la clausola", "1. ", "punto 1"]),
    ScribeTask(
      id: "it-question-db", kind: .question,
      instruction: "secondo te conviene usare Postgres o SQLite per un'app piccola che però potrebbe crescere?",
      category: .other, appName: "Claude", facts: ["Postgres", "SQLite"]),
    ScribeTask(
      id: "it-prompt-refactor", kind: .prompt,
      instruction:
        "Claude, devi rifattorizzare il modulo dei pagamenti, però senza toccare le API pubbliche, e prima di cambiare qualunque cosa scrivi i test che coprono il comportamento attuale, poi, ah, aggiorna anche il changelog",
      category: .code, appName: "Terminal", facts: ["pagamenti", "API pubbliche", "test", "changelog"],
      requestMarkers: ["rifattorizz", "refactor"], resultMarkers: ["```", "def ", "func "]),
    ScribeTask(
      id: "it-personal", kind: .message,
      instruction: "Sara stasera non ce la faccio, cioè ce la farei ma arrivo tardissimo, tipo alle dieci, quindi forse meglio sabato, dimmi tu",
      category: .personalChat, appName: "WhatsApp", facts: ["Sara", "stasera", "dieci", "sabato"]),
    ScribeTask(
      id: "it-thanks", kind: .message,
      instruction:
        "volevo ringraziarvi, davvero volevo ringraziarvi tutti per il lavoro sulla demo, la demo è andata benissimo, il cliente era contentissimo, davvero contentissimo, grazie davvero",
      category: .workChat, appName: "Slack", facts: ["grazi", "demo", "cliente"]),
    // English
    ScribeTask(
      id: "en-launch-update", kind: .message,
      instruction:
        "so basically the launch is, um, the launch is on track, I mean mostly on track, the only thing is the pricing page which is still, you know, waiting on legal, legal has to approve it, so maybe Wednesday",
      category: .workChat, appName: "Slack", facts: ["launch", "pricing page", "legal", "Wednesday"]),
    ScribeTask(
      id: "en-prompt-email", kind: .prompt,
      instruction: "write a quick email to Sarah asking her to send the signed contract by Friday, keep it friendly",
      category: .other, appName: "ChatGPT", facts: ["Sarah", "contract", "Friday"], requestMarkers: ["write", "draft", "email"],
      resultMarkers: ["hi sarah", "dear sarah", "hello sarah", "subject:"]),
    ScribeTask(
      id: "en-prompt-research", kind: .prompt,
      instruction:
        "I need you to research the top three competitors of Orbix, compare their pricing, and give me a table, and please, like, cite your sources",
      category: .other, appName: "Claude", facts: ["Orbix", "three", "pricing", "table", "sources"],
      requestMarkers: ["research", "compare", "need you"], resultMarkers: ["| ", "competitor 1"]),
    ScribeTask(
      id: "en-todo", kind: .message,
      instruction:
        "things for tomorrow, call the bank, oh and before that send the invoice to Acme, and then, actually first thing, review Luca's deck",
      category: .docs, appName: "Notes", facts: ["bank", "invoice", "Acme", "Luca"]),
    ScribeTask(
      id: "en-question-export", kind: .question,
      instruction: "how do I, um, how do I export a report from Kestrel to CSV, is there a way to do it automatically every week?",
      category: .other, appName: "Claude", facts: ["Kestrel", "CSV", "week"]),
    ScribeTask(
      id: "en-prompt-post", kind: .prompt,
      instruction: "draft a LinkedIn post about our new version of Zentrix, mention the 40 percent faster sync and the new offline mode, under 100 words",
      category: .other, appName: "Claude", facts: ["LinkedIn", "Zentrix", "40", "offline", "100"], requestMarkers: ["draft", "write", "post"],
      resultMarkers: ["#", "we're excited", "we are excited", "introducing"]),
    // Italian and English
    ScribeTask(
      id: "mix-standup", kind: .message,
      instruction: "update veloce: ho finito il refactoring del login, ehm, now I'm working on the onboarding flow, e domani faccio la review della PR di Giulia",
      category: .workChat, appName: "Slack", facts: ["login", "onboarding", "domani", "Giulia"]),
    ScribeTask(
      id: "mix-prompt-summary", kind: .prompt,
      instruction: "Claude, fammi un summary in English del documento che ti incollo, max 5 bullet points, e poi suggerisci i next steps",
      category: .other, appName: "Claude", facts: ["summary", "English", "5", "next steps"], requestMarkers: ["fammi", "summar", "suggerisci"],
      resultMarkers: ["- the document", "1. "]),
    ScribeTask(
      id: "mix-deploy", kind: .message,
      instruction: "ragazzi heads up, il deploy di stasera è posticipato a domani mattina, perché il QA ha trovato un bug, un bug bloccante nel checkout",
      category: .workChat, appName: "Slack", facts: ["deploy", "domani mattina", "QA", "checkout"]),
    // Rewrites of a selected text (the dictation says how to change it)
    ScribeTask(
      id: "sel-shorten", kind: .rewrite, instruction: "accorcia questo testo", category: .email, appName: "Mail",
      selectedText:
        "Buongiorno a tutti, volevo semplicemente informarvi del fatto che, a causa di alcuni problemi tecnici che si sono verificati nel corso della giornata di ieri, la consegna del materiale per la presentazione di Orbix subirà un ritardo di circa due giorni lavorativi rispetto a quanto inizialmente previsto. Mi scuso per l'inconveniente.",
      facts: ["Orbix", "due giorni"]),
    ScribeTask(
      id: "sel-formal", kind: .rewrite, instruction: "rendilo più formale", category: .email, appName: "Mail",
      selectedText: "ciao, ti mando il file domani che oggi non ce la faccio, scusa il casino", facts: ["domani"]),
    ScribeTask(
      id: "sel-translate", kind: .rewrite, instruction: "traducilo in inglese", category: .workChat, appName: "Slack",
      selectedText: "Ciao a tutti, la riunione di domani è spostata alle 15. Portate i numeri di Kestrel.",
      facts: ["Kestrel", "tomorrow"], allowedNumbers: ["3", "00"]),
    ScribeTask(
      id: "sel-typos", kind: .rewrite, instruction: "correggi gli errori", category: .docs, appName: "Notes",
      selectedText: "Domani matina facciamo il punto con il clente, poi aggiorniamo la presentazzione.",
      facts: ["mattina", "cliente", "presentazione"]),
    ScribeTask(
      id: "sel-friendlier", kind: .rewrite, instruction: "make it friendlier", category: .workChat, appName: "Slack",
      selectedText: "Send me the numbers by Friday.", facts: ["numbers", "Friday"]),
    ScribeTask(
      id: "sel-list", kind: .rewrite, instruction: "trasformalo in un elenco puntato", category: .docs, appName: "Notes",
      selectedText: "Per il lancio servono tre cose: la pagina del prodotto aggiornata, il video di presentazione e l'email ai clienti.",
      facts: ["pagina", "video", "email"]),
  ]

  /// Quality flags: "executed" (carried out or answered instead of editing), "added" (numbers
  /// that weren't there), "missing" (facts lost, a changed meaning).
  func flags(for text: String) -> [String] {
    var flags: [String] = []
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    let opening = lower.prefix(40)
    let assistant = ["certo", "ecco", "sure", "here's", "here’s", "here is", "of course", "va bene", "ok,", "ok!", "come assistente", "as an ai"]
    var executed = assistant.contains { opening.hasPrefix($0) }
    switch kind {
    case .prompt:
      if !requestMarkers.contains(where: { lower.contains($0.lowercased()) }) { executed = true }
      if resultMarkers.contains(where: { lower.contains($0.lowercased()) }) { executed = true }
    case .question:
      // Still a question, and not followed by its answer.
      if !trimmed.contains("?") || trimmed.count > instruction.count * 2 { executed = true }
    case .message, .rewrite:
      break
    }
    if executed { flags.append("executed") }
    let input = instruction + " " + (selectedText ?? "")
    let known = Set(Self.numbers(input) + allowedNumbers.flatMap(Self.numbers))
    if Self.numbers(trimmed).contains(where: { !known.contains($0) }) { flags.append("added") }
    if facts.contains(where: { !lower.contains($0.lowercased()) }) { flags.append("missing") }
    return flags
  }

  static func numbers(_ text: String) -> [String] {
    text.split(whereSeparator: { !$0.isNumber }).map { String($0.drop { $0 == "0" }.isEmpty ? "0" : $0.drop { $0 == "0" }) }
  }
}
