import Foundation

enum CSV {
    // RFC 4180: quoted delimiters, escaped quotes, CRLF and embedded newlines.
    static func parse(_ text: String) throws -> [[String: String]] {
        let text = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
        let chars = Array(text)
        var lines: [[String]] = [], row: [String] = []
        var field = "", quoted = false, i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" {
                    field.append("\""); i += 1
                } else { quoted.toggle() }
            } else if c == "," && !quoted {
                row.append(field); field = ""
            } else if (c == "\n" || c == "\r") && !quoted {
                row.append(field); field = ""
                if row.contains(where: { !$0.isEmpty }) { lines.append(row) }
                row = []
            } else { field.append(c) }
            i += 1
        }
        guard !quoted else { throw PulseError.message("CSV incompleto: comillas sin cerrar.") }
        if !field.isEmpty || !row.isEmpty { row.append(field); lines.append(row) }
        guard let header = lines.first, !header.isEmpty, Set(header).count == header.count else {
            throw PulseError.message("El proveedor devolvió un encabezado CSV inválido.")
        }
        return try lines.dropFirst().map { values in
            guard values.count == header.count else {
                throw PulseError.message("El formato del proveedor cambió: columnas incompatibles.")
            }
            return Dictionary(uniqueKeysWithValues: zip(header, values))
        }
    }

    static func require(_ rows: [[String: String]], _ columns: [String], source: String) throws {
        guard let first = rows.first, columns.allSatisfy({ first[$0] != nil }) else {
            throw PulseError.message("\(source): datos vacíos o columnas inesperadas. No se reemplazó la última descarga válida.")
        }
    }
}
