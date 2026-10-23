use std::{collections::HashMap, time::Instant};

use mlua::{Lua, Table, Value};

use crate::{Expected, Handler, Kind, Node, deadline};

type Result<T> = mlua::Result<T>;
const MAX_NODES: usize = 512;
const MAX_DEPTH: usize = 24;
const MAX_TEXT: usize = 8 * 1024;
const MAX_SERIES: usize = 256;

fn error(message: &str) -> mlua::Error {
    mlua::Error::runtime(message)
}

fn kind(name: &str) -> Result<Kind> {
    Ok(match name {
        "column" => Kind::Column,
        "row" => Kind::Row,
        "text" => Kind::Text,
        "stat" => Kind::Stat,
        "chart" => Kind::Chart,
        "button" => Kind::Button,
        "toggle" => Kind::Toggle,
        "slider" => Kind::Slider,
        "rule" => Kind::Rule,
        _ => return Err(error("unsupported visual node kind")),
    })
}

fn properties(table: &Table, kind: Kind, tagged: bool) -> Result<()> {
    let allowed: &[&str] = match kind {
        Kind::Column | Kind::Row | Kind::Rule => &[],
        Kind::Text => &["text"],
        Kind::Stat => &["label", "value"],
        Kind::Chart => &["label", "values", "labels"],
        Kind::Button => &["label", "onClick"],
        Kind::Toggle => &["label", "value", "onChange"],
        Kind::Slider => &["label", "value", "min", "max", "onChange"],
    };
    // A table with this many keys cannot be a valid node. Bound native validation work too.
    for (count, pair) in table.pairs::<Value, Value>().enumerate() {
        if count > MAX_NODES + 8 {
            return Err(error("too many visual properties"));
        }
        let (key, _) = pair?;
        let valid = match key {
            Value::Integer(index) if matches!(kind, Kind::Column | Kind::Row) => {
                index > 0 && index as usize <= MAX_NODES
            }
            Value::String(key) => {
                let name = key.to_str()?;
                (tagged && name.as_ref() == "__kind") || allowed.contains(&name.as_ref())
            }
            _ => false,
        };
        if !valid {
            return Err(error(
                "unsupported visual property (styling is not supported)",
            ));
        }
    }
    Ok(())
}

pub(super) fn install(lua: &Lua) -> Result<()> {
    let ui = lua.create_table()?;
    for name in [
        "column", "row", "text", "stat", "chart", "button", "toggle", "slider", "rule",
    ] {
        ui.raw_set(
            name,
            lua.create_function(move |lua, value: Value| {
                let table = match value {
                    Value::String(text) if name == "text" => {
                        let table = lua.create_table()?;
                        table.raw_set("text", text)?;
                        table
                    }
                    Value::Table(table) => table,
                    _ => {
                        return Err(error(
                            "visual constructors require a property table (or a text string)",
                        ));
                    }
                };
                properties(&table, kind(name)?, false)?;
                table.raw_set("__kind", name)?;
                Ok(table)
            })?,
        )?;
    }
    ui.set_readonly(true);
    lua.globals().raw_set("ui", ui)
}

pub(super) struct Parser<'a> {
    start: Instant,
    nodes: usize,
    text_bytes: usize,
    series: usize,
    next_id: &'a mut u64,
    pub(super) handlers: HashMap<u64, Handler>,
}

impl<'a> Parser<'a> {
    pub(super) fn new(start: Instant, next_id: &'a mut u64) -> Self {
        Self {
            start,
            nodes: 0,
            text_bytes: 0,
            series: 0,
            next_id,
            handlers: HashMap::new(),
        }
    }

    fn text(&mut self, value: Value) -> Result<String> {
        let text = match value {
            Value::String(text) => {
                if text.as_bytes().len() > MAX_TEXT {
                    return Err(error("visual text exceeds 8 KiB"));
                }
                text.to_str()?.to_string()
            }
            Value::Integer(value) => value.to_string(),
            Value::Number(value) if value.is_finite() => value.to_string(),
            _ => return Err(error("expected visual text or a finite number")),
        };
        self.text_bytes += text.len();
        if self.text_bytes > MAX_TEXT {
            return Err(error("visual text exceeds 8 KiB"));
        }
        Ok(text)
    }

    fn label(&mut self, table: &Table) -> Result<String> {
        match table.raw_get::<Value>("label")? {
            Value::Nil => Ok(String::new()),
            value => self.text(value),
        }
    }

    fn handler(&mut self, table: &Table, field: &str, expected: Expected) -> Result<Option<u64>> {
        match table.raw_get::<Value>(field)? {
            Value::Nil => Ok(None),
            Value::Function(function) => {
                let id = *self.next_id;
                *self.next_id = id
                    .checked_add(1)
                    .ok_or_else(|| error("visual handler ids exhausted"))?;
                self.handlers.insert(id, Handler { function, expected });
                Ok(Some(id))
            }
            _ => Err(error("visual handler must be a function")),
        }
    }

    pub(super) fn parse(&mut self, value: Value, depth: usize) -> Result<Node> {
        deadline(self.start)?;
        self.nodes += 1;
        if depth > MAX_DEPTH {
            return Err(error("visual depth exceeds 24"));
        }
        if self.nodes > MAX_NODES {
            return Err(error("visual node count exceeds 512"));
        }
        let Value::Table(table) = value else {
            return Err(error("expected a ui node"));
        };
        // All accesses are raw: scripts cannot hide properties or invoke Lua through metatables.
        let name: Value = table.raw_get("__kind")?;
        let Value::String(name) = name else {
            return Err(error("expected a ui node kind"));
        };
        let kind = kind(&name.to_str()?)?;
        properties(&table, kind, true)?;
        let mut node = Node {
            kind,
            text: String::new(),
            children: Vec::new(),
            value: 0.0,
            min: 0.0,
            max: 1.0,
            values: Vec::new(),
            labels: Vec::new(),
            handler: None,
        };
        match kind {
            Kind::Column | Kind::Row => {
                let length = array_length(&table, MAX_NODES, true)?;
                for index in 1..=length {
                    node.children
                        .push(self.parse(table.raw_get(index)?, depth + 1)?);
                }
            }
            Kind::Text => node.text = self.text(table.raw_get("text")?)?,
            Kind::Stat => {
                let label = self.label(&table)?;
                let value = self.text(table.raw_get("value")?)?;
                if !label.is_empty() {
                    self.text_bytes += 2;
                }
                if self.text_bytes > MAX_TEXT {
                    return Err(error("visual text exceeds 8 KiB"));
                }
                node.text = if label.is_empty() {
                    value
                } else {
                    format!("{label}: {value}")
                };
            }
            Kind::Chart => {
                node.text = self.label(&table)?;
                let values = required_table(table.raw_get("values")?)?;
                let length = array_length(&values, MAX_SERIES, false)?;
                self.series += length;
                if self.series > MAX_SERIES {
                    return Err(error("visual series exceeds 256 values"));
                }
                for index in 1..=length {
                    node.values.push(number(values.raw_get(index)?)?);
                }
                match table.raw_get::<Value>("labels")? {
                    Value::Nil => {}
                    value => {
                        let labels = required_table(value)?;
                        if array_length(&labels, MAX_SERIES, false)? != length {
                            return Err(error("chart labels must match its values"));
                        }
                        for index in 1..=length {
                            let value = labels.raw_get(index)?;
                            node.labels.push(self.text(value)?);
                        }
                    }
                }
            }
            Kind::Button => {
                node.text = self.label(&table)?;
                node.handler = self.handler(&table, "onClick", Expected::Click)?;
            }
            Kind::Toggle => {
                node.text = self.label(&table)?;
                node.value = match table.raw_get::<Value>("value")? {
                    Value::Boolean(value) => {
                        if value {
                            1.0
                        } else {
                            0.0
                        }
                    }
                    _ => return Err(error("toggle value must be a boolean")),
                };
                node.handler = self.handler(&table, "onChange", Expected::Bool)?;
            }
            Kind::Slider => {
                node.text = self.label(&table)?;
                node.min = number(table.raw_get("min")?)?;
                node.max = number(table.raw_get("max")?)?;
                node.value = number(table.raw_get("value")?)?;
                if node.min > node.max || node.value < node.min || node.value > node.max {
                    return Err(error("invalid slider range or value"));
                }
                node.handler = self.handler(
                    &table,
                    "onChange",
                    Expected::Number {
                        min: node.min,
                        max: node.max,
                    },
                )?;
            }
            Kind::Rule => {}
        }
        Ok(node)
    }
}

fn required_table(value: Value) -> Result<Table> {
    if let Value::Table(table) = value {
        Ok(table)
    } else {
        Err(error("expected an array table"))
    }
}

fn number(value: Value) -> Result<f64> {
    let value = match value {
        Value::Integer(value) => value as f64,
        Value::Number(value) => value,
        _ => return Err(error("expected a finite number")),
    };
    if value.is_finite() {
        Ok(value)
    } else {
        Err(error("expected a finite number"))
    }
}

// Reject holes, map keys and oversized arrays rather than truncating at the first nil.
fn array_length(table: &Table, limit: usize, tagged: bool) -> Result<usize> {
    let length = table.raw_len();
    if length > limit {
        return Err(error("visual array exceeds its size limit"));
    }
    let mut count = 0;
    for pair in table.pairs::<Value, Value>() {
        let (key, _) = pair?;
        if tagged && matches!(&key, Value::String(key) if key.as_bytes().as_ref() == b"__kind") {
            continue;
        }
        match key {
            Value::Integer(index) if index > 0 && index as usize <= length => {}
            _ => {
                return Err(error(
                    "visual arrays must be dense, with no extra properties",
                ));
            }
        }
        count += 1;
        if count > limit {
            return Err(error("visual array exceeds its size limit"));
        }
    }
    if count != length {
        return Err(error("visual arrays must be dense"));
    }
    Ok(length)
}
