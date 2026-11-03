//! stator-ts as a Zig module, for compilers built on its parser and checker.
pub const api = @import("api.zig");
pub const ast = @import("ast.zig");
pub const binder = @import("binder.zig");
pub const decls = @import("decls.zig");
pub const expr = @import("expr.zig");
pub const pool = @import("pool.zig");
pub const project = @import("project.zig");
pub const session = @import("session.zig");
pub const syntax = @import("syntax.zig");
pub const types = @import("types.zig");

pub const Session = session.Session;
pub const Sym = api.Sym;
