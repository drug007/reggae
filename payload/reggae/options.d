module reggae.options;

import reggae.types;
import reggae.path: buildPath;

import std.file: thisExePath;
import std.path: absolutePath;
import std.file: exists;

enum version_ = "0.5.24+";

Options defaultOptions;

enum BuildLanguage {
    D,
    Python,
    Ruby,
    JavaScript,
    Lua,
}

enum DubArchitecture {
    x86,
    x86_64,
    x86_mscoff,
}

version(Windows) {
    enum defaultCC = "cl.exe";
    enum defaultCXX = "cl.exe";
} else {
    enum defaultCC = "gcc";
    enum defaultCXX = "g++";
}

struct Options {
    Backend backend;
    string projectPath;
    string dflags;
    string ranFromPath;
    string cCompiler;
    string cppCompiler;
    string dCompiler;
    bool help;
    bool perModule;
    bool allAtOnce;
    bool isDubProject;
    bool oldNinja;
    bool noCompilationDB;
    bool cacheBuildInfo;
    string[] args;
    string workingDir;
    bool version_;
    bool export_;
    bool verbose;
    string[] dependencies;
    string dubObjsDir;
    bool dubDepObjsInsteadOfStaticLib;
    string dubBuildType = "debug";
    string dubArchOverride;
    string dubConfig;

    string[string] userVars; //must always be the last member variable

    Options dup() @safe pure const nothrow {
        return Options(backend,
                       projectPath, dflags, ranFromPath, cCompiler, cppCompiler, dCompiler,
                       help, perModule, isDubProject, oldNinja, noCompilationDB, cacheBuildInfo);
    }

    //finished setup
    void finalize(string[] args) @safe {
        import std.process;
        import std.file: thisExePath;

        this.args = args;
        ranFromPath = thisExePath;

        if(!cCompiler)   cCompiler   = environment.get("CC", defaultCC);
        if(!cppCompiler) cppCompiler = environment.get("CXX", defaultCXX);
        if(!dCompiler)   dCompiler   = environment.get("DC", "dmd");

        isDubProject = _dubProjectFile != "";

        // if there's a dub package file, add it to the list of dependencies so the project
        // is rebuilt if it changes
        if(isDubProject) {
            dependencies ~= _dubProjectFile;
            dependencies ~= buildPath(projectPath, "dub.selections.json");
        }

        if(isDubProject && backend == Backend.tup) {
            throw new Exception("dub integration not supported with the tup backend");
        }
    }

    package string _dubProjectFile() @safe nothrow {
        foreach(fileName; ["dub.sdl", "dub.json", "package.json"]) {
            const name = buildPath(projectPath, fileName);
            if(name.exists) return name;
        }
        return "";
    }

    string reggaeFilePath() @safe const {
        import std.algorithm, std.array, std.exception, std.conv;

        auto langFiles = [dlangFile, pythonFile, rubyFile, jsFile, luaFile];
        auto foundFiles = langFiles.filter!exists.array;

        enforce(foundFiles.length < 2,
                text("Reggae builds may only use one language. Found: ",
                     foundFiles.map!(a => reggaeFileLanguage(a).to!string).join(", ")));

        if(!foundFiles.empty) return foundFiles.front;

        return buildPath(projectPath, "reggaefile.d").absolutePath;
    }

    string dlangFile() @safe const pure nothrow {
        return buildPath(projectPath, "reggaefile.d");
    }

    string pythonFile() @safe const pure nothrow {
        return buildPath(projectPath, "reggaefile.py");
    }

    string rubyFile() @safe const pure nothrow {
        return buildPath(projectPath, "reggaefile.rb");
    }

    string jsFile() @safe const pure nothrow {
        return buildPath(projectPath, "reggaefile.js");
    }

    string luaFile() @safe const pure nothrow {
        return buildPath(projectPath, "reggaefile.lua");
    }

    string toString() @safe const pure {
        import std.conv: text;
        import std.traits: isSomeString, isAssociativeArray, Unqual;

        string repr = "Options(Backend.";

        foreach(member; this.tupleof) {

            static if(isSomeString!(typeof(member)))
                repr ~= "`" ~ text(member) ~ "`, ";
            else static if(isAssociativeArray!(typeof(member)))
                {}
            else static if(is(Unqual!(typeof(member)) == DubArchitecture))
                repr ~= `DubArchitecture.` ~ text(member) ~ ", ";
            else
                repr ~= text(member, ", ");
        }

        repr ~= ")";
        return repr;
    }

    const (string)[] rerunArgs() @safe pure const {
        return args;
    }

    bool isScriptBuild() @safe const {
        import reggae.rules.common: getLanguage, Language;
        return getLanguage(reggaeFilePath) != Language.D;
    }

    BuildLanguage reggaeFileLanguage(in string fileName) @safe const {
        import std.exception;
        import std.path: extension;

        with(BuildLanguage) {
            immutable extToLang = [".d": D, ".py": Python, ".rb": Ruby, ".js": JavaScript, ".lua": Lua];
            enforce(extension(fileName) in extToLang, "Unsupported build description language in " ~ fileName);
            return extToLang[extension(fileName)];
        }
    }

    BuildLanguage reggaeFileLanguage() @safe const {
        return reggaeFileLanguage(reggaeFilePath);
    }

    string[] reggaeFileDependencies() @safe const {
        return [ranFromPath, reggaeFilePath] ~ getReggaeFileDependenciesDlang ~ dependencies;
    }

    bool isJsonBuild() @safe const {
        return reggaeFileLanguage != BuildLanguage.D;
    }

    bool earlyExit() @safe pure const nothrow {
        return help || version_;
    }

    string[] compilerVariables() @safe pure nothrow const {
        return ["CC = " ~ cCompiler, "CXX = " ~ cppCompiler, "DC = " ~ dCompiler];
    }

    string eraseProjectPath(in string str) @safe pure nothrow const {
        import std.string;
        import std.path: dirSeparator;
        return str.replace(projectPath ~ dirSeparator, "");
    }
}

Options getOptions(string[] args) {
    return getOptions(defaultOptions, args);
}

//getopt is @system
Options getOptions(Options defaultOptions, string[] args) @trusted {
    import std.getopt;
    import std.algorithm;
    import std.array;
    import std.path: buildNormalizedPath;
    import std.exception: enforce;
    import std.conv: ConvException;

    Options options = defaultOptions;

    //escape spaces so that if we try using these arguments again the shell won't complain
    auto origArgs = args.map!(a => a.canFind(" ") ? `"` ~ a ~ `"` : a).array;

    try {
        auto helpInfo = getopt(
            args,
            "backend|b", "Backend to use (ninja|make|binary|tup). Mandatory.", &options.backend,
            "dflags", "D compiler flags.", &options.dflags,
            "d", "User-defined variables (e.g. -d myvar=foo).", &options.userVars,
            "dc", "D compiler to use (default dmd).", &options.dCompiler,
            "cc", "C compiler to use (default " ~ defaultCC ~ ").", &options.cCompiler,
            "cxx", "C++ compiler to use (default " ~ defaultCXX ~ ").", &options.cppCompiler,
            "per-module", "Compile D files per module (default is per package)", &options.perModule,
            "all-at-once", "Compile D files all at once (default is per package)", &options.allAtOnce,
            "old-ninja", "Generate a Ninja build compatible with older versions of Ninja", &options.oldNinja,
            "no-comp-db", "Don't generate a JSON compilation database", &options.noCompilationDB,
            "cache-build-info", "Cache the build information for the binary backend", &options.cacheBuildInfo,
            "C", "Change directory to run in (similar to make -C and ninja -C)", &options.workingDir,
            "version", "Prints version information", &options.version_,
            "export", "Export build system - removes dependencies on reggae itself", &options.export_,
            "verbose", "Verbose output", &options.verbose,
            "dub-objs-dir", "Directory to place object files for dub dependencies", &options.dubObjsDir,
            "dub-arch", "Architecture (x86, x86_64, x86_mscoff)", &options.dubArchOverride,
            "dub-deps-objs", "Use object files instead of static library for dub dependencies", &options.dubDepObjsInsteadOfStaticLib,
            "dub-build-type", "Dub build type (debug, release, ...)", &options.dubBuildType,
            "dub-config", "Only use this dub configuration", &options.dubConfig,
        );

        if(helpInfo.helpWanted) {
            defaultGetoptPrinter("Usage: reggae -b <ninja|make|binary|tup> </path/to/project>",
                                 helpInfo.options);
            options.help = true;
        }
    } catch(ConvException ex) {
        import std.algorithm: canFind;

        if(ex.msg.canFind("Backend"))
            throw new Exception("Unsupported backend, -b must be one of: make|ninja|tup|binary");
        else if(ex.msg.canFind("DubArchitecture"))
            throw new Exception("Unsupported architecture, --dub-arch must be one of: x86|x86_64|x86_mscoff");
        else
            assert(0);
    }

    enforce(!options.perModule || !options.allAtOnce, "Cannot specify both --per-module and --all-at-once");
    enforce(options.backend != Backend.none || options.export_, "A backend must be specified with -b/--backend");

    if(options.version_) {
        import std.stdio;
        writeln("reggae v", version_);
    }

    immutable argsPath = args.length > 1 ? args[1] : ".";
    options.projectPath = argsPath.absolutePath.buildNormalizedPath;
    options.finalize(origArgs);

    if(options.workingDir == "") {
        import std.file;
        options.workingDir = getcwd.absolutePath;
    } else {
        options.workingDir = options.workingDir.absolutePath;
    }

    return options;
}


immutable hiddenDir = ".reggae";


//returns the list of files that the `reggaefile` depends on
//this will usually be empty, but won't be if the reggaefile imports other D files
string[] getReggaeFileDependenciesDlang() @trusted {
    import std.string: chomp;
    import std.stdio: File;
    import std.algorithm: splitter;
    import std.array: array;

    immutable fileName = buildPath(hiddenDir, "reggaefile.dep");
    if(!fileName.exists) return [];

    auto file = File(fileName);
    file.readln;
    return file.readln.chomp.splitter(" ").array;
}


Options withProjectPath(in Options options, in string projectPath) @safe pure nothrow {
    auto modOptions = options.dup;
    modOptions.projectPath = projectPath;
    return modOptions;
}


string banner() @safe pure nothrow {
    auto ret = "# Automatically generated by reggae version " ~ version_ ~ "\n";
    ret ~= "# Do not edit by hand\n";
    return ret;
}
