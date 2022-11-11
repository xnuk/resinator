//! Expects to be run after the C preprocessor and after `removeComments`.
//! This means that the lexer assumes that:
//! - Splices (\ at the end of a line) have been handled/collapsed.
//! - Preprocessor directives and macros have been expanded (any remaing should be skipped with the exception of `#pragma code_page`).
//! - All comments have been removed.

const std = @import("std");
const Resource = @import("rc.zig").Resource;
const isValidNumberDataLiteral = @import("literals.zig").isValidNumberDataLiteral;

const dumpTokensDuringTests = true;

pub const Token = struct {
    id: Id,
    start: usize,
    end: usize,
    line_number: usize,

    pub const Id = enum {
        literal,
        number,
        quoted_ascii_string,
        quoted_wide_string,
        operator,
        open_brace,
        close_brace,
        comma,
        open_paren,
        close_paren,
        invalid,
        eof,
    };

    pub fn slice(self: Token, buffer: []const u8) []const u8 {
        return buffer[self.start..self.end];
    }
};

pub const LexError = error{
    UnfinishedStringLiteral,
    UnfinishedComment,
};

pub const Lexer = struct {
    const Self = @This();

    buffer: []const u8,
    index: usize,
    line_number: usize = 1,
    at_start_of_line: bool = true,
    state_modifier: StateModifier = .none,
    resource_type_seen: ?Resource = null,

    pub const Error = LexError;

    pub fn init(buffer: []const u8) Self {
        return Self{
            .buffer = buffer,
            .index = 0,
        };
    }

    pub fn dump(self: *Self, token: *const Token) void {
        std.debug.print("{s}:{d}: {s}\n", .{ @tagName(token.id), token.line_number, std.fmt.fmtSliceEscapeLower(token.slice(self.buffer)) });
    }

    const StateModifier = enum {
        none,
        seen_id,
        seen_type,
        scope_data,
        language,
    };

    const StateWhitespaceDelimiterOnly = enum {
        start,
        literal,
        preprocessor,
    };

    pub fn nextWhitespaceDelimeterOnly(self: *Self) LexError!Token {
        const start_index = self.index;
        var result = Token{
            .id = .eof,
            .start = start_index,
            .end = undefined,
            .line_number = self.line_number,
        };
        var state = StateWhitespaceDelimiterOnly.start;

        var last_line_ending_index: ?usize = null;
        while (self.index < self.buffer.len) : (self.index += 1) {
            const c = self.buffer[self.index];
            switch (state) {
                .start => switch (c) {
                    '\r', '\n' => {
                        result.start = self.index + 1;
                        result.line_number = self.incrementLineNumber(&last_line_ending_index);
                    },
                    // space, tab, vertical tab, form feed
                    ' ', '\t', '\x0b', '\x0c' => {
                        result.start = self.index + 1;
                    },
                    '#' => {
                        if (self.at_start_of_line) {
                            state = .preprocessor;
                        } else {
                            state = .literal;
                        }
                        self.at_start_of_line = false;
                    },
                    else => {
                        state = .literal;
                        self.at_start_of_line = false;
                    },
                },
                .literal => switch (c) {
                    '\r', '\n', ' ', '\t', '\x0b', '\x0c' => {
                        result.id = .literal;
                        break;
                    },
                    else => {},
                },
                .preprocessor => switch (c) {
                    '\r', '\n' => {
                        result.start = self.index + 1;
                        state = .start;
                        result.line_number = self.incrementLineNumber(&last_line_ending_index);
                    },
                    else => {},
                },
            }
        } else { // got EOF
            switch (state) {
                .start => {},
                .literal => {
                    result.id = .literal;
                },
                .preprocessor => {
                    result.start = self.index;
                },
            }
        }

        result.end = self.index;
        return result;
    }

    const StateNormal = enum {
        start,
        literal_or_quoted_wide_string,
        quoted_ascii_string,
        quoted_wide_string,
        quoted_ascii_string_maybe_end,
        quoted_wide_string_maybe_end,
        literal,
        number_literal,
        preprocessor,
    };

    /// TODO: A not-terrible name
    pub fn nextNormal(self: *Self) LexError!Token {
        return self.nextNormalWithContext(.any);
    }

    pub fn nextNormalWithContext(self: *Self, context: enum { expect_operator, any }) LexError!Token {
        const start_index = self.index;
        var result = Token{
            .id = .eof,
            .start = start_index,
            .end = undefined,
            .line_number = self.line_number,
        };
        var state = StateNormal.start;

        var last_line_ending_index: ?usize = null;
        while (self.index < self.buffer.len) : (self.index += 1) {
            const c = self.buffer[self.index];
            switch (state) {
                .start => switch (c) {
                    '\r', '\n' => {
                        result.start = self.index + 1;
                        result.line_number = self.incrementLineNumber(&last_line_ending_index);
                    },
                    // space, tab, vertical tab, form feed
                    ' ', '\t', '\x0b', '\x0c' => {
                        result.start = self.index + 1;
                    },
                    'L', 'l' => {
                        state = .literal_or_quoted_wide_string;
                        self.at_start_of_line = false;
                    },
                    '"' => {
                        state = .quoted_ascii_string;
                        self.at_start_of_line = false;
                    },
                    '+', '&', '|' => {
                        self.index += 1;
                        result.id = .operator;
                        self.at_start_of_line = false;
                        break;
                    },
                    '-' => {
                        if (context == .expect_operator) {
                            self.index += 1;
                            result.id = .operator;
                            self.at_start_of_line = false;
                            break;
                        } else {
                            state = .number_literal;
                            self.at_start_of_line = false;
                        }
                    },
                    '0'...'9', '~' => {
                        state = .number_literal;
                        self.at_start_of_line = false;
                    },
                    '#' => {
                        if (self.at_start_of_line) {
                            state = .preprocessor;
                        } else {
                            state = .literal;
                        }
                        self.at_start_of_line = false;
                    },
                    '{', '}' => {
                        self.index += 1;
                        result.id = if (c == '{') .open_brace else .close_brace;
                        self.at_start_of_line = false;
                        break;
                    },
                    '(', ')' => {
                        self.index += 1;
                        result.id = if (c == '(') .open_paren else .close_paren;
                        self.at_start_of_line = false;
                        break;
                    },
                    ',' => {
                        self.index += 1;
                        result.id = .comma;
                        self.at_start_of_line = false;
                        break;
                    },
                    else => {
                        state = .literal;
                        self.at_start_of_line = false;
                    },
                },
                .preprocessor => switch (c) {
                    '\r', '\n' => {
                        result.start = self.index + 1;
                        state = .start;
                        result.line_number = self.incrementLineNumber(&last_line_ending_index);
                    },
                    else => {},
                },
                .number_literal => switch (c) {
                    ' ', '\t', '\x0b', '\x0c', '\r', '\n', '"', ',', '{', '}', '+', '-', '|', '&', '~', '(', ')' => {
                        result.id = .number;
                        break;
                    },
                    else => {},
                },
                .literal_or_quoted_wide_string => switch (c) {
                    ' ', '\t', '\x0b', '\x0c', '\r', '\n', ',', '{', '}' => {
                        result.id = .literal;
                        break;
                    },
                    '"' => {
                        state = .quoted_wide_string;
                    },
                    else => {
                        state = .literal;
                    },
                },
                .literal => switch (c) {
                    // space, tab, vertical tab, form feed, carriage return, new line, double quotes
                    ' ', '\t', '\x0b', '\x0c', '\r', '\n', '"', ',', '{', '}' => {
                        result.id = .literal;
                        break;
                    },
                    else => {},
                },
                .quoted_ascii_string, .quoted_wide_string => switch (c) {
                    '"' => {
                        state = if (state == .quoted_ascii_string) .quoted_ascii_string_maybe_end else .quoted_wide_string_maybe_end;
                    },
                    else => {},
                },
                .quoted_ascii_string_maybe_end, .quoted_wide_string_maybe_end => switch (c) {
                    '"' => {
                        state = if (state == .quoted_ascii_string_maybe_end) .quoted_ascii_string else .quoted_wide_string;
                    },
                    else => {
                        result.id = if (state == .quoted_ascii_string_maybe_end) .quoted_ascii_string else .quoted_wide_string;
                        break;
                    },
                },
            }
        } else { // got EOF
            switch (state) {
                .start => {},
                .literal_or_quoted_wide_string, .literal => {
                    result.id = .literal;
                },
                .preprocessor => {
                    result.start = self.index;
                },
                .number_literal => {
                    result.id = .number;
                },
                .quoted_ascii_string_maybe_end, .quoted_wide_string_maybe_end => {
                    result.id = if (state == .quoted_ascii_string_maybe_end) .quoted_ascii_string else .quoted_wide_string;
                },
                .quoted_ascii_string,
                .quoted_wide_string,
                => return LexError.UnfinishedStringLiteral,
            }
        }

        result.end = self.index;
        return result;
    }

    const StateNumberExpression = enum {
        start,
        invalid,
        number_literal,
    };

    /// Like incrementLineNumber but checks that the current char is a line ending first
    fn maybeIncrementLineNumber(self: *Self, last_line_ending_index: *?usize) usize {
        const c = self.buffer[self.index];
        if (c == '\r' or c == '\n') {
            return self.incrementLineNumber(last_line_ending_index);
        }
        return self.line_number;
    }

    /// Increments line_number appropriately (handling line ending pairs)
    /// and returns the new line number.
    /// note: mutates last_line_ending_index.*
    fn incrementLineNumber(self: *Self, last_line_ending_index: *?usize) usize {
        if (self.currentIndexFormsLineEndingPair(last_line_ending_index.*)) {
            last_line_ending_index.* = null;
        } else {
            self.line_number += 1;
            last_line_ending_index.* = self.index;
        }
        self.at_start_of_line = true;
        return self.line_number;
    }

    /// \r\n and \n\r pairs are treated as a single line ending (but not \r\r \n\n)
    /// expects self.index and last_line_ending_index (if non-null) to contain line endings
    fn currentIndexFormsLineEndingPair(self: *Self, last_line_ending_index: ?usize) bool {
        if (last_line_ending_index == null) return false;

        // must immediately precede the current index
        if (last_line_ending_index.? != self.index - 1) return false;

        const cur_line_ending = self.buffer[self.index];
        const last_line_ending = self.buffer[last_line_ending_index.?];

        // sanity check
        std.debug.assert(cur_line_ending == '\r' or cur_line_ending == '\n');
        std.debug.assert(last_line_ending == '\r' or last_line_ending == '\n');

        // can't be \n\n or \r\r
        if (last_line_ending == cur_line_ending) return false;

        return true;
    }
};

const common_resource_attributes_set = std.ComptimeStringMap(void, .{
    .{"PRELOAD"},
    .{"LOADONCALL"},
    .{"FIXED"},
    .{"MOVEABLE"},
    .{"DISCARDABLE"},
    .{"PURE"},
    .{"IMPURE"},
    .{"SHARED"},
    .{"NONSHARED"},
});

fn testLexNormal(source: []const u8, expected_tokens: []const Token.Id) !void {
    var lexer = Lexer.init(source);
    if (dumpTokensDuringTests) std.debug.print("\n----------------------\n{s}\n----------------------\n", .{lexer.buffer});
    for (expected_tokens) |expected_token_id| {
        const token = try lexer.nextNormal();
        if (dumpTokensDuringTests) lexer.dump(&token);
        try std.testing.expectEqual(expected_token_id, token.id);
    }
    const last_token = try lexer.nextNormal();
    try std.testing.expectEqual(Token.Id.eof, last_token.id);
}

fn expectLexError(expected: LexError, actual: anytype) !void {
    try std.testing.expectError(expected, actual);
    if (dumpTokensDuringTests) std.debug.print("{!}\n", .{actual});
}

test "normal: numbers" {
    try testLexNormal("1", &.{.number});
    try testLexNormal("-1", &.{.number});
    try testLexNormal("- 1", &.{ .number, .number });
    try testLexNormal("-a", &.{.number});
}

test "normal: string literals" {
    try testLexNormal("\"\"", &.{.quoted_ascii_string});
    // "" is an escaped "
    try testLexNormal("\" \"\" \"", &.{.quoted_ascii_string});
}
