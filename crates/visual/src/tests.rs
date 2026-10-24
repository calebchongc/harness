use super::*;

fn render(body: &str) -> Result<Node, String> {
    Visual::new(&format!("return function() {body} end"))?.render()
}

#[test]
fn documented_dashboard_and_stateful_button() {
    let mut visual = Visual::new(include_str!("../examples/dashboard.luau")).unwrap();
    let first = visual.render().unwrap();
    assert_eq!(first.kind, Kind::Column);
    assert_eq!(first.children[1].children[0].text, "Iterations: 3");
    let handler = first.children[3].handler.unwrap();
    let next = visual.call(handler, Input::Click).unwrap();
    assert_eq!(next.children[1].children[0].text, "Iterations: 4");
    assert!(
        visual
            .call(handler, Input::Click)
            .unwrap_err()
            .contains("stale")
    );
    assert!(visual.call(0, Input::Click).is_err());
    assert!(visual.call(u64::MAX, Input::Click).is_err());
}

#[test]
fn toggles_and_sliders_receive_typed_values_and_preserve_state() {
    let mut visual = Visual::new(r#"
        local enabled, amount = false, 2
        return function()
            return ui.column{
                ui.toggle{label='Enabled', value=enabled, onChange=function(v) enabled=v end},
                ui.slider{label='Amount', value=amount, min=0, max=10, onChange=function(v) amount=v end}
            }
        end
    "#).unwrap();
    let first = visual.render().unwrap();
    assert_eq!(first.children[0].value, 0.0);
    let toggle = first.children[0].handler.unwrap();
    assert!(visual.call(toggle, Input::Number(3.0)).is_err());
    let second = visual.call(toggle, Input::Bool(true)).unwrap();
    assert_eq!(second.children[0].value, 1.0);
    let slider = second.children[1].handler.unwrap();
    for value in [f64::NAN, f64::INFINITY, -1.0, 11.0] {
        assert!(visual.call(slider, Input::Number(value)).is_err());
    }
    let third = visual.call(slider, Input::Number(7.5)).unwrap();
    assert_eq!(third.children[1].value, 7.5);
    assert_eq!(third.children[0].value, 1.0);
}

#[test]
fn sandbox_has_only_local_safe_capabilities() {
    check(
        r#"
        for _, name in ipairs({'io','os','debug','package','require','load','loadfile',
            'loadstring','dofile','print','warn','getfenv','setfenv','newproxy',
            'collectgarbage','coroutine','buffer'}) do
            assert(_G[name] == nil, name)
        end
        assert(math.floor(1.5) == 1)
        assert(string.upper('ok') == 'OK')
        assert(not pcall(function() math.floor = function() return 9 end end))
        assert(not pcall(function() ui.text = function() end end))
        return function() return ui.text('safe') end
    "#,
    )
    .unwrap();
    let mut first =
        Visual::new("private_value=7; return function() return ui.text{text=private_value} end")
            .unwrap();
    assert_eq!(first.render().unwrap().text, "7");
    check("assert(private_value == nil); return function() return ui.rule{} end").unwrap();
}

#[test]
fn visual_moves_between_workers() {
    fn assert_send<T: Send>() {}
    assert_send::<Visual>();
    let visual = Visual::new("return function() return ui.text('worker') end").unwrap();
    let tree = std::thread::spawn(move || {
        let mut visual = visual;
        visual.render().unwrap()
    })
    .join()
    .unwrap();
    assert_eq!(tree.text, "worker");
}

#[test]
fn setup_render_and_handler_loops_time_out() {
    let start = Instant::now();
    assert!(
        Visual::new("while true do end")
            .err()
            .unwrap()
            .contains("20 ms")
    );
    assert!(render("while true do end").unwrap_err().contains("20 ms"));
    let mut visual = Visual::new(
        r#"
        return function()
            return ui.button{label='Loop', onClick=function() while true do end end}
        end
    "#,
    )
    .unwrap();
    let handler = visual.render().unwrap().handler.unwrap();
    assert!(
        visual
            .call(handler, Input::Click)
            .unwrap_err()
            .contains("20 ms")
    );
    assert!(visual.handlers.is_empty());
    assert!(start.elapsed() < Duration::from_secs(5));
}

#[test]
fn caught_timeout_cannot_turn_into_a_successful_render() {
    let error =
        render("pcall(function() while true do end end); return ui.text('late')").unwrap_err();
    assert!(error.contains("20 ms"), "{error}");
}

#[test]
fn memory_and_source_are_bounded() {
    assert!(
        Visual::new(&" ".repeat(MAX_SOURCE_BYTES + 1))
            .err()
            .unwrap()
            .contains("64 KiB")
    );
    let error = Visual::new(
        r#"
        local huge = string.rep('x', 32 * 1024 * 1024)
        return function() return ui.text(huge) end
    "#,
    )
    .err()
    .unwrap();
    assert!(error.to_lowercase().contains("memory"), "{error}");
    let error =
        render("local huge=string.rep('x',32*1024*1024); return ui.text(huge)").unwrap_err();
    assert!(error.to_lowercase().contains("memory"), "{error}");
}

#[test]
fn invalid_kinds_properties_and_values_fail_closed() {
    for body in [
        "return {__kind='html'}",
        "return ui.webview{}",
        "return ui.text{text='x', background='red'}",
        "return ui.text{text='x', style={}}",
        "return ui.text{text='x', font='large'}",
        "return ui.chart{values={1}, color='#fff'}",
        "return ui.row{children={ui.text('x')}}",
        "return ui.column{[2]=ui.text('hole')}",
        "return ui.rule{ui.text('child')}",
        "local n=ui.text('x'); n.rawcolors={}; return n",
        "return ui.slider{value=1,min=5,max=2}",
        "return ui.toggle{value=1}",
        "return ui.button{onClick='not a function'}",
        "return ui.chart{values={1,2},labels={'only one'}}",
        "return ui.chart{values={[1]=1,[3]=3}}",
        "return ui.chart{values={1,2,extra=3}}",
        "return ui.text{}",
        "return 'not a node'",
        "return setmetatable({}, {__index=function() while true do end end})",
    ] {
        assert!(render(body).is_err(), "accepted: {body}");
    }
    for value in ["0/0", "math.huge", "-math.huge"] {
        for body in [
            format!("return ui.chart{{values={{{value}}}}}"),
            format!("return ui.slider{{min=0,max=1,value={value}}}"),
            format!("return ui.text({{text={value}}})"),
            format!("return ui.stat{{label='Bad',value={value}}}"),
        ] {
            assert!(render(&body).is_err(), "accepted: {body}");
        }
    }
    assert!(Visual::new("return ui.text('not a renderer')").is_err());
    assert!(Visual::new("not valid luau !").is_err());
}

#[test]
fn output_limits_cover_cycles_depth_nodes_text_and_series() {
    assert!(
        render("local n=ui.column{}; n[1]=n; return n")
            .unwrap_err()
            .contains("depth")
    );
    assert!(render("local n=ui.text('x'); for i=1,24 do n=ui.column{n} end; return n").is_err());
    assert!(render("local n=ui.text('x'); for i=1,23 do n=ui.column{n} end; return n").is_ok());
    assert!(render("local t={}; for i=1,512 do t[i]=ui.rule{} end; return ui.column(t)").is_err());
    assert!(render("local t={}; for i=1,511 do t[i]=ui.rule{} end; return ui.column(t)").is_ok());
    assert!(render("return ui.text(string.rep('x',8193))").is_err());
    assert!(
        render("return ui.column{ui.text(string.rep('x',4096)),ui.text(string.rep('x',4097))}")
            .is_err()
    );
    assert!(render("return ui.text(string.rep('x',8192))").is_ok());
    assert!(render("local t={}; for i=1,257 do t[i]=i end; return ui.chart{values=t}").is_err());
    assert!(render("local t={}; for i=1,256 do t[i]=i end; return ui.chart{values=t}").is_ok());
}

#[test]
fn repeated_renders_release_handlers_and_invalidate_old_ids() {
    let mut visual = Visual::new(
        r#"
        return function()
            local payload=string.rep('x',4096)
            return ui.button{onClick=function() assert(#payload==4096) end}
        end
    "#,
    )
    .unwrap();
    visual.lua.gc_collect().unwrap();
    let baseline = visual.lua.used_memory();
    let old = visual.render().unwrap().handler.unwrap();
    for _ in 0..1000 {
        visual.render().unwrap();
        assert_eq!(visual.handlers.len(), 1);
    }
    visual.lua.gc_collect().unwrap();
    assert!(visual.lua.used_memory() < baseline + 256 * 1024);
    assert!(visual.call(old, Input::Click).is_err());
}

#[test]
fn failed_render_discards_callbacks_and_check_does_not_execute_handlers() {
    check("return function() return ui.button{onClick=function() error('not run') end} end")
        .unwrap();
    let mut visual = Visual::new(
        r#"
        local broken=false
        return function()
            if broken then return ui.column{ui.button{onClick=function() end}, false} end
            return ui.button{onClick=function() broken=true end}
        end
    "#,
    )
    .unwrap();
    let handler = visual.render().unwrap().handler.unwrap();
    assert!(visual.call(handler, Input::Click).is_err());
    assert!(visual.handlers.is_empty());
    assert!(visual.call(handler, Input::Click).is_err());
}

#[test]
fn tree_serialization_is_plain_data() {
    let tree =
        render("return ui.chart{label='Trend',values={1,2,3},labels={'a','b','c'}}").unwrap();
    let value = serde_json::to_value(tree).unwrap();
    assert_eq!(value["kind"], "chart");
    assert_eq!(value["values"], serde_json::json!([1.0, 2.0, 3.0]));
}
