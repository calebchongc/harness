//! Bounded, stateful Luau descriptions of native UI. See the crate README for the DSL.
//! [`check`] validates setup and the first render, not every handler.

mod nodes;

use std::{
    collections::HashMap,
    time::{Duration, Instant},
};

use mlua::{Function, Lua, LuaOptions, StdLib, Value, VmState, chunk::ChunkMode};
use serde::{Deserialize, Serialize};

pub const MAX_SOURCE_BYTES: usize = 64 * 1024;
const MAX_MEMORY_BYTES: usize = 16 * 1024 * 1024;
const CALL_BUDGET: Duration = Duration::from_millis(20);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Column,
    Row,
    Text,
    Stat,
    Chart,
    Button,
    Toggle,
    Slider,
    Rule,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Node {
    pub kind: Kind,
    pub text: String,
    pub children: Vec<Node>,
    pub value: f64,
    pub min: f64,
    pub max: f64,
    pub values: Vec<f64>,
    pub labels: Vec<String>,
    pub handler: Option<u64>,
}

#[derive(Clone, Debug)]
pub enum Input {
    Click,
    Number(f64),
    Bool(bool),
}

#[derive(Clone, Copy)]
enum Expected {
    Click,
    Bool,
    Number { min: f64, max: f64 },
}

struct Handler {
    function: Function,
    expected: Expected,
}

/// A single isolated visual. `mlua`'s `send` feature makes this movable between workers.
/// It does not run on the UI thread or access the filesystem, network, or other visuals.
pub struct Visual {
    lua: Lua,
    renderer: Function,
    handlers: HashMap<u64, Handler>,
    next_id: u64,
}

impl Visual {
    pub fn new(script: &str) -> Result<Self, String> {
        if script.len() > MAX_SOURCE_BYTES {
            return Err("visual source exceeds 64 KiB".into());
        }
        let setup = || -> mlua::Result<Self> {
            let lua = Lua::new_with(
                StdLib::TABLE | StdLib::STRING | StdLib::MATH | StdLib::UTF8,
                LuaOptions::default(),
            )?;
            lua.set_memory_limit(MAX_MEMORY_BYTES)?;
            // Base functions otherwise include output, environment mutation and code loading.
            // Keep pcall/xpcall: the interrupt stays expired even if script code catches it.
            for name in [
                "print",
                "warn",
                "require",
                "load",
                "loadstring",
                "loadfile",
                "dofile",
                "collectgarbage",
                "getfenv",
                "setfenv",
                "newproxy",
            ] {
                lua.globals().raw_set(name, Value::Nil)?;
            }
            nodes::install(&lua)?;
            lua.sandbox(true)?;
            let start = Instant::now();
            arm(&lua, start);
            let result = lua
                .load(script)
                .set_name("visual")
                .set_mode(ChunkMode::Text)
                .eval::<Function>();
            lua.remove_interrupt();
            deadline(start)?;
            let renderer = result?;
            Ok(Self {
                lua,
                renderer,
                handlers: HashMap::new(),
                next_id: 1,
            })
        };
        setup().map_err(|error| error.to_string())
    }

    pub fn render(&mut self) -> Result<Node, String> {
        self.execute(None)
    }

    pub fn call(&mut self, handler: u64, input: Input) -> Result<Node, String> {
        let entry = self
            .handlers
            .get(&handler)
            .ok_or_else(|| "unknown or stale visual handler".to_string())?;
        let valid = match (entry.expected, &input) {
            (Expected::Click, Input::Click) | (Expected::Bool, Input::Bool(_)) => true,
            (Expected::Number { min, max }, Input::Number(value)) => {
                value.is_finite() && *value >= min && *value <= max
            }
            _ => false,
        };
        if !valid {
            return Err("visual handler input has the wrong type or is outside its range".into());
        }
        let function = entry.function.clone();
        self.execute(Some((function, input)))
    }

    fn execute(&mut self, event: Option<(Function, Input)>) -> Result<Node, String> {
        // Invalidate even on failure: a UI must never retain callbacks for a failed render.
        self.handlers.clear();
        let start = Instant::now();
        arm(&self.lua, start);
        let result = (|| {
            if let Some((function, input)) = event {
                match input {
                    Input::Click => function.call::<()>(())?,
                    Input::Bool(value) => function.call::<()>(value)?,
                    Input::Number(value) => function.call::<()>(value)?,
                }
                deadline(start)?;
            }
            let value = self.renderer.call::<Value>(())?;
            deadline(start)?;
            let mut parser = nodes::Parser::new(start, &mut self.next_id);
            let node = parser.parse(value, 1)?;
            deadline(start)?;
            self.handlers = parser.handlers;
            Ok(node)
        })();
        self.lua.remove_interrupt();
        result.map_err(|error: mlua::Error| error.to_string())
    }
}

/// Validate setup and the first rendered tree. This does not execute event handlers.
pub fn check(script: &str) -> Result<(), String> {
    Visual::new(script)?.render().map(|_| ())
}

fn arm(lua: &Lua, start: Instant) {
    lua.set_interrupt(move |_| {
        deadline(start)?;
        Ok(VmState::Continue)
    });
}

fn deadline(start: Instant) -> mlua::Result<()> {
    if start.elapsed() >= CALL_BUDGET {
        Err(mlua::Error::runtime("visual execution exceeded 20 ms"))
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests;
