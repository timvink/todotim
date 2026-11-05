.pragma library

// Inline Markdown for task titles and descriptions, as the Mac and Android apps show it:
// **bold**, *italic* / _italic_, `code`, ~~strike~~, [text](https://…) and bare https:// links.
// Returns Qt StyledText (an HTML subset). Everything else is escaped, so task text can never
// inject markup; only http(s) and mailto links become clickable.

function escape(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
}

function safeUrl(url) {
  return /^(https?:\/\/|mailto:)/i.test(url) ? url : ""
}

function toStyled(text, codeColor) {
  var src = String(text || "")
  // Split out code spans first so their content is not formatted.
  var parts = src.split(/(`[^`\n]+`)/)
  var out = ""
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    if (/^`[^`\n]+`$/.test(part)) {
      out += "<code><font color=\"" + codeColor + "\">" + escape(part.slice(1, -1)) + "</font></code>"
      continue
    }
    var tokens = []
    // [text](url) links: replaced by placeholders before escaping.
    part = part.replace(/\[([^\]\n]+)\]\(([^)\s]+)\)/g, function(m, label, url) {
      var safe = safeUrl(url)
      if (!safe) return m
      tokens.push("<a href=\"" + escape(safe) + "\">" + escape(label) + "</a>")
      return "{{md" + (tokens.length - 1) + "}}"
    })
    part = part.replace(/\bhttps?:\/\/[^\s<>()]+[^\s<>().,;:!?'"]/g, function(url) {
      tokens.push("<a href=\"" + escape(url) + "\">" + escape(url) + "</a>")
      return "{{md" + (tokens.length - 1) + "}}"
    })
    var s = escape(part)
    s = s.replace(/\*\*([^*\n]+)\*\*/g, "<b>$1</b>")
    s = s.replace(/__([^_\n]+)__/g, "<b>$1</b>")
    s = s.replace(/(^|[^*\w])\*([^*\s][^*\n]*?)\*(?!\w)/g, "$1<i>$2</i>")
    s = s.replace(/(^|[^_\w])_([^_\s][^_\n]*?)_(?!\w)/g, "$1<i>$2</i>")
    s = s.replace(/~~([^~\n]+)~~/g, "<s>$1</s>")
    s = s.replace(/\{\{md(\d+)\}\}/g, function(m, n) { return tokens[Number(n)] })
    out += s
  }
  return out.replace(/\n/g, "<br>")
}

function plain(text) {
  return String(text || "").replace(/\[([^\]\n]+)\]\([^)\s]+\)/g, "$1").replace(/[*_`~]{1,2}([^*_`~\n]+)[*_`~]{1,2}/g, "$1")
}
