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
        if (c == '"') return self.readString();

        return self.readSymbol();
    }

    fn peek(self: *Lexer) u8 {
        if (self.pos >= self.src.len) return 0;
        return self.src[self.pos];
    }

    fn advance(self: *Lexer) u8 {
        const c = self.peek();
        if (c != 0) self.pos += 1;
        return c;
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const c = self.peek();

            switch (c) {
                ' ', '\t', '\r' => _ = self.advance(),
                '\n' => {
                    self.line += 1;
                    _ = self.advance();
                },
                '-' => {
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '-') {
                        self.skipLineComment();
                    } else {
                        break;
                    }
                },
                else => break,
            }
        }
    }

    fn skipLineComment(self: *Lexer) void {
        while (self.pos < self.src.len and self.src[self.pos] != '\n') {
            _ = self.advance();
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

        while (self.pos < self.src.len and isDigit(self.peek())) {
            _ = self.advance();
        }

        return .{
            .kind = .Number,
            .lexeme = self.src[start..self.pos],
            .line = start_line,
        };
    }

    fn readString(self: *Lexer) Token {
        const start = self.pos;
        const start_line = self.line;

        _ = self.advance(); // Skip opening quote

        while (self.pos < self.src.len and self.peek() != '"') {
            if (self.peek() == '\n') self.line += 1;
            _ = self.advance();
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
                    if (second_char == '=') {
                        _ = self.advance();
                    }
                },
                '>' => {
                    if (second_char == '=') {
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
    const keywords = [_][]const u8{
        "and",      "break",  "do",   "else", "elseif", "end",   "false", "for",
        "function", "goto",   "if",   "in",   "local",  "nil",   "not",   "or",
        "repeat",   "return", "then", "true", "until",  "while",
    };

    for (keywords) |keyword| {
        if (std.mem.eql(u8, str, keyword)) {
            return true;
        }
    }
    return false;
}

pub fn dumpAllTokens(src: []const u8) void {
    var lexer = Lexer.init(src);
    while (true) {
        const token = lexer.nextToken();
        std.debug.print("{d}: {s} ({s})\n", .{ token.line, @tagName(token.kind), token.lexeme });
        if (token.kind == .Eof) break;
    }
}
