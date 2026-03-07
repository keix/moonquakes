const std = @import("std");

pub const TokenKind = enum {
    Identifier,
    Number,
    String,
    Keyword,
    Symbol,
    Eof,
};

pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    line: usize,
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize,
    line: usize,

    pub fn init(src: []const u8) Lexer {
        return .{
            .src = src,
            .pos = 0,
            .line = 1,
        };
    }

    pub fn nextToken(self: *Lexer) Token {
        self.skipWhitespaceAndComments();

        if (self.pos >= self.src.len) {
            return .{
                .kind = .Eof,
                .lexeme = "",
                .line = self.line,
            };
        }

        const c = self.peek();

        if (isAlpha(c) or c == '_') return self.readIdentifier();
        if (isDigit(c)) return self.readNumber();
        if (c == '.' and self.pos + 1 < self.src.len and isDigit(self.src[self.pos + 1])) {
            return self.readNumberLeadingDot();
        }
        if (c == '"' or c == '\'') return self.readString();
        if (c == '[') {
            // Check for long bracket string: [[ or [=[ or [==[ etc.
            if (self.checkLongBracketStart()) |level| {
                return self.readLongBracketString(level);
            }
        }

        return self.readSymbol();
    }

    fn peek(self: *Lexer) u8 {
        if (self.pos >= self.src.len) return 0;
        return self.src[self.pos];
    }

    fn advance(self: *Lexer) u8 {
        if (self.pos >= self.src.len) return 0;
        const c = self.src[self.pos];
        self.pos += 1;
        return c;
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const c = self.peek();

            switch (c) {
                ' ', '\t', '\x0b', '\x0c' => _ = self.advance(),
                '\n', '\r' => {
                    self.line += 1;
                    const first = self.advance();
                    if (self.pos < self.src.len) {
                        const second = self.src[self.pos];
                        if ((first == '\n' and second == '\r') or (first == '\r' and second == '\n')) {
                            self.pos += 1;
                        }
                    }
                },
                '-' => {
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '-') {
                        // Skip "--"
                        self.pos += 2;
                        // Long comments: --[[...]] / --[=[...]=] / ...
                        if (self.pos < self.src.len and self.src[self.pos] == '[') {
                            if (self.checkLongBracketStart()) |level| {
                                self.skipLongBracket(level);
                            } else {
                                self.skipLineComment();
                            }
                        } else {
                            self.skipLineComment();
                        }
                    } else {
                        break;
                    }
                },
                else => break,
            }
        }
    }

    fn skipLineComment(self: *Lexer) void {
        while (self.pos < self.src.len and self.src[self.pos] != '\n' and self.src[self.pos] != '\r') {
            _ = self.advance();
        }
    }

    /// Skip a long bracket body: [[...]] or [=[...]=] etc.
    /// Assumes self.pos points to the opening '['.
    fn skipLongBracket(self: *Lexer, level: usize) void {
        // Skip opening: [ + level * '=' + [
        self.pos += 2 + level;

        // Find matching close: ] + level * '=' + ]
        while (self.pos < self.src.len) {
            if (self.src[self.pos] == '\n' or self.src[self.pos] == '\r') {
                self.line += 1;
                const first = self.src[self.pos];
                self.pos += 1;
                if (self.pos < self.src.len) {
                    const second = self.src[self.pos];
                    if ((first == '\n' and second == '\r') or (first == '\r' and second == '\n')) {
                        self.pos += 1;
                    }
                }
                continue;
            }
            if (self.src[self.pos] != ']') {
                self.pos += 1;
                continue;
            }

            var i = self.pos + 1;
            var eq_count: usize = 0;
            while (i < self.src.len and self.src[i] == '=') {
                eq_count += 1;
                i += 1;
            }

            if (eq_count == level and i < self.src.len and self.src[i] == ']') {
                self.pos = i + 1;
                return;
            }
            self.pos += 1;
        }
    }

    fn readIdentifier(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;

        while (self.pos < self.src.len and (isAlphaNum(self.peek()) or self.peek() == '_')) {
            _ = self.advance();
        }

        const lexeme = self.src[start..self.pos];
        const kind = if (isKeyword(lexeme)) TokenKind.Keyword else TokenKind.Identifier;

        return .{
            .kind = kind,
            .lexeme = lexeme,
            .line = start_line,
        };
    }

    fn readNumber(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;

        // Check for hex prefix (0x or 0X)
        if (self.peek() == '0' and self.pos + 1 < self.src.len and
            (self.src[self.pos + 1] == 'x' or self.src[self.pos + 1] == 'X'))
        {
            _ = self.advance(); // consume '0'
            _ = self.advance(); // consume 'x' or 'X'
            // Hex integer part
            while (self.pos < self.src.len and isHexDigit(self.peek())) {
                _ = self.advance();
            }
            // Hex fractional part (e.g., 0x1.5)
            if (self.pos < self.src.len and self.peek() == '.') {
                _ = self.advance(); // consume '.'
                while (self.pos < self.src.len and isHexDigit(self.peek())) {
                    _ = self.advance();
                }
            }
            // Hex exponent part (e.g., 0x1.5p10, 0x1P-5)
            if (self.pos < self.src.len and (self.peek() == 'p' or self.peek() == 'P')) {
                _ = self.advance(); // consume 'p' or 'P'
                // Optional sign
                if (self.pos < self.src.len and (self.peek() == '+' or self.peek() == '-')) {
                    _ = self.advance();
                }
                // Exponent digits (decimal)
                while (self.pos < self.src.len and isDigit(self.peek())) {
                    _ = self.advance();
                }
            }
        } else {
            // Decimal integer part
            while (self.pos < self.src.len and isDigit(self.peek())) {
                _ = self.advance();
            }

            // Fractional part (e.g., 3.14, 3., 3.e2)
            if (self.pos < self.src.len and self.peek() == '.') {
                // Check next char to distinguish from ".." operator
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] != '.') {
                    _ = self.advance(); // consume '.'
                    while (self.pos < self.src.len and isDigit(self.peek())) {
                        _ = self.advance();
                    }
                }
            }

            // Exponent part (e.g., 1e10, 1E-5, 3.14e+2)
            if (self.pos < self.src.len and (self.peek() == 'e' or self.peek() == 'E')) {
                _ = self.advance(); // consume 'e' or 'E'
                // Optional sign
                if (self.pos < self.src.len and (self.peek() == '+' or self.peek() == '-')) {
                    _ = self.advance();
                }
                // Exponent digits
                while (self.pos < self.src.len and isDigit(self.peek())) {
                    _ = self.advance();
                }
            }
        }

        // Malformed-number capture: consume trailing identifier chars contiguous to number
        // (e.g. "1print", "0xep-p") so parser can report "malformed number".
        while (self.pos < self.src.len and (isAlphaNum(self.peek()) or self.peek() == '_')) {
            _ = self.advance();
        }

        return .{
            .kind = .Number,
            .lexeme = self.src[start..self.pos],
            .line = start_line,
        };
    }

    fn readNumberLeadingDot(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;

        _ = self.advance(); // consume '.'
        while (self.pos < self.src.len and isDigit(self.peek())) {
            _ = self.advance();
        }

        // Exponent part (e.g., .2e2, .0E-3)
        if (self.pos < self.src.len and (self.peek() == 'e' or self.peek() == 'E')) {
            _ = self.advance(); // consume 'e' or 'E'
            if (self.pos < self.src.len and (self.peek() == '+' or self.peek() == '-')) {
                _ = self.advance();
            }
            while (self.pos < self.src.len and isDigit(self.peek())) {
                _ = self.advance();
            }
        }

        return .{
            .kind = .Number,
            .lexeme = self.src[start..self.pos],
            .line = start_line,
        };
    }

    fn isHexDigit(c: u8) bool {
        return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    fn readString(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;
        const quote = self.advance(); // Get and skip opening quote (" or ')
        var skip_z_whitespace = false;

        while (self.pos < self.src.len and self.peek() != quote) {
            if (skip_z_whitespace) {
                const ch = self.peek();
                if (ch == ' ' or ch == '\t' or ch == '\x0b' or ch == '\x0c') {
                    _ = self.advance();
                    continue;
                }
                if (ch == '\n' or ch == '\r') {
                    self.line += 1;
                    const first = self.advance();
                    if (self.pos < self.src.len) {
                        const second = self.src[self.pos];
                        if ((first == '\n' and second == '\r') or (first == '\r' and second == '\n')) {
                            self.pos += 1;
                        }
                    }
                    continue;
                }
                skip_z_whitespace = false;
            }

            if (self.peek() == '\\' and self.pos + 1 < self.src.len) {
                // Skip escape sequence (backslash + next char), counting escaped line breaks.
                const next = self.src[self.pos + 1];
                _ = self.advance(); // '\'
                if (next == '\n' or next == '\r') {
                    self.line += 1;
                    _ = self.advance(); // first newline byte
                    if (self.pos < self.src.len) {
                        const second = self.src[self.pos];
                        if ((next == '\n' and second == '\r') or (next == '\r' and second == '\n')) {
                            self.pos += 1;
                        }
                    }
                } else {
                    _ = self.advance();
                    if (next == 'z') {
                        skip_z_whitespace = true;
                    }
                }
            } else {
                const ch = self.peek();
                if (ch == '\n' or ch == '\r') {
                    // Raw newlines are not allowed inside short strings.
                    // Leave newline unread so parser reports unterminated string.
                    break;
                } else {
                    _ = self.advance();
                }
            }
        }

        if (self.pos < self.src.len) {
            _ = self.advance(); // Skip closing quote
        }

        return .{
            .kind = .String,
            .lexeme = self.src[start..self.pos],
            .line = start_line,
        };
    }

    /// Check if current position starts a long bracket: [[ or [=[ or [==[ etc.
    /// Returns the level (number of '=' signs) if it's a long bracket, null otherwise.
    fn checkLongBracketStart(self: *Lexer) ?usize {
        if (self.pos >= self.src.len or self.src[self.pos] != '[') return null;

        var i = self.pos + 1;
        var level: usize = 0;

        // Count '=' signs
        while (i < self.src.len and self.src[i] == '=') {
            level += 1;
            i += 1;
        }

        // Check for closing '['
        if (i < self.src.len and self.src[i] == '[') {
            return level;
        }

        return null;
    }

    /// Read a long bracket string: [[...]] or [=[...]=] etc.
    fn readLongBracketString(self: *Lexer, level: usize) Token {
        const start = self.pos;
        const start_line = self.line;

        // Skip opening bracket: [ + level * '=' + [
        self.pos += 2 + level;

        // Find matching close bracket: ] + level * '=' + ]
        while (self.pos < self.src.len) {
            if (self.src[self.pos] == '\n' or self.src[self.pos] == '\r') {
                self.line += 1;
                const first = self.src[self.pos];
                self.pos += 1;
                if (self.pos < self.src.len) {
                    const second = self.src[self.pos];
                    if ((first == '\n' and second == '\r') or (first == '\r' and second == '\n')) {
                        self.pos += 1;
                    }
                }
            } else if (self.src[self.pos] == ']') {
                // Check for matching close bracket
                var i = self.pos + 1;
                var eq_count: usize = 0;

                while (i < self.src.len and self.src[i] == '=') {
                    eq_count += 1;
                    i += 1;
                }

                if (eq_count == level and i < self.src.len and self.src[i] == ']') {
                    // Found matching close bracket
                    self.pos = i + 1;
                    break;
                } else {
                    self.pos += 1;
                }
            } else {
                self.pos += 1;
            }
        }

        return .{
            .kind = .String,
            .lexeme = self.src[start..self.pos],
            .line = start_line,
        };
    }

    fn readSymbol(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;

        const first_char = self.advance();

        // Check for two-character operators
        if (self.pos < self.src.len) {
            const second_char = self.peek();
            switch (first_char) {
                '=' => {
                    if (second_char == '=') {
                        _ = self.advance();
                    }
                },
                '!' => {
                    if (second_char == '=') {
                        _ = self.advance();
                    }
                },
                '<' => {
                    if (second_char == '=' or second_char == '<') {
                        _ = self.advance();
                    }
                },
                '>' => {
                    if (second_char == '=' or second_char == '>') {
                        _ = self.advance();
                    }
                },
                '~' => {
                    if (second_char == '=') {
                        _ = self.advance();
                    }
                },
                '.' => {
                    if (second_char == '.') {
                        _ = self.advance();
                        // Check for three dots: ...
                        if (self.pos < self.src.len and self.peek() == '.') {
                            _ = self.advance();
                        }
                    }
                },
                '/' => {
                    if (second_char == '/') {
                        _ = self.advance();
                    }
                },
                else => {},
            }
        }

        return .{
            .kind = .Symbol,
            .lexeme = self.src[start..self.pos],
            .line = start_line,
        };
    }
};

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAlphaNum(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}

fn isKeyword(str: []const u8) bool {
    return switch (str.len) {
        2 => (str[0] == 'd' and str[1] == 'o') or
            (str[0] == 'i' and str[1] == 'f') or
            (str[0] == 'i' and str[1] == 'n') or
            (str[0] == 'o' and str[1] == 'r'),
        3 => (str[0] == 'a' and str[1] == 'n' and str[2] == 'd') or
            (str[0] == 'e' and str[1] == 'n' and str[2] == 'd') or
            (str[0] == 'f' and str[1] == 'o' and str[2] == 'r') or
            (str[0] == 'n' and str[1] == 'i' and str[2] == 'l') or
            (str[0] == 'n' and str[1] == 'o' and str[2] == 't'),
        4 => (str[0] == 'e' and str[1] == 'l' and str[2] == 's' and str[3] == 'e') or
            (str[0] == 'g' and str[1] == 'o' and str[2] == 't' and str[3] == 'o') or
            (str[0] == 't' and str[1] == 'h' and str[2] == 'e' and str[3] == 'n') or
            (str[0] == 't' and str[1] == 'r' and str[2] == 'u' and str[3] == 'e'),
        5 => (str[0] == 'b' and str[1] == 'r' and str[2] == 'e' and str[3] == 'a' and str[4] == 'k') or
            (str[0] == 'f' and str[1] == 'a' and str[2] == 'l' and str[3] == 's' and str[4] == 'e') or
            (str[0] == 'l' and str[1] == 'o' and str[2] == 'c' and str[3] == 'a' and str[4] == 'l') or
            (str[0] == 'u' and str[1] == 'n' and str[2] == 't' and str[3] == 'i' and str[4] == 'l') or
            (str[0] == 'w' and str[1] == 'h' and str[2] == 'i' and str[3] == 'l' and str[4] == 'e'),
        6 => (str[0] == 'e' and str[1] == 'l' and str[2] == 's' and str[3] == 'e' and str[4] == 'i' and str[5] == 'f') or
            (str[0] == 'r' and str[1] == 'e' and str[2] == 'p' and str[3] == 'e' and str[4] == 'a' and str[5] == 't') or
            (str[0] == 'r' and str[1] == 'e' and str[2] == 't' and str[3] == 'u' and str[4] == 'r' and str[5] == 'n'),
        8 => str[0] == 'f' and str[1] == 'u' and str[2] == 'n' and str[3] == 'c' and str[4] == 't' and str[5] == 'i' and str[6] == 'o' and str[7] == 'n',
        else => false,
    };
}

pub fn dumpAllTokens(src: []const u8) void {
    var lexer = Lexer.init(src);
    while (true) {
        const token = lexer.nextToken();
        std.debug.print("{d}: {s} ({s})\n", .{ token.line, @tagName(token.kind), token.lexeme });
        if (token.kind == .Eof) break;
    }
}
