module reggae.dub.info;

import reggae.build;
import reggae.rules;
import reggae.types;
import reggae.sorting;
import reggae.options: Options;
import reggae.path: buildPath;
import std.algorithm: map, filter, find, splitter;
import std.array: array, join;
import std.range: chain;


enum TargetType {
    autodetect,
    none,
    executable,
    library,
    sourceLibrary,
    dynamicLibrary,
    staticLibrary,
    object,
}


struct DubPackage {
    string name;
    string path; /// path to the dub package
    string mainSourceFile;
    string targetFileName;
    string[] dflags;
    string[] lflags;
    string[] importPaths;
    string[] stringImportPaths;
    string[] files;
    TargetType targetType;
    string[] versions;
    string[] dependencies;
    string[] libs;
    string[] preBuildCommands;
    string[] postBuildCommands;
    string targetPath;

    string toString() @safe pure const {
        import std.string: join;
        import std.conv: to;
        import std.traits: Unqual;

        auto ret = `DubPackage(`;
        string[] lines;

        foreach(ref elt; this.tupleof) {
            static if(is(Unqual!(typeof(elt)) == TargetType))
                lines ~= `TargetType.` ~ elt.to!string;
            else static if(is(Unqual!(typeof(elt)) == string))
                lines ~= "`" ~ elt.to!string ~ "`";
            else
                lines ~= elt.to!string;
        }
        ret ~= lines.join(`, `);
        ret ~= `)`;
        return ret;
    }

    DubPackage dup() @safe pure nothrow const {
        DubPackage ret;
        foreach(i, member; this.tupleof) {
            static if(__traits(compiles, member.dup))
                ret.tupleof[i] = member.dup;
            else
                ret.tupleof[i] = member;
        }
        return ret;
    }
}

bool isStaticLibrary(in string fileName) @safe pure nothrow {
    import std.path: extension;
    version(Windows)
        return fileName.extension == ".lib";
    else
        return fileName.extension == ".a";
}

bool isObjectFile(in string fileName) @safe pure nothrow {
    import reggae.rules.common: objExt;
    import std.path: extension;
    return fileName.extension == objExt;
}

string inDubPackagePath(in string packagePath, in string filePath) @safe pure nothrow {
    import std.algorithm: startsWith;
    return filePath.startsWith("$project")
        ? buildPath(filePath)
        : buildPath(packagePath, filePath);
}

struct DubObjsDir {
    string globalDir;
    string targetDir;
}

struct DubInfo {

    import reggae.rules.dub: CompilationMode;

    DubPackage[] packages;

    DubInfo dup() @safe pure nothrow const {
        import std.algorithm: map;
        import std.array: array;
        return DubInfo(packages.map!(a => a.dup).array);
    }

    Target[] toTargets(in string[] compilerFlags = [],
                       in CompilationMode compilationMode = CompilationMode.options,
                       in DubObjsDir dubObjsDir = DubObjsDir(),
                       in size_t startingIndex = 0)
        @safe const
    {
        Target[] targets;

        foreach(i; startingIndex .. packages.length) {
            targets ~= packageIndexToTargets(i, compilerFlags, compilationMode, dubObjsDir);
        }

        return targets ~ allObjectFileSources ~ allStaticLibrarySources;
    }

    // dubPackage[i] -> Target[]
    private Target[] packageIndexToTargets(
        in size_t dubPackageIndex,
        in string[] compilerFlags = [],
        in CompilationMode compilationMode = CompilationMode.options,
        in DubObjsDir dubObjsDir = DubObjsDir())
        @safe const
    {
        import reggae.path: deabsolutePath;
        import reggae.config: options;
        import std.range: chain, only;
        import std.algorithm: filter;
        import std.array: array, replace;
        import std.functional: not;
        import std.path: baseName, dirSeparator;
        import std.string: stripRight;

        const dubPackage = packages[dubPackageIndex];
        const importPaths = allImportPaths();
        const stringImportPaths = dubPackage.allOf!(a => a.packagePaths(a.stringImportPaths))(packages);
        const isMainPackage = dubPackageIndex == 0;
        //the path must be explicit for the other packages, implicit for the "main"
        //package
        const projDir = isMainPackage ? "" : dubPackage.path;

        const sharedFlag = targetType == TargetType.dynamicLibrary ? ["-fPIC"] : [];

        // -unittest should only apply to the main package
        const(string)[] deUnitTest(in string[] flags) {
            return isMainPackage
                ? flags
                : flags.filter!(f => f != "-unittest" && f != "-main").array;
        }

        const flags = chain(dubPackage.dflags,
                            dubPackage.versions.map!(a => "-version=" ~ a),
                            options.dflags.splitter, // TODO: doesn't support quoted args with spaces
                            sharedFlag,
                            deUnitTest(compilerFlags))
            .array;

        const files = dubPackage.files
            .filter!(not!isStaticLibrary)
            .filter!(not!isObjectFile)
            .map!(a => buildPath(dubPackage.path, a))
            .array;

        auto compileFunc() {
            final switch(compilationMode) with(CompilationMode) {
                case all: return &dlangObjectFilesTogether;
                case module_: return &dlangObjectFilesPerModule;
                case package_: return &dlangObjectFilesPerPackage;
                case options: return &dlangObjectFiles;
            }
        }

        auto targetsFunc() {
            import reggae.rules.d: dlangStaticLibraryTogether;
            import reggae.config: options;

            const isStaticLibDep =
                dubPackage.targetType == TargetType.staticLibrary &&
                dubPackageIndex != 0 &&
                !options.dubDepObjsInsteadOfStaticLib;

            return isStaticLibDep
                ? &dlangStaticLibraryTogether
                : compileFunc;
        }

        auto packageTargets = targetsFunc()(files, flags, importPaths, stringImportPaths, [], projDir);

        // go through dub dependencies and adjust object file output paths
        if(!isMainPackage) {
            // optionally put the object files in dubObjsDir
            if(dubObjsDir.globalDir != "") {
                foreach(ref target; packageTargets) {
                    target.rawOutputs[0] = buildPath(dubObjsDir.globalDir,
                                                    options.projectPath.deabsolutePath,
                                                    dubObjsDir.targetDir,
                                                    target.rawOutputs[0]);
                }
            } else {
                const dubPkgRoot = buildPath(dubPackage.path).deabsolutePath.stripRight(dirSeparator);
                const shortenedRoot = buildPath("__dub__", baseName(dubPackage.path));
                foreach(ref target; packageTargets)
                    target.rawOutputs[0] = buildPath(target.rawOutputs[0]).replace(dubPkgRoot, shortenedRoot);
            }
        }

        return packageTargets;
    }

    Target[] packageNameToTargets(
        in string name,
        in string[] compilerFlags = [],
        in CompilationMode compilationMode = CompilationMode.options,
        in DubObjsDir dubObjsDir = DubObjsDir())
        @safe const
    {
        foreach(const index, const dubPackage; packages) {
            if(dubPackage.name == name)
                return packageIndexToTargets(index, compilerFlags, compilationMode, dubObjsDir);
        }

        throw new Exception("Couldn't find package '" ~ name ~ "'");
    }

    TargetName targetName() @safe const pure nothrow {
        const fileName = packages[0].targetFileName;
        return .targetName(targetType, fileName);
    }

    string targetPath(in Options options) @safe const pure {
        import std.path: relativePath;

        return options.workingDir == options.projectPath
            ? packages[0].targetPath.relativePath(options.projectPath)
            : "";
    }

    TargetType targetType() @safe const pure nothrow {
        return packages[0].targetType;
    }

    string[] mainLinkerFlags() @safe pure nothrow const {
        import std.array: join;

        const pack = packages[0];
        return (pack.targetType == TargetType.library || pack.targetType == TargetType.staticLibrary)
            ? ["-shared"]
            : [];
    }

    // template due to purity - in the 2nd build with the payload this is pure,
    // but in the 1st build to generate the reggae executable it's not.
    // See reggae.config.
    string[] linkerFlags()() const {
        import reggae.config: options;

        const allLibs = packages[0].libs;

        static string libFlag(in string lib) {
            version(Posix)
                return "-L-l" ~ lib;
            else
                return lib ~ ".lib";
        }

        return
            packages[0].libs.map!libFlag.array ~
            packages[0].lflags.dup
            ;
    }

    string[] allImportPaths() @safe nothrow const {
        import reggae.config: options;
        import std.algorithm: sorted = sort, uniq;
        import std.array: array;

        string[] paths;
        auto rng = packages.map!(a => a.packagePaths(a.importPaths));
        foreach(p; rng) paths ~= p;
        auto allPaths = paths ~ options.projectPath;
        return allPaths.sorted.uniq.array;
    }

    // must be at the very end
    private Target[] allStaticLibrarySources() @trusted /*join*/ nothrow const pure {
        import std.algorithm: filter, map;
        import std.array: array, join;

        return packages
            .map!(a => cast(string[]) a.files.filter!isStaticLibrary.array)
            .join
            .map!(a => Target(a))
            .array;
    }

    private Target[] allObjectFileSources() @trusted nothrow const pure {
        import std.algorithm.iteration: filter, map, uniq;
        import std.algorithm.sorting: sort;
        import std.array: array, join;

        string[] objectFiles =
        packages
            .map!(a => cast(string[]) a
                  .files
                  .filter!isObjectFile
                  .map!(b => inDubPackagePath(a.path, b))
                  .array
            )
            .join
            .array;
        sort(objectFiles);

        return objectFiles
            .uniq
            .map!(a => Target(a))
            .array;
    }


    // all postBuildCommands in one shell command. Empty if there are none
    string postBuildCommands() @safe pure nothrow const {
        import std.string: join;
        return packages[0].postBuildCommands.join(" && ");
    }
}


private auto packagePaths(in DubPackage dubPackage, in string[] paths) @trusted nothrow {
    return paths.map!(a => buildPath(dubPackage.path, a)).array;
}

//@trusted because of map.array
private string[] allOf(alias F)(in DubPackage pack, in DubPackage[] packages) @trusted nothrow {

    import std.range: chain, only;
    import std.array: array, front, empty;

    string[] result;

    foreach(dependency; chain(only(pack.name), pack.dependencies)) {
        auto depPack = packages.find!(a => a.name == dependency);
        if(!depPack.empty) {
            result ~= F(depPack.front).array;
        }
    }
    return result;
}


TargetName targetName(in TargetType targetType, in string fileName) @safe pure nothrow {

    import reggae.rules.common: exeExt;

    switch(targetType) with(TargetType) {
    default:
        return TargetName(fileName);

    case executable:
        return TargetName(fileName ~ exeExt);

    case library:
        version(Posix)
            return TargetName("lib" ~ fileName ~ ".a");
        else
            return TargetName(fileName ~ ".lib");

    case dynamicLibrary:
        version(Posix)
            return TargetName("lib" ~ fileName ~ ".so");
        else
            return TargetName(fileName ~ ".dll");
    }
}
