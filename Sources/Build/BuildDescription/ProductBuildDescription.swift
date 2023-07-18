//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2015-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import PackageGraph
import PackageModel
import SPMBuildCore
import TSCBasic
@_implementationOnly import DriverSupport

/// The build description for a product.
public final class ProductBuildDescription: SPMBuildCore.ProductBuildDescription {
    /// The reference to the product.
    public let package: ResolvedPackage

    /// The reference to the product.
    public let product: ResolvedProduct

    /// The tools version of the package that declared the product.  This can
    /// can be used to conditionalize semantically significant changes in how
    /// a target is built.
    public let toolsVersion: ToolsVersion

    /// The build parameters.
    public let buildParameters: BuildParameters

    /// All object files to link into this product.
    ///
    // Computed during build planning.
    public internal(set) var objects = SortedArray<AbsolutePath>()

    /// The dynamic libraries this product needs to link with.
    // Computed during build planning.
    var dylibs: [ProductBuildDescription] = []

    /// Any additional flags to be added. These flags are expected to be computed during build planning.
    var additionalFlags: [String] = []

    /// The list of targets that are going to be linked statically in this product.
    var staticTargets: [ResolvedTarget] = []

    /// The list of Swift modules that should be passed to the linker. This is required for debugging to work.
    var swiftASTs: SortedArray<AbsolutePath> = .init()

    /// Paths to the binary libraries the product depends on.
    var libraryBinaryPaths: Set<AbsolutePath> = []

    /// Paths to tools shipped in binary dependencies
    var availableTools: [String: AbsolutePath] = [:]

    /// Path to the temporary directory for this product.
    var tempsPath: AbsolutePath {
        self.buildParameters.buildPath.appending(component: self.product.name + ".product")
    }

    /// Path to the link filelist file.
    var linkFileListPath: AbsolutePath {
        self.tempsPath.appending("Objects.LinkFileList")
    }

    /// File system reference.
    private let fileSystem: FileSystem

    /// ObservabilityScope with which to emit diagnostics
    private let observabilityScope: ObservabilityScope

    /// Create a build description for a product.
    init(
        package: ResolvedPackage,
        product: ResolvedProduct,
        toolsVersion: ToolsVersion,
        buildParameters: BuildParameters,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope
    ) throws {
        guard product.type != .library(.automatic) else {
            throw InternalError("Automatic type libraries should not be described.")
        }

        self.package = package
        self.product = product
        self.toolsVersion = toolsVersion
        self.buildParameters = buildParameters
        self.fileSystem = fileSystem
        self.observabilityScope = observabilityScope
    }

    /// Strips the arguments which should *never* be passed to Swift compiler
    /// when we're linking the product.
    ///
    /// We might want to get rid of this method once Swift driver can strip the
    /// flags itself, <rdar://problem/31215562>.
    private func stripInvalidArguments(_ args: [String]) -> [String] {
        let invalidArguments: Set<String> = ["-wmo", "-whole-module-optimization"]
        return args.filter { !invalidArguments.contains($0) }
    }

    private var deadStripArguments: [String] {
        if !self.buildParameters.linkerDeadStrip {
            return []
        }

        switch self.buildParameters.configuration {
        case .debug:
            return []
        case .release:
            if self.buildParameters.triple.isDarwin() {
                return ["-Xlinker", "-dead_strip"]
            } else if self.buildParameters.triple.isWindows() {
                return ["-Xlinker", "/OPT:REF"]
            } else if self.buildParameters.triple.arch == .wasm32 {
                // FIXME: wasm-ld strips data segments referenced through __start/__stop symbols
                // during GC, and it removes Swift metadata sections like swift5_protocols
                // We should add support of SHF_GNU_RETAIN-like flag for __attribute__((retain))
                // to LLVM and wasm-ld
                // This workaround is required for not only WASI but also all WebAssembly archs
                // using wasm-ld (e.g. wasm32-unknown-unknown). So this branch is conditioned by
                // arch == .wasm32
                return []
            } else {
                return ["-Xlinker", "--gc-sections"]
            }
        }
    }

    /// The arguments to the librarian to create a static library.
    public func archiveArguments() throws -> [String] {
        let librarian = self.buildParameters.toolchain.librarianPath.pathString
        let triple = self.buildParameters.triple
        if triple.isWindows(), librarian.hasSuffix("link") || librarian.hasSuffix("link.exe") {
            return [librarian, "/LIB", "/OUT:\(binaryPath.pathString)", "@\(self.linkFileListPath.pathString)"]
        }
        if triple.isDarwin(), librarian.hasSuffix("libtool") {
            return [librarian, "-static", "-o", binaryPath.pathString, "@\(self.linkFileListPath.pathString)"]
        }
        return [librarian, "crs", binaryPath.pathString, "@\(self.linkFileListPath.pathString)"]
    }

    /// The arguments to link and create this product.
    public func linkArguments() throws -> [String] {
        var args = [buildParameters.toolchain.swiftCompilerPath.pathString]
        args += self.buildParameters.sanitizers.linkSwiftFlags()
        args += self.additionalFlags

        // Pass `-g` during a *release* build so the Swift driver emits a dSYM file for the binary.
        if self.buildParameters.configuration == .release {
            if self.buildParameters.triple.isWindows() {
                args += ["-Xlinker", "-debug"]
            } else {
                args += ["-g"]
            }
        }

        // Only add the build path to the framework search path if there are binary frameworks to link against.
        if !self.libraryBinaryPaths.isEmpty {
            args += ["-F", self.buildParameters.buildPath.pathString]
        }

        args += ["-L", self.buildParameters.buildPath.pathString]
        args += ["-o", binaryPath.pathString]
        args += ["-module-name", self.product.name.spm_mangledToC99ExtendedIdentifier()]
        args += self.dylibs.map { "-l" + $0.product.name }

        // Add arguments needed for code coverage if it is enabled.
        if self.buildParameters.enableCodeCoverage {
            args += ["-profile-coverage-mapping", "-profile-generate"]
        }

        let containsSwiftTargets = self.product.containsSwiftTargets

        let derivedProductType: ProductType
        switch self.product.type {
        case .macro:
            #if BUILD_MACROS_AS_DYLIBS
            derivedProductType = .library(.dynamic)
            #else
            derivedProductType = .executable
            #endif
        default:
            derivedProductType = self.product.type
        }

        var hasStaticStdlib = false
        switch derivedProductType {
        case .macro:
            throw InternalError("macro not supported") // should never be reached
        case .library(.automatic):
            throw InternalError("automatic library not supported")
        case .library(.static):
            // No arguments for static libraries.
            return []
        case .test:
            // Test products are bundle when using objectiveC, executable when using test entry point.
            switch self.buildParameters.testProductStyle {
            case .loadableBundle:
                args += ["-Xlinker", "-bundle"]
            case .entryPointExecutable:
                args += ["-emit-executable"]
            }
            args += self.deadStripArguments
        case .library(.dynamic):
            args += ["-emit-library"]
            if self.buildParameters.triple.isDarwin() {
                let relativePath = "@rpath/\(buildParameters.binaryRelativePath(for: self.product).pathString)"
                args += ["-Xlinker", "-install_name", "-Xlinker", relativePath]
            }
            args += self.deadStripArguments
        case .executable, .snippet:
            // Link the Swift stdlib statically, if requested.
            if self.buildParameters.shouldLinkStaticSwiftStdlib {
                if self.buildParameters.triple.isDarwin() {
                    self.observabilityScope.emit(.swiftBackDeployError)
                } else if self.buildParameters.triple.isSupportingStaticStdlib {
                    args += ["-static-stdlib"]
                    hasStaticStdlib = true
                }
            }
            args += ["-emit-executable"]
            args += self.deadStripArguments

            // If we're linking an executable whose main module is implemented in Swift,
            // we rename the `_<modulename>_main` entry point symbol to `_main` again.
            // This is because executable modules implemented in Swift are compiled with
            // a main symbol named that way to allow tests to link against it without
            // conflicts. If we're using a linker that doesn't support symbol renaming,
            // we will instead have generated a source file containing the redirect.
            // Support for linking tests against executables is conditional on the tools
            // version of the package that defines the executable product.
            let executableTarget = try product.executableTarget
            if let target = executableTarget.underlyingTarget as? SwiftTarget, self.toolsVersion >= .v5_5,
               self.buildParameters.canRenameEntrypointFunctionName, target.supportsTestableExecutablesFeature
            {
                if let flags = buildParameters.linkerFlagsForRenamingMainFunction(of: executableTarget) {
                    args += flags
                }
            }
        case .plugin:
            throw InternalError("unexpectedly asked to generate linker arguments for a plugin product")
        }

        if let resourcesPath = self.buildParameters.toolchain.swiftResourcesPath(static: hasStaticStdlib) {
            args += ["-resource-dir", resourcesPath.pathString]
        }

        // clang resources are always in lib/swift/
        if let dynamicResourcesPath = self.buildParameters.toolchain.swiftResourcesPath {
            let clangResourcesPath = dynamicResourcesPath.appending("clang")
            args += ["-Xclang-linker", "-resource-dir", "-Xclang-linker", clangResourcesPath.pathString]
        }

        // Set rpath such that dynamic libraries are looked up
        // adjacent to the product.
        if self.buildParameters.triple.isLinux() {
            args += ["-Xlinker", "-rpath=$ORIGIN"]
        } else if self.buildParameters.triple.isDarwin() {
            let rpath = self.product.type == .test ? "@loader_path/../../../" : "@loader_path"
            args += ["-Xlinker", "-rpath", "-Xlinker", rpath]
        }
        args += ["@\(self.linkFileListPath.pathString)"]

        // Embed the swift stdlib library path inside tests and executables on Darwin.
        if containsSwiftTargets {
            let useStdlibRpath: Bool
            switch self.product.type {
            case .library(let type):
                useStdlibRpath = type == .dynamic
            case .test, .executable, .snippet, .macro:
                useStdlibRpath = true
            case .plugin:
                throw InternalError("unexpectedly asked to generate linker arguments for a plugin product")
            }

            // When deploying to macOS prior to macOS 12, add an rpath to the
            // back-deployed concurrency libraries.
            if useStdlibRpath, self.buildParameters.triple.isDarwin(),
               let macOSSupportedPlatform = self.package.platforms.getDerived(for: .macOS),
               macOSSupportedPlatform.version.major < 12
            {
                let backDeployedStdlib = try buildParameters.toolchain.macosSwiftStdlib
                    .parentDirectory
                    .parentDirectory
                    .appending("swift-5.5")
                    .appending("macosx")
                args += ["-Xlinker", "-rpath", "-Xlinker", backDeployedStdlib.pathString]
            }
        }

        // Don't link runtime compatibility patch libraries if there are no
        // Swift sources in the target.
        if !containsSwiftTargets {
            args += ["-runtime-compatibility-version", "none"]
        }

        // Add the target triple from the first target in the product.
        //
        // We can just use the first target of the product because the deployment target
        // setting is the package-level right now. We might need to figure out a better
        // answer for libraries if/when we support specifying deployment target at the
        // target-level.
        args += try self.buildParameters.targetTripleArgs(for: self.product.targets[0])

        // Add arguments from declared build settings.
        args += self.buildSettingsFlags()

        // Add AST paths to make the product debuggable. This array is only populated when we're
        // building for Darwin in debug configuration.
        args += self.swiftASTs.flatMap { ["-Xlinker", "-add_ast_path", "-Xlinker", $0.pathString] }

        args += self.buildParameters.toolchain.extraFlags.swiftCompilerFlags
        // User arguments (from -Xlinker and -Xswiftc) should follow generated arguments to allow user overrides
        args += self.buildParameters.linkerFlags
        args += self.stripInvalidArguments(self.buildParameters.swiftCompilerFlags)

        // Add toolchain's libdir at the very end (even after the user -Xlinker arguments).
        //
        // This will allow linking to libraries shipped in the toolchain.
        let toolchainLibDir = try buildParameters.toolchain.toolchainLibDir
        if self.fileSystem.isDirectory(toolchainLibDir) {
            args += ["-L", toolchainLibDir.pathString]
        }

        // Library search path for the toolchain's copy of SwiftSyntax.
        #if BUILD_MACROS_AS_DYLIBS
        if product.type == .macro {
            args += try ["-L", buildParameters.toolchain.hostLibDir.pathString]
        }
        #endif

        return args
    }

    /// Writes link filelist to the filesystem.
    func writeLinkFilelist(_ fs: FileSystem) throws {
        let stream = BufferedOutputByteStream()

        for object in self.objects {
            stream <<< object.pathString.spm_shellEscaped() <<< "\n"
        }

        try fs.createDirectory(self.linkFileListPath.parentDirectory, recursive: true)
        try fs.writeFileContents(self.linkFileListPath, bytes: stream.bytes)
    }

    /// Returns the build flags from the declared build settings.
    private func buildSettingsFlags() -> [String] {
        var flags: [String] = []

        // Linked libraries.
        let libraries = OrderedSet(staticTargets.reduce([]) {
            $0 + buildParameters.createScope(for: $1).evaluate(.LINK_LIBRARIES)
        })
        flags += libraries.map { "-l" + $0 }

        // Linked frameworks.
        let frameworks = OrderedSet(staticTargets.reduce([]) {
            $0 + buildParameters.createScope(for: $1).evaluate(.LINK_FRAMEWORKS)
        })
        flags += frameworks.flatMap { ["-framework", $0] }

        // Other linker flags.
        for target in self.staticTargets {
            let scope = self.buildParameters.createScope(for: target)
            flags += scope.evaluate(.OTHER_LDFLAGS)
        }

        return flags
    }
}
