///|
#external
type ProjectFiles

///|
#external
type TextFile

///|
extern "js" fn argument_count() -> Int32 =
  #| () => process.argv.length - 2

///|
extern "js" fn argument_at(index : Int32) -> String =
  #| (index) => process.argv[index + 2]

///|
/// Locates the mini program source root and lists its files with sizes.
/// File contents are read later, on demand, by `read_text`.
extern "js" fn list_project(source_root : String) -> ProjectFiles =
  #| (sourceRoot) => {
  #|   if (typeof process.getBuiltinModule !== "function") {
  #|     return { error: "Node.js 22.3 or newer is required." };
  #|   }
  #|   const fs = process.getBuiltinModule("node:fs");
  #|   const path = process.getBuiltinModule("node:path");
  #|   const readUtf8 = (filename) => {
  #|     const bytes = fs.readFileSync(filename);
  #|     try {
  #|       return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  #|     } catch (error) {
  #|       throw new Error(`${filename} must be UTF-8 encoded.`, { cause: error });
  #|     }
  #|   };
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
  #|       const configText = readUtf8(configPath);
  #|       let config;
  #|       try {
  #|         config = JSON.parse(configText.replace(/^﻿/, ""));
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
  #|     const manifestEntry = fs.lstatSync(manifest, { throwIfNoEntry: false });
  #|     if (manifestEntry && !manifestEntry.isFile()) {
  #|       return { error: `${manifest} must be a regular file.` };
  #|     }
  #|     if (manifestEntry) {
  #|       readUtf8(manifest);
  #|     }
  #|     // Compiler plugins (TypeScript, Less, Sass) come from the project
  #|     // config next to app.json or in the project directory.
  #|     const plugins = [];
  #|     for (const dir of new Set([root, project])) {
  #|       const configPath = path.join(dir, "project.config.json");
  #|       const entry = fs.lstatSync(configPath, { throwIfNoEntry: false });
  #|       if (!entry || !entry.isFile()) continue;
  #|       let config;
  #|       try {
  #|         config = JSON.parse(readUtf8(configPath).replace(/^﻿/, ""));
  #|       } catch (error) {
  #|         continue;
  #|       }
  #|       const listed = config?.setting?.useCompilerPlugins;
  #|       if (Array.isArray(listed)) {
  #|         for (const item of listed) {
  #|           const name = typeof item === "string" ? item : item?.type;
  #|           if (typeof name === "string") plugins.push(name);
  #|         }
  #|       }
  #|       break;
  #|     }
  #|     const excludedDirectories = new Set([".git", ".hg", ".svn", "node_modules"]);
  #|     const files = [];
  #|     const directories = [""];
  #|     while (directories.length !== 0) {
  #|       const directory = directories.pop();
  #|       const entries = fs.readdirSync(path.join(root, directory), { withFileTypes: true });
  #|       entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  #|       for (const entry of entries) {
  #|         const relative = directory === "" ? entry.name : `${directory}/${entry.name}`;
  #|         if (entry.isDirectory() && !excludedDirectories.has(entry.name)) {
  #|           directories.push(relative);
  #|         } else if (entry.isFile()) {
  #|           files.push([relative, fs.statSync(path.join(root, relative)).size]);
  #|         }
  #|       }
  #|     }
  #|     files.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  #|     return { error: "", root, files, plugins };
  #|   } catch (error) {
  #|     return { error: error.message };
  #|   }
  #| }

///|
extern "js" fn plugin_count(project : ProjectFiles) -> Int32 =
  #| (project) => project.plugins.length

///|
extern "js" fn plugin_at(project : ProjectFiles, index : Int32) -> String =
  #| (project, index) => project.plugins[index]

///|
extern "js" fn project_error(project : ProjectFiles) -> String =
  #| (project) => project.error

///|
extern "js" fn project_root(project : ProjectFiles) -> String =
  #| (project) => project.root

///|
extern "js" fn file_count(project : ProjectFiles) -> Int32 =
  #| (project) => project.files.length

///|
extern "js" fn file_path_at(project : ProjectFiles, index : Int32) -> String =
  #| (project, index) => project.files[index][0]

///|
extern "js" fn file_size_at(project : ProjectFiles, index : Int32) -> Int32 =
  #| (project, index) => Math.min(project.files[index][1], 2147483647)

///|
extern "js" fn read_text(root : String, relative : String) -> TextFile =
  #| (root, relative) => {
  #|   const fs = process.getBuiltinModule("node:fs");
  #|   const path = process.getBuiltinModule("node:path");
  #|   try {
  #|     const bytes = fs.readFileSync(path.join(root, ...relative.split("/")));
  #|     return { ok: true, text: new TextDecoder("utf-8", { fatal: true }).decode(bytes) };
  #|   } catch (error) {
  #|     return { ok: false, text: "" };
  #|   }
  #| }

///|
extern "js" fn text_ok(file : TextFile) -> Bool =
  #| (file) => file.ok

///|
extern "js" fn text_value(file : TextFile) -> String =
  #| (file) => file.text

///|
extern "js" fn write_stdout(text : String) -> Unit =
  #| (text) => { process.stdout.write(text); }

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
fn main {
  let args = Array::makei(argument_count(), argument_at)
  let arguments = match parse_cli_arguments(args) {
    Ok(Help) => {
      println(usage_message())
      return
    }
    Ok(Audit(arguments)) => arguments
    Err(error) => {
      fail_cli(error + "\n" + usage_message())
      return
    }
  }
  let listing = list_project(arguments.root)
  let error = project_error(listing)
  guard error == "" else {
    fail_cli(error)
    return
  }
  let root = project_root(listing)
  let files = Array::makei(file_count(listing), fn(index) {
    (file_path_at(listing, index), file_size_at(listing, index))
  })
  let project = @audit.Project::new(files, fn(relative) {
    let file = read_text(root, relative)
    if text_ok(file) {
      Some(text_value(file))
    } else {
      None
    }
  })
  let plugins = Array::makei(plugin_count(listing), fn(index) {
    plugin_at(listing, index)
  })
  let project = project.with_compiler_plugins(plugins)
  let report = @audit.analyze(project, options=arguments.options)
  match arguments.format {
    JsonOutput => println(report.to_json().stringify(indent=2))
    TextOutput => write_stdout(report.to_text(options=arguments.options))
    SarifOutput => println(report.to_sarif().stringify(indent=2))
    DotOutput => write_stdout(report.to_dot())
  }
  let failures = report.count(Error) +
    (if arguments.strict { report.count(Warning) } else { 0 })
  if failures > 0 {
    set_exit_code(1)
  }
}
