///|
#external
type ProjectFiles

///|
extern "js" fn argument_count() -> Int32 =
  #| () => process.argv.length - 2

///|
extern "js" fn argument_at(index : Int32) -> String =
  #| (index) => process.argv[index + 2]

///|
extern "js" fn read_project(source_root : String) -> ProjectFiles =
  #| (sourceRoot) => {
  #|   if (typeof process.getBuiltinModule !== "function") {
  #|     return { error: "Node.js 22.3 or newer is required." };
  #|   }
  #|   const fs = process.getBuiltinModule("node:fs");
  #|   const path = process.getBuiltinModule("node:path");
  #|   try {
  #|     const project = fs.realpathSync(path.resolve(sourceRoot));
  #|     let root = project;
  #|     if (!fs.lstatSync(path.join(project, "app.json"), { throwIfNoEntry: false })) {
  #|       const configPath = path.join(project, "project.config.json");
  #|       const configEntry = fs.lstatSync(configPath, { throwIfNoEntry: false });
  #|       if (!configEntry) {
  #|         throw new Error(`No app.json or project.config.json found in ${project}.`);
  #|       }
  #|       if (!configEntry.isFile()) {
  #|         throw new Error(`${configPath} must be a regular file.`);
  #|       }
  #|       const configText = fs.readFileSync(configPath, "utf8");
  #|       let config;
  #|       try {
  #|         config = JSON.parse(configText);
  #|       } catch (error) {
  #|         throw new Error(`Invalid JSON in ${configPath}: ${error.message}`);
  #|       }
  #|       const configuredRoot = config?.miniprogramRoot;
  #|       if (typeof configuredRoot !== "string" || configuredRoot.trim() === "" ||
  #|           path.win32.parse(configuredRoot).root !== "") {
  #|         throw new Error(`${configPath}: miniprogramRoot must be a non-empty relative directory.`);
  #|       }
  #|       const configuredPath = path.resolve(project, configuredRoot.replaceAll("\\", "/"));
  #|       const relativeRoot = path.relative(project, configuredPath);
  #|       if (relativeRoot === ".." || relativeRoot.startsWith(".." + path.sep) || path.isAbsolute(relativeRoot)) {
  #|         throw new Error(`${configPath}: miniprogramRoot must stay within the project directory.`);
  #|       }
  #|       for (const segment of relativeRoot ? relativeRoot.split(path.sep) : []) {
  #|         root = path.join(root, segment);
  #|         if (!fs.lstatSync(root).isDirectory()) {
  #|           throw new Error(`miniprogramRoot must use real directories: ${root}.`);
  #|         }
  #|       }
  #|     }
  #|     const manifest = path.join(root, "app.json");
  #|     if (!fs.lstatSync(manifest).isFile()) {
  #|       return { error: `${manifest} must be a regular file.` };
  #|     }
  #|     const content = fs.readFileSync(manifest, "utf8");
  #|     const excludedDirectories = new Set([".git", ".hg", ".svn", "node_modules"]);
  #|     const files = [];
  #|     const directories = [""];
  #|     while (directories.length !== 0) {
  #|       const directory = directories.pop();
  #|       for (const entry of fs.readdirSync(path.join(root, directory), { withFileTypes: true })) {
  #|         const relative = directory === "" ? entry.name : `${directory}/${entry.name}`;
  #|         if (entry.isDirectory() && !excludedDirectories.has(entry.name)) {
  #|           directories.push(relative);
  #|         } else if (entry.isFile()) {
  #|           files.push(relative);
  #|         }
  #|       }
  #|     }
  #|     return { error: "", content, files };
  #|   } catch (error) {
  #|     return { error: error.message };
  #|   }
  #| }

///|
extern "js" fn project_error(project : ProjectFiles) -> String =
  #| (project) => project.error

///|
extern "js" fn manifest_contents(project : ProjectFiles) -> String =
  #| (project) => project.content

///|
extern "js" fn file_count(project : ProjectFiles) -> Int32 =
  #| (project) => project.files.length

///|
extern "js" fn file_at(project : ProjectFiles, index : Int32) -> String =
  #| (project, index) => project.files[index]

///|
extern "js" fn print_error(message : String) -> Unit =
  #| (message) => console.error(message)

///|
extern "js" fn set_exit_code(code : Int32) -> Unit =
  #| (code) => { process.exitCode = code; }

///|
fn fail_cli(message : String) -> Unit {
  print_error(message)
  set_exit_code(2)
}

///|
fn print_text_diagnostics(diagnostics : Json) -> Unit {
  guard diagnostics is Array(items) else {
    println(diagnostics.stringify())
    return
  }
  if items.is_empty() {
    println("No issues found.")
  }
  for item in items {
    if item is Object(fields) &&
      fields.get("code") is Some(String(code)) &&
      fields.get("location") is Some(String(location)) &&
      fields.get("detail") is Some(String(detail)) {
      println("[\{code}] \{location}: \{detail}")
    } else {
      println(item.stringify())
    }
  }
}

///|
fn main {
  let args = Array::makei(argument_count(), argument_at)
  let (source_root, format) = match parse_cli_arguments(args) {
    Ok(Help) => {
      println(usage_message())
      return
    }
    Ok(Audit(root, format)) => (root, format)
    Err(error) => {
      fail_cli(error + "\n" + usage_message())
      return
    }
  }
  let project = read_project(source_root)
  let error = project_error(project)
  guard error == "" else {
    fail_cli(error)
    return
  }
  let files = Array::makei(file_count(project), fn(index) {
    file_at(project, index)
  })
  let diagnostics = @audit.audit_manifest(manifest_contents(project), files)
  match format {
    JsonOutput => println(diagnostics.stringify())
    TextOutput => print_text_diagnostics(diagnostics)
  }
  match diagnostics {
    Array(items) if items.length() > 0 => set_exit_code(1)
    _ => ()
  }
}
