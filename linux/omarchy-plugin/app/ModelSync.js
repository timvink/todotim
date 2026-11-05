.pragma library

// Brings a ListModel of {key, type, json} in line with `rows` (objects with a unique `key`),
// keeping elements whose key survives, so the ListView keeps its delegates, scroll position and
// animations. Changed rows get a new `json` string; delegates parse it.
function sync(model, rows) {
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]
    var json = JSON.stringify(row)
    if (i < model.count && model.get(i).key === row.key) {
      if (model.get(i).json !== json) model.set(i, { key: row.key, type: row.type, json: json })
      continue
    }
    var found = -1
    for (var j = i + 1; j < model.count; j++) {
      if (model.get(j).key === row.key) { found = j; break }
    }
    if (found >= 0) {
      model.move(found, i, 1)
      if (model.get(i).json !== json) model.set(i, { key: row.key, type: row.type, json: json })
    } else {
      model.insert(i, { key: row.key, type: row.type, json: json })
    }
  }
  if (model.count > rows.length) model.remove(rows.length, model.count - rows.length)
}
