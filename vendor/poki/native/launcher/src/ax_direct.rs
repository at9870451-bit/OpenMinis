//! The front app's tree asked for directly on the accessibility service, with no XCTest session and
//! no inspector focus. The service's own idea of the front app can be wrong (it names a Sleep screen
//! process left running), so the app is found the way the screen shows it: a hit test at a point,
//! then that process's application element, then one deep snapshot of it.
//! Wire schema: https://github.com/ipbtools/ipb/blob/main/docs/protocol.md
//! A hit test sends no touch, and nothing here is an accessibility action.
use super::*;

/// What each step of a direct read did, for the test log.
#[derive(Default, serde::Serialize)]
pub struct Trace {
    pub stage: &'static str,
    pub subscribe_ms: u64,
    /// One per point tried: the point, the process hit (None when nothing answered there), the time.
    pub hits: Vec<Json>,
    pub pid: Option<u64>,
    pub application_ms: Option<u64>,
    pub snapshot_ms: Option<u64>,
    pub snapshot_bytes: Option<u64>,
    pub orientation: Option<u64>,
    pub error: Option<String>,
}

pub struct Direct {
    socket: Box<dyn ReadWrite>,
    orientation: Option<u64>,
    next_id: u32,
}

const STEP: Duration = Duration::from_secs(4);

fn dictionary(entries: impl IntoIterator<Item = (&'static str, Value)>) -> Value {
    Value::Dictionary(
        entries
            .into_iter()
            .map(|(k, v)| (k.to_owned(), v))
            .collect(),
    )
}
fn add(objects: &mut Vec<Value>, value: Value) -> Value {
    let id = objects.len();
    objects.push(value);
    Value::Uid(plist::Uid::new(id as u64))
}
fn class(objects: &mut Vec<Value>, name: &str) -> Value {
    add(
        objects,
        dictionary([
            ("$classname", name.into()),
            (
                "$classes",
                Value::Array(vec![name.into(), "NSObject".into()]),
            ),
        ]),
    )
}
fn encode(objects: &mut Vec<Value>, value: Value) -> Value {
    match value {
        Value::Dictionary(values) => {
            let mut keys = Vec::new();
            let mut vals = Vec::new();
            for (key, value) in values {
                keys.push(encode(objects, key.into()));
                vals.push(encode(objects, value));
            }
            let cls = class(objects, "NSDictionary");
            add(
                objects,
                dictionary([
                    ("NS.keys", Value::Array(keys)),
                    ("NS.objects", Value::Array(vals)),
                    ("$class", cls),
                ]),
            )
        }
        Value::Array(values) => {
            let items = values.into_iter().map(|v| encode(objects, v)).collect();
            let cls = class(objects, "NSArray");
            add(
                objects,
                dictionary([("NS.objects", Value::Array(items)), ("$class", cls)]),
            )
        }
        other => add(objects, other),
    }
}
impl Direct {
    /// Subscribes, and waits a moment for the first unsolicited dump (it carries the orientation).
    pub async fn connect(adapter: &mut AdapterHandle, rsd: &RsdHandshake) -> Result<Self> {
        let port = rsd.services.get(SERVICE).ok_or("Native accessibility service is unavailable")?.port;
        let mut socket: Box<dyn ReadWrite> = Box::new(adapter.connect(port).await?);
        call(
            &mut socket,
            1,
            "_notifyOfPublishedCapabilities:",
            dictionary([("com.apple.private.DTXBlockCompression", 0.into()), ("com.apple.private.DTXConnection", 1.into())]),
            false,
        )
        .await?;
        call(&mut socket, 2, "clientNeedsAccessibility:", true.into(), true).await?;
        let mut direct = Self { socket, orientation: None, next_id: 10 };
        let _ = tokio::time::timeout(Duration::from_millis(1500), async {
            while direct.orientation.is_none() {
                let message = Message::from_reader(&mut direct.socket).await?;
                acknowledge(&mut direct.socket, &message).await?;
                if let Some(update) = response(&message)? {
                    direct.observe(&update);
                }
            }
            Ok::<(), Box<dyn std::error::Error + Send + Sync>>(())
        })
        .await;
        Ok(direct)
    }

    fn observe(&mut self, update: &Archive) {
        if update.field(update.root(), "associatedRequestType").and_then(|v| update.integer(v)) != Some(11) {
            return;
        }
        let Some(dump) = update.field(update.root(), "resultData").and_then(|v| update.field(v, "treeDump")) else { return };
        for item in update.array(dump) {
            let kind = update.field(item, "associatedRequestType").and_then(|v| update.integer(v));
            if kind == Some(2) && update.field(item, "attribute").and_then(|v| update.integer(v)) == Some(129) {
                if let Some(value) = update.field(item, "resultData").and_then(|v| update.integer(v)) {
                    self.orientation = Some(value);
                }
            }
        }
    }

    /// Sends one request and returns the answer of the same type, within `STEP`.
    async fn ask(&mut self, kind: u64, objects: Vec<Value>, request: Value) -> Result<(Archive, usize)> {
        let archive = dictionary([
            ("$version", 100000.into()),
            ("$archiver", "NSKeyedArchiver".into()),
            ("$top", dictionary([("root", request)])),
            ("$objects", Value::Array(objects)),
        ]);
        let mut bytes = Vec::new();
        archive.to_writer_binary(&mut bytes)?;
        let id = self.next_id;
        self.next_id += 1;
        call(&mut self.socket, id, "processDataFromHost:", Value::Data(bytes), true).await?;
        tokio::time::timeout(STEP, async {
            loop {
                let message = Message::from_reader(&mut self.socket).await?;
                acknowledge(&mut self.socket, &message).await?;
                let size = match message.aux.as_ref().and_then(|a| a.values.first()) {
                    Some(AuxValue::Array(bytes)) => bytes.len(),
                    _ => 0,
                };
                let Some(update) = response(&message)? else { continue };
                self.observe(&update);
                if update.field(update.root(), "associatedRequestType").and_then(|v| update.integer(v)) == Some(kind) {
                    return Ok::<_, Box<dyn std::error::Error + Send + Sync>>((update, size));
                }
            }
        })
        .await
        .map_err(|_| format!("no answer to request type {kind} in {} s", STEP.as_secs()))?
    }

    /// The process that owns what is shown at a point of the screen (in points). No touch is sent.
    pub async fn hit(&mut self, x: f64, y: f64) -> Result<Option<u64>> {
        let mut objects = vec![Value::from("$null")];
        let point_text = add(&mut objects, format!("{{{x}, {y}}}").into());
        let point_class = class(&mut objects, "NSValue");
        let point = add(&mut objects, dictionary([("NS.pointval", point_text), ("NS.special", 1.into()), ("$class", point_class)]));
        let point_key = add(&mut objects, "point".into());
        let display_key = add(&mut objects, "displayId".into());
        let display = add(&mut objects, 0.into());
        let dict_class = class(&mut objects, "NSDictionary");
        let parameters = add(
            &mut objects,
            dictionary([
                ("NS.keys", Value::Array(vec![point_key, display_key])),
                ("NS.objects", Value::Array(vec![point, display])),
                ("$class", dict_class),
            ]),
        );
        // The documented carrier of a hit test is blank, not a live element.
        let nonce = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_nanos() as u64;
        let object_id = add(&mut objects, nonce.into());
        let token_class = class(&mut objects, "AXPTranslationObject");
        let token = add(
            &mut objects,
            dictionary([
                ("objectID", object_id),
                ("pid", 0.into()),
                ("isApplicationElement", false.into()),
                ("didPopuldateAppInfo", false.into()),
                ("bridgeDelegateToken", Value::Uid(plist::Uid::new(0))),
                ("rawElementData", Value::Uid(plist::Uid::new(0))),
                ("$class", token_class),
            ]),
        );
        let cls = class(&mut objects, "AXPTranslatorRequest");
        let request = add(
            &mut objects,
            dictionary([
                ("requestType", 6.into()),
                ("attributeType", 0.into()),
                ("actionType", 0.into()),
                ("clientType", 0.into()),
                ("translation", token),
                ("parameters", parameters),
                ("$class", cls),
            ]),
        );
        let (update, _) = self.ask(6, objects, request).await?;
        Ok(update.field(update.root(), "resultData").and_then(|v| update.field(v, "pid")).and_then(|v| update.integer(v)).filter(|pid| *pid > 0))
    }

    /// The application element of a process and its deep snapshot, flattened like a tree dump.
    pub async fn tree_of(&mut self, pid: u64, trace: &mut Trace) -> Result<Json> {
        trace.stage = "application";
        let asked = std::time::Instant::now();
        let mut objects = vec![Value::from("$null")];
        let parameters = encode(&mut objects, dictionary([("pid", pid.into())]));
        let cls = class(&mut objects, "AXPTranslatorRequest");
        let request = add(
            &mut objects,
            dictionary([
                ("requestType", 1.into()),
                ("attributeType", 0.into()),
                ("actionType", 0.into()),
                ("clientType", 0.into()),
                ("translation", Value::Uid(plist::Uid::new(0))),
                ("parameters", parameters),
                ("$class", cls),
            ]),
        );
        let (update, _) = self.ask(1, objects, request).await?;
        trace.application_ms = Some(asked.elapsed().as_millis() as u64);
        let token = update.field(update.root(), "resultData").ok_or("the process has no application element")?;
        let object_id = update.field(token, "objectID").and_then(|v| update.integer(v)).ok_or("the application element has no identity")?;

        trace.stage = "snapshot";
        let asked = std::time::Instant::now();
        // The token goes back whole, with every object it refers to.
        let mut objects = update.value.as_dictionary().unwrap()["$objects"].as_array().unwrap().clone();
        let token = add(&mut objects, token.clone());
        let options = dictionary([
            ("attributes", Value::Array([2001, 2003, 2004, 5019, 2006, 3002, 3003].into_iter().map(Value::from).collect())),
            ("maxDepth", 48.into()),
            ("maxChildren", 512.into()),
            ("maxArrayCount", 512.into()),
            ("traverseFromParentsToChildren", true.into()),
            ("snapshotKeyHonorModalViews", false.into()),
        ]);
        let parameters = encode(&mut objects, dictionary([("parameter", options)]));
        let cls = class(&mut objects, "AXPTranslatorRequest");
        let request = add(
            &mut objects,
            dictionary([
                ("requestType", 2.into()),
                ("attributeType", 52.into()),
                ("actionType", 0.into()),
                ("clientType", 0.into()),
                ("translation", token),
                ("parameters", parameters),
                ("$class", cls),
            ]),
        );
        let (update, size) = self.ask(2, objects, request).await?;
        trace.snapshot_ms = Some(asked.elapsed().as_millis() as u64);
        trace.snapshot_bytes = Some(size as u64);
        let result = update.field(update.root(), "resultData").ok_or("the snapshot has no result")?;
        flatten(&update, result, pid, object_id, self.orientation.unwrap_or(1))
    }

    /// The tree of the app shown at the first of `points` that hits a process, on this connection.
    pub async fn front(&mut self, points: &[(f64, f64)], trace: &mut Trace) -> Result<Json> {
        trace.stage = "hit test";
        trace.orientation = self.orientation;
        for (x, y) in points {
            let asked = std::time::Instant::now();
            let hit = self.hit(*x, *y).await;
            let ms = asked.elapsed().as_millis() as u64;
            match hit {
                Ok(pid) => {
                    trace.hits.push(json!({"x": x, "y": y, "pid": pid, "ms": ms}));
                    if let Some(pid) = pid {
                        trace.pid = Some(pid);
                        break;
                    }
                }
                Err(error) => trace.hits.push(json!({"x": x, "y": y, "error": error.to_string(), "ms": ms})),
            }
        }
        let pid = trace.pid.ok_or("no point of the screen answered the hit test")?;
        self.tree_of(pid, trace).await
    }

    pub async fn close(&mut self) {
        let id = self.next_id;
        let _ = call(&mut self.socket, id, "clientNeedsAccessibility:", false.into(), true).await;
        let _ = self.socket.shutdown().await;
    }
}

/// The tree of the app shown at the first of `points` that hits a process.
pub async fn read_front(adapter: &mut AdapterHandle, rsd: &RsdHandshake, points: &[(f64, f64)]) -> (Option<Json>, Trace) {
    let mut trace = Trace { stage: "subscribe", ..Trace::default() };
    let asked = std::time::Instant::now();
    let mut direct = match Direct::connect(adapter, rsd).await {
        Ok(direct) => direct,
        Err(error) => {
            trace.error = Some(error.to_string());
            return (None, trace);
        }
    };
    trace.subscribe_ms = asked.elapsed().as_millis() as u64;
    trace.orientation = direct.orientation;
    let outcome = direct.front(points, &mut trace).await;
    direct.close().await;
    match outcome {
        Ok(tree) => {
            trace.stage = "done";
            (Some(tree), trace)
        }
        Err(error) => {
            trace.error = Some(error.to_string());
            (None, trace)
        }
    }
}

fn response(message: &Message) -> Result<Option<Archive>> {
    let Some(AuxValue::Array(bytes)) = message.aux.as_ref().and_then(|a| a.values.first()) else {
        return Ok(None);
    };
    let outer = Archive::parse(bytes)?;
    let Some(data) = outer.data(outer.root()) else {
        return Ok(None);
    };
    Ok(Some(Archive::parse(data)?))
}
fn attribute<'a>(a: &'a Archive, attrs: &'a Value, id: u64) -> Option<&'a Value> {
    a.entries(attrs)
        .into_iter()
        .find(|(key, _)| a.integer(key) == Some(id))
        .map(|(_, v)| v)
}
fn flatten(
    a: &Archive,
    root: &Value,
    pid: u64,
    expected_id: u64,
    orientation: u64,
) -> Result<Json> {
    let token = a
        .field(root, "UIAccessibilitySnapshotKeyElement")
        .ok_or("Direct snapshot unavailable")?;
    // Some apps answer with a root whose identity differs from the application element that was
    // asked (seen on an iPhone, iOS 27.3). The snapshot is still that process's, so its own root is
    // taken as the root.
    let expected_id = a.field(token, "objectID").and_then(|v| a.integer(v)).unwrap_or(expected_id);
    let attrs = a
        .field(root, "UIAccessibilitySnapshotKeyAttributes")
        .ok_or("No root attributes")?;
    let responder_id = attribute(a, attrs, 3002)
        .and_then(|r| a.field(r, "UIAccessibilitySnapshotKeyElement"))
        .and_then(|t| a.field(t, "objectID"))
        .and_then(|v| a.integer(v));
    let mut tree = Tree {
        roots: vec![(expected_id, Some(pid))],
        orientation: Some(orientation),
        ..Tree::default()
    };
    let mut pending = vec![(root, 0)];
    while let Some((record, depth)) = pending.pop() {
        // A very large screen is cut short, not refused: what was read so far is still the screen.
        if depth > 64 || tree.nodes.len() >= 4000 {
            continue;
        }
        let token = a
            .field(record, "UIAccessibilitySnapshotKeyElement")
            .ok_or("Missing snapshot element")?;
        let id = a
            .field(token, "objectID")
            .and_then(|v| a.integer(v))
            .ok_or("Missing element identity")?;
        let attrs = a
            .field(record, "UIAccessibilitySnapshotKeyAttributes")
            .ok_or("Missing element attributes")?;
        let children_value = a
            .field(record, "UIAccessibilitySnapshotKeyChildren")
            .ok_or("Missing snapshot children")?;
        let children = a.array(children_value);
        // The count may be larger than the children sent (a long list is cut by the phone): what came is read.
        let mut node = Node::default();
        for (number, name) in [(2001, "label"), (5019, "identifier"), (2006, "value"), (3003, "bundle_id")] {
            if let Some(value) = attribute(a, attrs, number).and_then(|v| a.string(v)) {
                node.fields.insert(name.into(), value.into());
            }
        }
        if let Some(value) = attribute(a, attrs, 2003) {
            let f = a.numbers(value);
            if f.len() == 4 {
                node.fields.insert(
                    "frame".into(),
                    json!({"x":f[0],"y":f[1],"width":f[2],"height":f[3]}),
                );
            }
        }
        if let Some(traits) = attribute(a, attrs, 2004).and_then(|v| a.integer(v)) {
            node.fields.insert("traits".into(), traits.into());
            if is_editing(traits) {
                node.fields.insert("role".into(), "TextField".into());
            }
        }
        node.fields
            .insert("focused".into(), (Some(id) == responder_id).into());
        for child in children {
            let child_id = a
                .field(child, "UIAccessibilitySnapshotKeyElement")
                .and_then(|t| a.field(t, "objectID"))
                .and_then(|v| a.integer(v))
                .ok_or("Missing child identity")?;
            node.children.push(child_id);
            pending.push((child, depth + 1));
        }
        tree.nodes.insert(id, node);
    }
    let mut json = tree.json();
    // Direct snapshot focus comes from the actual root first responder, not a trait approximation.
    for item in json["elements"].as_array_mut().unwrap() {
        item["focused"] = (item["object_id"].as_str()
            == responder_id.map(|id| format!("o{id}")).as_deref())
        .into();
    }
    json["direct"] = true.into();
    Ok(json)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn attrs(values: Vec<(u64, Value)>) -> Value {
        let (keys, values): (Vec<_>, Vec<_>) =
            values.into_iter().map(|(k, v)| (Value::from(k), v)).unzip();
        dictionary([
            ("NS.keys", Value::Array(keys)),
            ("NS.objects", Value::Array(values)),
        ])
    }
    fn record(id: u64, attributes: Value, children: Vec<Value>) -> Value {
        dictionary([
            (
                "UIAccessibilitySnapshotKeyElement",
                dictionary([("objectID", id.into()), ("pid", 42.into())]),
            ),
            ("UIAccessibilitySnapshotKeyAttributes", attributes),
            (
                "UIAccessibilitySnapshotKeyChildrenCount",
                (children.len() as u64).into(),
            ),
            ("UIAccessibilitySnapshotKeyChildren", Value::Array(children)),
        ])
    }
    fn fixture(responder: bool) -> (Archive, Value) {
        let field = record(
            u64::MAX - 1,
            attrs(vec![
                (2004, (1u64 << 21).into()),
                (2006, "你好".into()),
                (2003, "{{10, 20}, {300, 400}}".into()),
            ]),
            vec![],
        );
        let attributes = if responder {
            attrs(vec![(3002, field.clone())])
        } else {
            attrs(vec![])
        };
        let root = record(10, attributes, vec![field]);
        (
            Archive {
                value: dictionary([("$objects", Value::Array(vec!["$null".into()]))]),
            },
            root,
        )
    }
    #[test]
    fn direct_focus_requires_first_responder_not_editing_trait() {
        for responder in [false, true] {
            let (archive, root) = fixture(responder);
            let json = flatten(&archive, &root, 42, 10, 3).unwrap();
            let field = &json["elements"][1];
            assert_eq!(field["object_id"], format!("o{}", u64::MAX - 1));
            assert_eq!(field["value"], "你好");
            assert_eq!(field["focused"], responder);
        }
    }
    #[test]
    fn direct_snapshot_takes_its_own_root_and_reads_cut_lists() {
        let (archive, mut root) = fixture(true);
        // A root with another identity than the one asked for is read as it is.
        assert_eq!(flatten(&archive, &root, 42, 11, 3).unwrap()["elements"].as_array().unwrap().len(), 2);
        // A count above the children sent is a list the phone cut short: what came is read.
        root.as_dictionary_mut()
            .unwrap()
            .insert("UIAccessibilitySnapshotKeyChildrenCount".into(), 2.into());
        assert_eq!(flatten(&archive, &root, 42, 10, 3).unwrap()["elements"].as_array().unwrap().len(), 2);
    }
}
