/**
 * Copyright: Copyright (c) 2010-2011 Jacob Carlborg. All rights reserved.
 * Authors: Jacob Carlborg
 * Version: Initial created: Nov 8, 2010
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
 */
module dvm.commands.Install;

import tango.core.Exception;
import tango.io.Stdout;
import tango.io.device.File;
import tango.net.http.HttpGet;
import tango.sys.Common;
import tango.sys.Environment;
import tango.sys.Process;
import tango.sys.win32.Types;
import tango.text.convert.Format : format = Format;
import tango.text.Util;
import tango.util.compress.Zip : extractArchive;

import dvm.commands.Command;
import dvm.commands.DvmInstall;
import dvm.commands.Fetch;
import dvm.commands.Use;
import dvm.core._;
import dvm.dvm.Wrapper;
import dvm.dvm._;
import Path = dvm.io.Path;
import dvm.util.Util;
import dvm.util.Version;

class Install : Fetch
{	
	private
	{
		string archivePath;
		string tmpCompilerPath;
		string installPath_;
		Wrapper wrapper;
		
		static if (darwin)
			const platform = "osx";
		
		else static if (freebsd)
			const platform = "freebsd";
		
		else static if (linux)
			const platform = "linux";
		
		else static if (Windows)
			const platform = "windows";
	}
	
	this ()
	{
		super("install", "Install one or many D versions.");
	}
	
	void execute ()
	{
		if (args.first == "dvm") // special case for the installation of dvm itself
		{
			(new DvmInstall).invoke(args);
			return;
		}
		
		install;
	}
	
private:
	
	void install ()
	{
		auto filename = buildFilename;
		auto url = buildUrl(filename);
		
		archivePath = Path.join(options.path.archives, filename);
		
		fetch(url, archivePath);		
		println("Installing: dmd-", args.first);

		unpack;
		moveFiles;
		installWrapper;
		version (Posix) setPermissions;
		installEnvironment(createEnvironment);
		patchDmdConf;
		
		if (options.tango)
			installTango;

		registerCompiler;
	}
	
	void unpack ()
	{
		tmpCompilerPath = Path.join(options.path.tmp, "dmd-" ~ args.first);
		verbose("Unpacking:");
		verbose(options.indentation, "source: ", archivePath);
		verbose(options.indentation, "destination: ", tmpCompilerPath, '\n');
		extractArchive(archivePath, tmpCompilerPath);
	}
	
	void moveFiles ()
	{
		auto dmd = args.first.length > 0 && args.first[0] == '2' ? "dmd2" : "dmd";
		auto root = Path.join(tmpCompilerPath, dmd);
		auto platformRoot = Path.join(root, platform);
		
		if (!Path.exists(platformRoot))
			throw new DvmException(format(`The platform "{}" is not compatible with the compiler dmd {}`, platform, args.first), __FILE__, __LINE__);
		
		auto binSource = getBinSource(platformRoot);
		auto binDest = Path.join(installPath, options.path.bin);		
	 
		auto libSource = getLibSource(platformRoot);
		auto libDest = Path.join(installPath, options.path.lib);

		auto srcSource = Path.join(root, options.path.src);
		auto srcDest = Path.join(installPath, options.path.src);

		verbose("Moving:");
		
		move(binSource, binDest);
		move(libSource, libDest);
		move(srcSource, srcDest);
	}

	void installWrapper ()
	{
		wrapper.target = Path.join(installPath, options.path.bin, "dmd"~options.path.executableExtension);
		wrapper.path = Path.join(options.path.dvm, options.path.bin, "dmd-") ~ args.first;
		version (Windows)
			wrapper.path ~= ".bat";
		
		verbose("Installing wrapper: " ~ wrapper.path);
		wrapper.write;
	}
	
	void setPermissions ()
	{
		verbose("Setting permissions:");
		
		permission(Path.join(installPath, options.path.bin, "dmd"), "+x");
		permission(Path.join(installPath, options.path.bin, "dumpobj"), "+x");
		permission(Path.join(installPath, options.path.bin, "obj2asm"), "+x");

		auto rdmdPath = Path.join(installPath, options.path.bin, "rdmd");

		if (Path.exists(rdmdPath))
	        permission(rdmdPath, "+x");

		permission(wrapper.path, "+x");
	}
	
	void installEnvironment (ShellScript sh)
	{
		sh.path = options.path.env;
		Path.createPath(sh.path);
		sh.path = Path.join(sh.path, "dmd-" ~ args.first ~ options.path.scriptExtension);
		
		verbose("Installing environment: ", sh.path);
		sh.write;
	}
	
	ShellScript createEnvironment ()
	{		
		auto sh = new ShellScript;
		sh.echoOff;
		
		auto envPath = Path.join(installPath, options.path.bin);
		auto binPath = Path.join(options.path.dvm, options.path.bin);
		
		version (Posix)
			sh.exportPath("PATH", envPath, binPath, Sh.variable("PATH", false));
		
		version (Windows)
		{
			Path.native(envPath);
			Path.native(binPath);
			sh.exportPath("DVM",  envPath, binPath).nl;
			sh.exportPath("PATH", envPath, Sh.variable("PATH", false));
		}
		
		return sh;
	}
	
	void patchDmdConf (bool tango = false)
	{
		auto dmdConfPath = Path.join(installPath, options.path.conf);
		
		verbose("Patching: ", dmdConfPath);
		
		auto src = tango ? "-I%@P%/../import -defaultlib=tango -debuglib=tango -version=Tango" : "-I%@P%/../src/phobos";
		auto content = cast(string) File.get(dmdConfPath);
		
		content = content.slashSafeSubstitute("-I%@P%/../../src/phobos", src);
		content = content.slashSafeSubstitute("-I%@P%/../../src/druntime/import", "-I%@P%/../src/druntime/import");
		content = content.slashSafeSubstitute("-L-L%@P%/../lib32", "-L-L%@P%/../lib");
		
		File.set(dmdConfPath, content);
	}
	
	void installTango ()
	{
		verbose("Installing Tango");

		fetchTango;
		unpackTango;
		setupTangoEnvironment;
		buildTango;
		moveTangoFiles;
		patchDmdConfForTango;
	}
	
	void registerCompiler ()
	{
		verbose("Registering compiler");
		
		string installedCompilers;
		if(Path.exists(options.path.installed))
			installedCompilers = cast(string) File.get(options.path.installed);

		auto dmd = "dmd-" ~ args.first;
		
		if (!installedCompilers.containsPattern(dmd))
		{
			if(installedCompilers != "")
				installedCompilers ~= "\n";
			installedCompilers ~= dmd;
			File.set(options.path.installed, installedCompilers);
		}
	}
	
	void fetchTango ()
	{
		const tangoUrl = "http://dsource.org/projects/tango/changeset/head/trunk?old_path=%2F&format=zip";
		fetch(tangoUrl, options.path.tangoZip);
	}
	
	void unpackTango ()
	{
		verbose("Unpacking:");
		verbose(options.indentation, "source: ", options.path.tangoZip);
		verbose(options.indentation, "destination: ", options.path.tangoTmp, '\n');
		extractArchive(options.path.tangoZip, options.path.tangoUnarchived);
	}
	
	void setupTangoEnvironment ()
	{
		verbose(format(`Installing "{}" as the temporary D compiler`, args.first));
		auto path = Environment.get("PATH");
		path = Path.join(installPath, options.path.bin) ~ options.path.pathSeparator ~ path;
		Environment.set("PATH", path);
	}

	void buildTango ()
	{
		version (Posix)
		{
			verbose("Setting permission:");
			permission(options.path.tangoBob, "+x");
		}
		
		verbose("Building Tango...");

		auto tangoBuildOptions = [
			"-r=dmd"[], "-c=dmd", "-u", "-q", "-l=" ~ options.path.tangoLibName
		];
		version (Posix)
			auto tangoBuildOptions = options.is64bit ? "-m=64" : "-m=32";

		auto process = new Process(true, options.path.tangoBob ~ tangoBuildOptions ~ "."[]);
		process.workDir = options.path.tangoTmp;
		process.execute;
		
		auto result = process.wait;

		if (options.verbose || result.reason != Process.Result.Exit)
		{
			println("Output of the Tango build:", "\n");
			Stdout.copy(process.stdout).flush;
			println();
			println("Process ", process.programName, '(', process.pid, ')', " exited with:");
			println(options.indentation, "reason: ", result);
			println(options.indentation, "status: ", result.status, "\n");
		}
	}
	
	void moveTangoFiles ()
	{
		verbose("Moving:");
		
		auto importDest = Path.join(installPath, options.path.import_);
		
		auto tangoSource = options.path.tangoSrc;
		auto tangoDest = Path.join(importDest, "tango");
		
		
		auto objectSrc = options.path.tangoObject;
		auto objectDest = Path.join(importDest, options.path.object_di);
		
		auto vendorSrc = options.path.tangoVendor;
		auto vendorDest = Path.join(importDest, options.path.std);
		
		move(options.path.tangoLib, Path.join(installPath, options.path.lib, options.path.tangoLibName ~ options.path.libExtension));
		move(vendorSrc, vendorDest);
		move(tangoSource, tangoDest);
		move(objectSrc, objectDest);
	}
	
	void patchDmdConfForTango ()
	{
		auto dmdConfPath = Path.join(installPath, options.path.conf);
		
		verbose("Patching: ", dmdConfPath);
		
		string newInclude = "-I%@P%/../import";
		string newArgs = " -defaultlib=tango -debuglib=tango -version=Tango";
		string content = cast(string) File.get(dmdConfPath);
		
		string oldInclude1 = "-I%@P%/../src/phobos";
		string oldInclude2 = "-I%@P%/../../src/druntime/import";
		version (Windows)
		{
			oldInclude1 = '"' ~ oldInclude1 ~ '"';
			oldInclude2 = '"' ~ oldInclude2 ~ '"';
			newInclude  = '"' ~ newInclude  ~ '"';
		}

		auto src = newInclude ~ newArgs;
		
		content = content.slashSafeSubstitute(oldInclude1, src);
		content = content.slashSafeSubstitute(oldInclude2, "");
		
		File.set(dmdConfPath, content);
	}
	
	void move (string source, string destination)
	{
		verbose(options.indentation, "source: ", source);
		verbose(options.indentation, "destination: ", destination, '\n');		
		
		if (Path.exists(destination))
			Path.remove(destination, true);

		bool createParentOnly = false;
		if (Path.isFile(source))
			createParentOnly = true;
		
		version (Windows)
			createParentOnly = true;
		
		if (createParentOnly)
			Path.createPath(Path.parse(destination).path);
		else
			Path.createPath(destination);

		Path.rename(source, destination);
	}
	
	string installPath ()
	{
		if (installPath_.length > 0)
			return installPath_;

		return installPath_ = Path.join(options.path.compilers, "dmd-" ~ args.first);
	}
	
	void permission (string path, string mode)
	{
		version (Posix)
		{
			verbose(options.indentation, "mode: " ~ mode);
			verbose(options.indentation, "file: " ~ path, '\n');
			
			Path.permission(path, mode);
		}
	}
	
	string getLibSource (string platformRoot)
	{
		string libPath = Path.join(platformRoot, options.path.lib);
		
		if (Path.exists(libPath))
			return libPath;
		
		if (options.is64bit)
		{
			libPath = Path.join(platformRoot, options.path.lib64);
			
			if (Path.exists(libPath))
				return libPath;
			
			else
				throw new DvmException("There is no 64bit compiler available on this platform", __FILE__, __LINE__);
		}

		libPath = Path.join(platformRoot, options.path.lib32);

		if (Path.exists(libPath))
			return libPath;

		throw new DvmException("Could not find the library path: " ~ libPath, __FILE__, __LINE__);
	}

	string getBinSource (string platformRoot)
    {
    	string binPath = Path.join(platformRoot, options.path.bin);

    	if (Path.exists(binPath))
    		return binPath;

    	if (options.is64bit)
    	{
    		binPath = Path.join(platformRoot, options.path.bin64);

    		if (Path.exists(binPath))
    			return binPath;

    		else
    			throw new DvmException("There is no 64bit compiler available on this platform", __FILE__, __LINE__);
    	}

    	binPath = Path.join(platformRoot, options.path.bin32);

    	if (Path.exists(binPath))
    		return binPath;

    	throw new DvmException("Could not find the binrary path: " ~ binPath, __FILE__, __LINE__);
    }

	string slashSafeSubstitute(string haystack, string needle, string replacement)
	{
		version (Windows)
		{
			needle      = needle     .substitute("/", "\\");
			replacement = replacement.substitute("/", "\\");
		}
			
		return haystack.substitute(needle, replacement);
	}
}